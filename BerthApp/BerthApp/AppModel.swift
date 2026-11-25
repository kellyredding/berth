import AppKit
import Combine
import WebKit

/// One site's app: owns the services and the windows and wires them
/// together. The socket's events and the menus both land here.
@MainActor
final class AppModel: ObservableObject {
    let paths: BerthPaths
    let site: String
    let cli: CLIRunner
    let configStore: ConfigStore
    let downloads: Downloads
    let notifier = Notifier()
    let safariVersion: String
    private var configuration: WKWebViewConfiguration?
    /// The notification shim the windows' pages get at their next load: the
    /// site's hosts and macOS's permission, or none when the site leaves
    /// notifications off.
    private var shimState: NotificationShimState?
    private(set) var mainWindow: BrowserWindowController?
    private var popups: [BrowserWindowController] = []
    private var messageWindow: MessageWindowController?
    private var socket: SocketServer?
    private var handler: RequestHandler?
    private var subscriptions: Set<AnyCancellable> = []
    private var pendingURLs: [URL] = []
    private var badgeRule: BadgeRule?
    private var loggedFirstPage = false
    private var successExpiry = 0
    private var offerCheckDue: Date?
    private var offerChecks = 0
    @Published private(set) var badge: String?
    /// File → Sign In with 1Password and the main window's sign-in bar.
    @Published private(set) var signinBar = SigninBarState() {
        didSet {
            let message = signinBar.presentation?.message
            if message != oldValue.presentation?.message { Log.info("signin bar: \(message ?? "hidden")") }
            scheduleOfferCheck()
        }
    }

    init(paths: BerthPaths, site: String) {
        self.paths = paths
        self.site = site
        cli = CLIRunner(paths: paths, site: site)
        configStore = ConfigStore(paths: paths, cli: cli)
        downloads = Downloads(appName: Bundle.main.object(forInfoDictionaryKey: "CFBundleName") as? String ?? "Berth")
        safariVersion = WebSession.safariVersion()
    }

