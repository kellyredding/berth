import AppKit
import Combine
import WebKit

/// One window showing the site: the main window, or a second window for an
/// in-scope popup. Every link decision goes through LinkPolicy with the
/// site's current `keep`.
@MainActor
final class BrowserWindowController: NSWindowController, NSWindowDelegate, WKNavigationDelegate, WKUIDelegate,
    NSMenuItemValidation {
    enum Role { case main, popup }

    /// When a finished page is looked at again for a sign-in's markers: a
    /// sign-in widget often draws itself after the load.
    private static let markerChecks: [TimeInterval] = [0, 1.5]

    let role: Role
    let webView: WKWebView
    private unowned let model: AppModel
    private let findBar = FindBar()
    private var findBarHeight: NSLayoutConstraint!
    /// The main window only: sign in with 1Password, above the find bar.
    private var signinBar: SigninBarView?
    private var signinBarHeight: NSLayoutConstraint?
    private var signinBarSubscription: AnyCancellable?
    private var markerCheck = 0
    private var observations: [NSKeyValueObservation] = []
    /// Popups only: whether the window appears, or hands off and closes.
    private var popupGate: PopupGate?

    init(model: AppModel, configuration: WKWebViewConfiguration, role: Role, features: WKWindowFeatures? = nil) {
        self.model = model
        self.role = role
        webView = WKWebView(frame: .zero, configuration: configuration)

        let size = NSSize(width: features?.width?.doubleValue ?? (role == .main ? 1200 : 640),
                          height: features?.height?.doubleValue ?? (role == .main ? 860 : 720))
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: size),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable],
                              backing: .buffered, defer: false)
        window.tabbingMode = .disallowed
        window.isReleasedWhenClosed = false
        window.minSize = NSSize(width: 400, height: 300)
        window.title = model.displayName
        super.init(window: window)
        window.delegate = self

        webView.navigationDelegate = self
        webView.uiDelegate = self
        webView.allowsBackForwardNavigationGestures = true
        webView.allowsMagnification = true
        webView.pageZoom = model.pageZoom
        if role == .main { signinBar = SigninBarView() }
        layOut(in: window)

        switch role {
        case .main:
            let name = "Berth.\(model.site)"
            window.center()
            window.setFrameUsingName(name)
            window.setFrameAutosaveName(name)
        case .popup:
            window.center()
            popupGate = PopupGate()
        }

        observations.append(webView.observe(\.title, options: [.initial, .new]) { [weak self] _, _ in
            MainActor.assumeIsolated { self?.titleChanged() }
        })
        if role == .main {
            observations.append(webView.observe(\.url, options: [.initial, .new]) { [weak self] _, _ in
                MainActor.assumeIsolated { self?.urlChanged() }
            })
            signinBarSubscription = model.$signinBar
                .removeDuplicates()
                .sink { [weak self] in self?.showSigninBar($0) }
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func load(_ url: URL) {
        webView.load(URLRequest(url: url))
    }

    func show() {
        guard let window else { return }
        if window.isMiniaturized { window.deminiaturize(nil) }
        window.makeKeyAndOrderFront(nil)
    }

    /// Top to bottom: the sign-in bar (main window only), the find bar, the
    /// page. A hidden bar has no height, so the page never sits beneath one.
    private func layOut(in window: NSWindow) {
        let container = NSView()
        findBar.isHidden = true
        findBar.onFind = { [weak self] text, backwards in self?.find(text, backwards: backwards) }
        findBar.onClose = { [weak self] in self?.closeFindBar() }
        for view in [signinBar, findBar, webView].compactMap({ $0 }) as [NSView] {
            view.translatesAutoresizingMaskIntoConstraints = false
            container.addSubview(view)
        }
        var top = container.topAnchor
        if let signinBar {
            signinBar.isHidden = true
            signinBar.onSignIn = { [weak self] login in self?.model.startSignin(login: login) }
            signinBar.onDismiss = { [weak self] in self?.model.dismissSigninBar() }
            let height = signinBar.heightAnchor.constraint(equalToConstant: 0)
            signinBarHeight = height
            NSLayoutConstraint.activate([
                signinBar.topAnchor.constraint(equalTo: container.topAnchor),
                signinBar.leadingAnchor.constraint(equalTo: container.leadingAnchor),
                signinBar.trailingAnchor.constraint(equalTo: container.trailingAnchor),
                height,
            ])
            top = signinBar.bottomAnchor
        }
        findBarHeight = findBar.heightAnchor.constraint(equalToConstant: 0)
        NSLayoutConstraint.activate([
            findBar.topAnchor.constraint(equalTo: top),
            findBar.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            findBar.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            findBarHeight,
            webView.topAnchor.constraint(equalTo: findBar.bottomAnchor),
            webView.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            webView.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            webView.bottomAnchor.constraint(equalTo: container.bottomAnchor),
        ])
        window.contentView = container
    }

    private func titleChanged() {
        let title = webView.title ?? ""
        window?.title = title.isEmpty ? model.displayName : title
        if role == .main { model.mainTitleChanged(webView.title) }
    }

    // MARK: - Sign-in bar

    private func urlChanged() {
        model.mainPageChanged(webView.url)
    }

    private func showSigninBar(_ state: SigninBarState) {
        guard let signinBar, let signinBarHeight else { return }
        if let presentation = state.presentation {
            signinBar.show(presentation, logins: state.logins)
            signinBar.isHidden = false
            signinBarHeight.constant = SigninBarView.height
        } else {
            signinBar.isHidden = true
            signinBarHeight.constant = 0
        }
    }

    /// A page on a host no sign-in flow lists may still be one of their
    /// pages; look for the flows' markers once it has loaded, and again once
    /// its scripts have had a moment to draw.
    private func checkSigninMarkers() {
        markerCheck += 1
        let check = markerCheck
        for delay in Self.markerChecks {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
                MainActor.assumeIsolated { self?.checkSigninMarkers(check) }
            }
        }
    }

    private func checkSigninMarkers(_ check: Int) {
        let state = model.signinBar
        guard check == markerCheck, !state.logins.isEmpty,
              !state.flows.contains(where: { $0.spec.hosts.keeps(host: state.host) }) else { return }
        let host = webView.url?.host
        Task { [weak self] in
            guard let self else { return }
            let seen = await SigninFiller.showsMarker(of: state.flows, in: self.webView)
            guard check == self.markerCheck, self.webView.url?.host == host else { return }
            self.model.signinMarkers(seen: seen)
        }
    }

    // MARK: - Window

    /// Closing the main window hides it and keeps the page running, so its
    /// badge stays current and the Dock icon brings it straight back.
    func windowShouldClose(_ sender: NSWindow) -> Bool {
        guard role == .main else { return true }
        sender.orderOut(nil)
        return false
    }

    func windowWillClose(_ notification: Notification) {
        guard role == .popup else { return }
        observations.removeAll()
        webView.stopLoading()
        model.popupClosed(self)
    }

    // MARK: - Menu actions

    @objc func reloadPage(_ sender: Any?) { webView.reload() }

    @objc func historyBack(_ sender: Any?) { webView.goBack() }

    @objc func historyForward(_ sender: Any?) { webView.goForward() }

    @objc func actualSize(_ sender: Any?) { setZoom(PageZoom.actualSize) }

    @objc func zoomInPage(_ sender: Any?) { setZoom(PageZoom.zoomIn(from: webView.pageZoom)) }

    @objc func zoomOutPage(_ sender: Any?) { setZoom(PageZoom.zoomOut(from: webView.pageZoom)) }

    @objc func copyPageLink(_ sender: Any?) {
        guard let url = webView.url else { return }
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.writeObjects([url as NSURL])
        pasteboard.setString(url.absoluteString, forType: .string)
    }

    @objc func openInBrowser(_ sender: Any?) {
        guard let url = webView.url else { return }
        model.openExternally(url)
    }

    @objc func printPage(_ sender: Any?) {
        guard let window else { return }
        let operation = webView.printOperation(with: NSPrintInfo.shared)
        // Without a frame WebKit prints blank pages.
        operation.view?.frame = webView.bounds
        operation.runModal(for: window, delegate: nil, didRun: nil, contextInfo: nil)
    }

    @objc func showFindBar(_ sender: Any?) {
        findBar.isHidden = false
        findBarHeight.constant = FindBar.height
        window?.makeFirstResponder(findBar.field)
        findBar.field.selectText(nil)
    }

    @objc func findNextMatch(_ sender: Any?) { findAgain(backwards: false) }

    @objc func findPreviousMatch(_ sender: Any?) { findAgain(backwards: true) }

    func validateMenuItem(_ item: NSMenuItem) -> Bool {
        switch item.action {
        case #selector(historyBack(_:)): return webView.canGoBack
        case #selector(historyForward(_:)): return webView.canGoForward
        case #selector(copyPageLink(_:)), #selector(openInBrowser(_:)): return webView.url.map(LinkPolicy.isWeb) ?? false
        case #selector(findNextMatch(_:)), #selector(findPreviousMatch(_:)): return !findBar.text.isEmpty
        case #selector(zoomInPage(_:)): return webView.pageZoom < PageZoom.levels.last! - 0.001
        case #selector(zoomOutPage(_:)): return webView.pageZoom > PageZoom.levels.first! + 0.001
        case #selector(actualSize(_:)): return abs(webView.pageZoom - PageZoom.actualSize) > 0.001
        default: return true
        }
    }

    private func setZoom(_ zoom: Double) {
        webView.pageZoom = zoom
        model.pageZoom = zoom
    }

    private func findAgain(backwards: Bool) {
        if findBar.isHidden || findBar.text.isEmpty {
            showFindBar(nil)
            return
        }
        find(findBar.text, backwards: backwards)
    }

    private func find(_ text: String, backwards: Bool) {
        let configuration = WKFindConfiguration()
        configuration.backwards = backwards
        configuration.caseSensitive = false
        configuration.wraps = true
        webView.find(text, configuration: configuration) { [weak self] result in
            self?.findBar.showResult(found: result.matchFound)
        }
    }

    private func closeFindBar() {
        findBar.isHidden = true
        findBarHeight.constant = 0
        window?.makeFirstResponder(webView)
    }

    // MARK: - Navigation

    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction,
                 decisionHandler: @escaping @MainActor (WKNavigationActionPolicy) -> Void) {
        if navigationAction.shouldPerformDownload {
            decisionHandler(.download)
            return
        }
        let url = navigationAction.request.url
        let kind = Self.kind(navigationAction.navigationType)
        let commandClick = kind == .link && navigationAction.modifierFlags.contains(.command)
        let mainFrame = navigationAction.targetFrame?.isMainFrame ?? true
        if mainFrame, var gate = popupGate {
            let action = gate.navigation(LinkPolicy.popupDestination(url, keep: model.keep))
            popupGate = gate
            switch action {
            case .allow:
                decisionHandler(.allow)
                return
            case .handOffAndClose:
                decisionHandler(.cancel)
                if let url { model.openExternally(url) }
                Log.info("popup: handed off \(url?.host ?? "\(url?.scheme ?? "no") URL"), closed")
                window?.close()
                return
            case .close:
                decisionHandler(.cancel)
                Log.info("popup: dropped a \(url?.scheme ?? "no"): URL, closed")
                window?.close()
                return
            case .none, .startGrace, .show:
                break
            }
        }
        let route = LinkPolicy.navigation(url, kind: kind, mainFrame: mainFrame, commandClick: commandClick, keep: model.keep)
        switch route {
        case .app:
            decisionHandler(.allow)
            if mainFrame, let url { logCrossHost(url, kind: kind) }
        case .browser:
            decisionHandler(.cancel)
            if let url {
                Log.info("handed to browser (\(commandClick ? "⌘-click" : kind.label)): " +
                         (LinkPolicy.isWeb(url) ? LinkPolicy.hostAndPath(url) : "a \(url.scheme ?? "no"): URL"))
                model.openExternally(url)
            }
        case .ignore:
            decisionHandler(.cancel)
            Log.info("dropped a navigation to \(url?.scheme ?? "no"): URL")
        }
    }

    /// One line per main-frame move to another host, so a sign-in chain that
    /// goes wrong can be followed in the log.
    private func logCrossHost(_ url: URL, kind: NavigationKind) {
        guard LinkPolicy.isWeb(url), let host = url.host?.lowercased(),
              host != webView.url?.host?.lowercased() else { return }
        let label = model.keep.keeps(url) ? "navigation" : "left site"
        Log.info("\(label) (\(kind.label), stays): \(LinkPolicy.hostAndPath(url))")
    }

    private static func kind(_ type: WKNavigationType) -> NavigationKind {
        switch type {
        case .linkActivated: return .link
        case .formSubmitted: return .formSubmission
        case .formResubmitted: return .formResubmission
        case .backForward: return .backForward
        case .reload: return .reload
        default: return .other
        }
    }

    func webView(_ webView: WKWebView, didCommit navigation: WKNavigation!) {
        guard var gate = popupGate else { return }
        let action = gate.committed(inScope: webView.url.map(model.keep.keeps) ?? false)
        popupGate = gate
        guard case .startGrace(let generation) = action else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + PopupGate.grace) { [weak self] in
            MainActor.assumeIsolated { self?.popupGraceElapsed(generation) }
        }
    }

    private func popupGraceElapsed(_ generation: Int) {
        guard var gate = popupGate else { return }
        let action = gate.graceElapsed(generation)
        popupGate = gate
        guard action == .show else { return }
        Log.info("popup: shown \(webView.url?.host ?? "a page")")
        show()
    }

    func webView(_ webView: WKWebView, decidePolicyFor navigationResponse: WKNavigationResponse,
                 decisionHandler: @escaping @MainActor (WKNavigationResponsePolicy) -> Void) {
        let disposition = (navigationResponse.response as? HTTPURLResponse)?
            .value(forHTTPHeaderField: "Content-Disposition")?.lowercased() ?? ""
        if !navigationResponse.canShowMIMEType || disposition.hasPrefix("attachment") {
            decisionHandler(.download)
        } else {
            decisionHandler(.allow)
        }
    }

    func webView(_ webView: WKWebView, navigationAction: WKNavigationAction, didBecome download: WKDownload) {
        model.downloads.adopt(download)
    }

    func webView(_ webView: WKWebView, navigationResponse: WKNavigationResponse, didBecome download: WKDownload) {
        model.downloads.adopt(download)
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        guard role == .main else { return }
        model.mainPageFinished(webView.url)
        checkSigninMarkers()
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        logFailure(error)
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        logFailure(error)
    }

    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        Log.error("the page's web content process ended; reloading")
        webView.reload()
    }

    private func logFailure(_ error: Error) {
        let error = error as NSError
        // Cancelled, and "frame load interrupted" when a navigation becomes a
        // download or is cancelled by policy: both expected.
        if error.domain == NSURLErrorDomain && error.code == NSURLErrorCancelled { return }
        if error.domain == "WebKitErrorDomain" && error.code == 102 { return }
        Log.error("page failed to load: \(error.localizedDescription)")
    }

    // MARK: - UI

    func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
                 for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
        let url = navigationAction.request.url
        let commandClick = navigationAction.modifierFlags.contains(.command)
        switch LinkPolicy.newWindow(url, commandClick: commandClick, keep: model.keep) {
        case .app:
            return model.openPopup(configuration: configuration, features: windowFeatures)
        case .browser:
            if let url { model.openExternally(url) }
            return nil
        case .ignore:
            return nil
        }
    }

    func webViewDidClose(_ webView: WKWebView) {
        if role == .popup { window?.close() }
    }

    func webView(_ webView: WKWebView, runOpenPanelWith parameters: WKOpenPanelParameters,
                 initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping @MainActor ([URL]?) -> Void) {
        guard let window else {
            completionHandler(nil)
            return
        }
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = parameters.allowsDirectories
        panel.allowsMultipleSelection = parameters.allowsMultipleSelection
        panel.beginSheetModal(for: window) { response in
            completionHandler(response == .OK ? panel.urls : nil)
        }
    }

    func webView(_ webView: WKWebView, runJavaScriptAlertPanelWithMessage message: String,
                 initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping @MainActor () -> Void) {
        let alert = pageAlert(message, frame: frame)
        alert.addButton(withTitle: "OK")
        runSheet(alert) { _ in completionHandler() }
    }

    func webView(_ webView: WKWebView, runJavaScriptConfirmPanelWithMessage message: String,
                 initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping @MainActor (Bool) -> Void) {
        let alert = pageAlert(message, frame: frame)
        alert.addButton(withTitle: "OK")
        alert.addButton(withTitle: "Cancel")
        runSheet(alert) { completionHandler($0 == .alertFirstButtonReturn) }
    }

    func webView(_ webView: WKWebView, runJavaScriptTextInputPanelWithPrompt prompt: String, defaultText: String?,
                 initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping @MainActor (String?) -> Void) {
        let alert = pageAlert(prompt, frame: frame)
        let field = NSTextField(string: defaultText ?? "")
        field.frame = NSRect(x: 0, y: 0, width: 280, height: 24)
        alert.accessoryView = field
        alert.addButton(withTitle: "OK")
        alert.addButton(withTitle: "Cancel")
        runSheet(alert) { completionHandler($0 == .alertFirstButtonReturn ? field.stringValue : nil) }
    }

    private func pageAlert(_ message: String, frame: WKFrameInfo) -> NSAlert {
        let alert = NSAlert()
        alert.messageText = frame.request.url?.host.map { "\($0) says" } ?? model.displayName
        alert.informativeText = message
        return alert
    }

    private func runSheet(_ alert: NSAlert, completion: @escaping (NSApplication.ModalResponse) -> Void) {
        if let window {
            alert.beginSheetModal(for: window, completionHandler: completion)
        } else {
            completion(alert.runModal())
        }
    }
}
