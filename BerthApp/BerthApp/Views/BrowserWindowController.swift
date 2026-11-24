import AppKit
import WebKit

/// One window showing the site: the main window, or a second window for an
/// in-scope popup. Every link decision goes through LinkPolicy with the
/// site's current `keep`.
@MainActor
final class BrowserWindowController: NSWindowController, NSWindowDelegate, WKNavigationDelegate, WKUIDelegate,
    NSMenuItemValidation {
    enum Role { case main, popup }

    let role: Role
    let webView: WKWebView
    private unowned let model: AppModel
    private let findBar = FindBar()
    private var findBarHeight: NSLayoutConstraint!
    private var observations: [NSKeyValueObservation] = []
    private var hasLoadedPage = false

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
        layOut(in: window)

        switch role {
        case .main:
            let name = "Berth.\(model.site)"
            window.center()
            window.setFrameUsingName(name)
            window.setFrameAutosaveName(name)
        case .popup:
            window.center()
        }

        observations.append(webView.observe(\.title, options: [.initial, .new]) { [weak self] _, _ in
            MainActor.assumeIsolated { self?.titleChanged() }
        })
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

    private func layOut(in window: NSWindow) {
        let container = NSView()
        findBar.isHidden = true
        findBar.onFind = { [weak self] text, backwards in self?.find(text, backwards: backwards) }
        findBar.onClose = { [weak self] in self?.closeFindBar() }
        for view in [findBar, webView] as [NSView] {
            view.translatesAutoresizingMaskIntoConstraints = false
            container.addSubview(view)
        }
        findBarHeight = findBar.heightAnchor.constraint(equalToConstant: 0)
        NSLayoutConstraint.activate([
            findBar.topAnchor.constraint(equalTo: container.topAnchor),
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
        let commandClick = navigationAction.navigationType == .linkActivated
            && navigationAction.modifierFlags.contains(.command)
        let route = LinkPolicy.navigation(url, mainFrame: navigationAction.targetFrame?.isMainFrame ?? true,
                                          commandClick: commandClick, keep: model.keep)
        switch route {
        case .app:
            decisionHandler(.allow)
        case .browser:
            decisionHandler(.cancel)
            if let url { model.openExternally(url) }
            closeIfNeverLoaded()
        case .ignore:
            decisionHandler(.cancel)
            Log.info("dropped a navigation to \(url?.scheme ?? "no"): URL")
            closeIfNeverLoaded()
        }
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
        hasLoadedPage = true
        if role == .main { model.mainPageFinished(webView.url) }
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

    /// A popup whose first page went to the browser would stay blank.
    private func closeIfNeverLoaded() {
        guard role == .popup, !hasLoadedPage else { return }
        window?.close()
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