    var version: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "unknown"
    }

    var buildLabel: String { BuildLabel.text(commit: Bundle.main.object(forInfoDictionaryKey: "BerthBuildCommit")) }

    var displayName: String { configStore.config?.name ?? site }

    /// The last good config's hosts; nothing is kept before one loads.
    var keep: KeepList { configStore.config?.keep ?? KeepList([]) }

    var pageZoom: Double {
        get {
            let stored = UserDefaults.standard.double(forKey: "pageZoom.\(site)")
            return stored > 0 ? PageZoom.clamped(stored) : PageZoom.actualSize
        }
        set {
            UserDefaults.standard.set(newValue, forKey: "pageZoom.\(site)")
            for controller in [mainWindow].compactMap({ $0 }) + popups { controller.webView.pageZoom = newValue }
        }
    }

    /// False when another instance already serves this site; the caller quits.
    func start() -> Bool {
        try? FileManager.default.createDirectory(
            at: paths.runtimeDir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700]
        )
        try? FileManager.default.createDirectory(at: paths.logsDir, withIntermediateDirectories: true)

        let socket = SocketServer(socketPath: paths.socket(site: site).path, lockPath: paths.lockFile(site: site).path)
        let handler = RequestHandler(model: self)
        socket.handler = { await handler.handle($0) }
        switch socket.start() {
        case .anotherInstance:
            Log.error("another copy of \(site)'s app holds \(paths.lockFile(site: site).path); quitting")
            return false
        case .failed(let message):
            Log.error(message)
        case .listening:
            break
        }
        self.socket = socket
        self.handler = handler

        configStore.objectWillChange
            .sink { [weak self] _ in self?.objectWillChange.send() }
            .store(in: &subscriptions)
        notifier.objectWillChange
            .sink { [weak self] _ in self?.objectWillChange.send() }
            .store(in: &subscriptions)
        notifier.onAuthorizationChange = { [weak self] in self?.notificationPermissionChanged() }
        notifier.onClick = { [weak self] webView, pageID in self?.notificationClicked(webView: webView, pageID: pageID) }
        notifier.start()
        configStore.onLoad = { [weak self] in self?.configLoaded() }
        Log.info("user agent: WebKit's own + \(UserAgent.applicationName(safariVersion: safariVersion))")
        configStore.start()
        return true
    }

    func stop() {
        socket?.stop()
    }

    // MARK: - Config

    private func configLoaded() {
        guard let config = configStore.config else {
            if mainWindow == nil { showLoadError() }
            return
        }
        messageWindow?.close()
        messageWindow = nil

        badgeRule = nil
        if let pattern = config.badge?.title {
            badgeRule = BadgeRule(pattern: pattern)
            if badgeRule == nil { Log.error("badge.title does not compile here: \(pattern)") }
        }
        updateBadge(title: mainWindow?.webView.title)
        LaunchAtLoginChoice.apply(configured: config.launchAtLogin, site: site)
        signinBar.configure(name: config.name, signin: config.signin, keep: config.keep, at: Date())
        notifier.enabled = config.notifications
        notifier.keep = config.keep

        if mainWindow == nil { createMainWindow(config) }
        refreshNotificationShim()
    }

    private func createMainWindow(_ config: SiteConfig) {
        let configuration = WebSession.configuration(site: site, safariVersion: safariVersion)
        notifier.install(in: configuration.userContentController)
        self.configuration = configuration
        refreshNotificationShim()
        let controller = BrowserWindowController(model: self, configuration: configuration, role: .main)
        mainWindow = controller

        let pending = pendingURLs
        pendingURLs = []
        var start = config.url
        for incoming in pending {
            guard let url = MailtoLink.isMailto(incoming) ? composeURL(for: incoming, config: config) : incoming else { continue }
            switch LinkPolicy.external(url, keep: config.keep) {
            case .app: start = url
            case .browser: openExternally(url)
            case .ignore: break
            }
        }
        Log.info("loading \(Self.describe(start))")
        controller.load(start)
        controller.show()
        activate()
    }

    private func showLoadError() {
        let detail = configStore.error ?? "no reason given"
        if let messageWindow {
            messageWindow.update(detail: detail)
            return
        }
        let window = MessageWindowController(
            title: site,
            message: "\(site)'s settings could not be loaded.",
            detail: detail,
            actions: [
                .init(title: "Try Again") { [weak self] in Task { await self?.configStore.reload() } },
                .init(title: "Quit") { NSApp.terminate(nil) },
            ]
        )
        messageWindow = window
        window.show()
        activate()
    }

    // MARK: - Windows

    func showMainWindow() {
        if let mainWindow {
            mainWindow.show()
        } else {
            messageWindow?.show()
        }
        activate()
    }

    /// The popup's window stays hidden until its PopupGate shows it.
    func openPopup(configuration: WKWebViewConfiguration, features: WKWindowFeatures) -> WKWebView {
        let controller = BrowserWindowController(model: self, configuration: configuration, role: .popup, features: features)
        popups.append(controller)
        return controller.webView
    }

    func popupClosed(_ controller: BrowserWindowController) {
        popups.removeAll { $0 === controller }
    }

    func mainTitleChanged(_ title: String?) {
        updateBadge(title: title)
    }

    /// The main window's page moved, by a load, a redirect or the page's own
    /// history.
    func mainPageChanged(_ url: URL?) {
        signinBar.pageChanged(host: url.flatMap { LinkPolicy.isWeb($0) ? $0.host : nil }, at: Date())
    }

    func mainPageFinished(_ url: URL?) {
        guard let url else { return }
        if !loggedFirstPage {
            loggedFirstPage = true
            Log.info("page finished: \(Self.describe(url))")
        }
    }

    func openExternally(_ url: URL) {
        if !NSWorkspace.shared.open(url) {
            Log.error("no app opened \(url.scheme ?? "a"): URL")
        }
    }

    /// URLs from `open -a <app> URL` and `mailto:` links, before or after the
    /// page is up.
    func openURLs(_ urls: [URL]) {
        guard mainWindow != nil, let config = configStore.config else {
            pendingURLs.append(contentsOf: urls)
            return
        }
        for url in urls {
            if MailtoLink.isMailto(url) {
                if let compose = composeURL(for: url, config: config) { _ = open(compose) }
            } else {
                _ = open(url)
            }
        }
    }

    /// A `mailto:` link as the site's compose page, which then loads in the
    /// main window like any kept URL. Never handed back to the system: this
    /// app may be the default email app, and the link would return here.
    private func composeURL(for link: URL, config: SiteConfig) -> URL? {
        switch MailtoLink.route(link.absoluteString, handles: config.handles, template: config.mailto) {
        case .compose(let url):
            Log.info("mailto: opening the compose page \(LinkPolicy.hostAndPath(url))")
            return url
        case .notHandled:
            Log.info("mailto: dropped a link; this site's config doesn't handle mailto")
        case .badTemplate:
            Log.error("mailto: dropped a link; the site's mailto template doesn't make a URL with it")
        }
        return nil
    }

    private func activate() {
        NSApp.activate(ignoringOtherApps: true)
    }

    private func updateBadge(title: String?) {
        let label = badgeRule?.label(for: title)
        guard label != badge else { return }
        badge = label
        NSApp.dockTile.badgeLabel = label
    }

    /// Scheme, host and path: enough to follow the app in its log without
    /// writing a page's query or fragment there.
    static func describe(_ url: URL) -> String {
        guard let scheme = url.scheme, let host = url.host else { return url.scheme.map { "\($0): URL" } ?? "a URL" }
        return "\(scheme)://\(host)\(url.path.isEmpty ? "/" : url.path)"
    }

    // MARK: - Notifications

    /// User scripts apply from a page's next load; the native side refuses
    /// what the config no longer allows meanwhile.
    private func refreshNotificationShim() {
        guard let controller = configuration?.userContentController, let config = configStore.config else { return }
        let wanted = NotificationShimState.wanted(
            notifications: config.notifications, keep: config.keep, authorization: notifier.authorization
        )
        guard wanted != shimState else { return }
        shimState = wanted
        controller.removeAllUserScripts()
        guard let wanted else {
            Log.info("notification: off for this site")
            return
        }
        controller.addUserScript(WKUserScript(
            source: NotificationShim.userScript(keep: wanted.keep, permission: wanted.permission),
            injectionTime: .atDocumentStart, forMainFrameOnly: true, in: .page
        ))
    }

    /// Pages already open learn the new permission at once; new ones get it
    /// from the shim.
    private func notificationPermissionChanged() {
        refreshNotificationShim()
        guard configStore.config?.notifications == true else { return }
        let permission = notifier.authorization.pagePermission.rawValue
        for controller in [mainWindow].compactMap({ $0 }) + popups {
            controller.webView.callAsyncJavaScript(
                NotificationShim.permissionBody, arguments: ["permission": permission], in: nil, in: .page
            ) { _ in }
        }
    }

    /// Brings forward the window whose page posted it, the main window when
    /// that is gone, and fires the page's `click` for that notification.
    private func notificationClicked(webView: WKWebView?, pageID: String?) {
        let controller = ([mainWindow].compactMap { $0 } + popups).first { $0.webView === webView }
        if let controller, controller.role == .popup {
            controller.show()
            activate()
        } else {
            showMainWindow()
        }
        guard let controller, let pageID else { return }
        controller.webView.callAsyncJavaScript(
            NotificationShim.clickBody, arguments: ["id": pageID], in: nil, in: .page
        ) { result in
            if case .success(let handled) = result, handled as? Bool == true { return }
            Log.info("notification: the page no longer has it; the window came forward only")
        }
    }

    // MARK: - Socket

    func statusData() -> StatusData {
        let title = mainWindow?.webView.title
        return StatusData(
            version: version,
            pid: Int(ProcessInfo.processInfo.processIdentifier),
            site: site,
            url: mainWindow?.webView.url?.absoluteString,
            title: title?.isEmpty == false ? title : nil,
            badge: badge,
            config: .init(state: configStore.state, error: configStore.error)
        )
    }

    func open(_ url: URL?) -> Result<OpenData, RequestError> {
        guard let url else {
            showMainWindow()
            return .success(OpenData(url: nil, openedIn: .app))
        }
        guard let mainWindow else { return .failure(.noConfig) }
        switch LinkPolicy.external(url, keep: keep) {
        case .app:
            Log.info("open: loading \(Self.describe(url))")
            mainWindow.load(url)
            showMainWindow()
            return .success(OpenData(url: url.absoluteString, openedIn: .app))
        case .browser:
            Log.info("open: \(Self.describe(url)) is outside keep; opening it in the browser")
            openExternally(url)
            return .success(OpenData(url: url.absoluteString, openedIn: .browser))
        case .ignore:
            return .failure(.badRequest("\(url.absoluteString) cannot be opened"))
        }
    }

    /// Fills the main window's sign-in, one at a time, in front of the person
    /// who may have to approve a step. The request comes from the app's own
    /// run of the CLI or from a terminal's; the bar shows its progress either
    /// way.
    func signin(_ request: SigninRequest) async -> Result<SigninData, RequestError> {
        guard let mainWindow, let config = configStore.config else { return .failure(.noConfig) }
        guard !signinBar.filling else { return .failure(.signinBusy) }
        signinBar.fillStarted(flows: request.flows)
        showMainWindow()
        if let first = request.steps.first?.flow,
           SigninStart.reloadFirst(firstFlow: first, host: mainWindow.webView.url?.host) {
            Log.info("signin: the page is not \(first.rawValue)'s; starting from \(Self.describe(config.url))")
            mainWindow.load(config.url)
            await settled(mainWindow.webView)
        }
        Log.info("signin: filling \(request)")
        let filler = SigninFiller(webView: mainWindow.webView)
        let progress = filler.$progress.compactMap { $0 }.sink { [weak self] in self?.signinBar.progressed($0) }
        let data = await filler.run(request, siteHost: config.url.host)
        progress.cancel()
        if data.alreadySignedIn {
            Log.info("signin: signed in already; nothing to do")
        } else if let stop = data.stoppedAt {
            Log.info("signin: stopped at step \(stop.step + 1), \(stop.flow): \(stop.reason)")
        } else {
            Log.info("signin: done (\(data.completed.joined(separator: ", ")))")
        }
        signinBar.fillFinished(SigninResult(data))
        expireSuccessLater()
        return .success(data)
    }

    /// Returns once the page has stopped loading for a moment, or after 15 s;
    /// the filler then polls whatever page it finds.
    private func settled(_ webView: WKWebView) async {
        let deadline = Date().addingTimeInterval(15)
        var idleSince: Date?
        try? await Task.sleep(nanoseconds: 300_000_000)
        while Date() < deadline {
            if webView.isLoading {
                idleSince = nil
            } else if let since = idleSince, Date().timeIntervalSince(since) >= 1 {
                return
            } else if idleSince == nil {
                idleSince = Date()
            }
            try? await Task.sleep(nanoseconds: 200_000_000)
        }
    }

    // MARK: - Signing in from the app

    /// Runs `berth signin` for one of the site's logins, as the menu and the
    /// bar do: the CLI reads 1Password and sends the fill back to this app's
    /// socket, which `signin(_:)` answers.
    func startSignin(login: String) {
        guard signinBar.logins.contains(login), !signinBar.isRunning else { return }
        signinBar.launched(login: login)
        Log.info("signin: running berth signin \(site) --account \(login)")
        Task { [weak self] in
            guard let self else { return }
            let result = await self.cli.signin(login: login)
            self.signinFinished(result, login: login)
        }
    }

    func dismissSigninBar() {
        signinBar.dismiss()
    }

    /// Whether the main window's page shows a sign-in flow's markers.
    func signinMarkers(seen: Bool) {
        guard seen != signinBar.markerSeen else { return }
        signinBar.markers(seen: seen, at: Date())
    }

    /// One check when a sign-in page's offer falls due. A page that moves on
    /// first changes or clears the due time, and the stale check is ignored.
    private func scheduleOfferCheck() {
        let due = signinBar.offerDue
        guard due != offerCheckDue else { return }
        offerCheckDue = due
        offerChecks += 1
        guard let due else { return }
        let token = offerChecks
        DispatchQueue.main.asyncAfter(deadline: .now() + max(0, due.timeIntervalSinceNow)) { [weak self] in
            MainActor.assumeIsolated {
                guard let self, self.offerChecks == token else { return }
                self.offerCheckDue = nil
                self.signinBar.recheck(at: Date())
            }
        }
    }

    private func signinFinished(_ result: SigninResult, login: String) {
        switch result {
        case .signedIn: Log.info("signin: berth signin --account \(login) finished")
        case .stopped(let reason): Log.info("signin: berth signin --account \(login) stopped: \(reason)")
        case .failed(let message): Log.error("signin: berth signin --account \(login): \(message)")
        }
        signinBar.cliFinished(result)
        expireSuccessLater()
    }

    /// "Signed in" shows briefly, then the bar hides; a later result restarts
    /// the wait.
    private func expireSuccessLater() {
        guard signinBar.result?.succeeded == true else { return }
        successExpiry += 1
        let token = successExpiry
        DispatchQueue.main.asyncAfter(deadline: .now() + SigninBarState.successDuration) { [weak self] in
            MainActor.assumeIsolated {
                guard let self, self.successExpiry == token else { return }
                self.signinBar.expireSuccess()
            }
        }
    }
}
