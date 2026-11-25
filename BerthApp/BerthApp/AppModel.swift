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
    let safariVersion: String
    private var configuration: WKWebViewConfiguration?
    private(set) var mainWindow: BrowserWindowController?
    private var popups: [BrowserWindowController] = []
    private var messageWindow: MessageWindowController?
    private var socket: SocketServer?
    private var handler: RequestHandler?
    private var subscriptions: Set<AnyCancellable> = []
    private var pendingURLs: [URL] = []
    private var badgeRule: BadgeRule?
    private var loggedFirstPage = false
    @Published private(set) var badge: String?

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

        if mainWindow == nil { createMainWindow(config) }
    }

    private func createMainWindow(_ config: SiteConfig) {
        let configuration = WebSession.configuration(site: site, safariVersion: safariVersion)
        self.configuration = configuration
        let controller = BrowserWindowController(model: self, configuration: configuration, role: .main)
        mainWindow = controller

        let pending = pendingURLs
        pendingURLs = []
        var start = config.url
        for url in pending {
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

    /// URLs from `open -a <app> URL`, before or after the page is up.
    func openURLs(_ urls: [URL]) {
        guard mainWindow != nil else {
            pendingURLs.append(contentsOf: urls)
            return
        }
        for url in urls { _ = open(url) }
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
}
