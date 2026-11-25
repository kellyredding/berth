import AppKit

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuItemValidation {
    private var model: AppModel?
    private var signinMenu: SigninMenuController?
    private var notice: MessageWindowController?
    private var pendingURLs: [URL] = []
    private var appName = "Berth"
    private var termination: DispatchSourceSignal?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        // SIGTERM (`kill <pid>`) quits like ⌘Q, so the socket is taken down.
        signal(SIGTERM, SIG_IGN)
        let termination = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .main)
        termination.setEventHandler { NSApp.terminate(nil) }
        termination.resume()
        self.termination = termination
        NSWindow.allowsAutomaticWindowTabbing = false
        let paths = BerthPaths.current
        let selection = SiteSelection.resolve(
            infoPlist: Bundle.main.object(forInfoDictionaryKey: "BerthSite"),
            environment: ProcessInfo.processInfo.environment
        )
        appName = Bundle.main.object(forInfoDictionaryKey: "CFBundleName") as? String ?? "Berth"
        NSApp.mainMenu = MainMenu.build(appName: appName, target: self)

        switch selection {
        case .template:
            Log.configure(file: paths.templateLog)
            showNotice(
                title: appName,
                message: "This is the Berth template.",
                detail: "Each site gets its own app, copied from this one. Build them with `berth sites build`."
            )
        case .invalid(let problem):
            Log.configure(file: paths.templateLog)
            Log.error(problem)
            showNotice(title: appName, message: "This app does not name a valid site.", detail: problem)
        case .site(let site, let source):
            Log.configure(file: paths.log(site: site))
            Log.info("starting \(site) (from \(source.rawValue)), version \(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "unknown"), pid \(ProcessInfo.processInfo.processIdentifier)")
            let model = AppModel(paths: paths, site: site)
            guard model.start() else {
                NSApp.terminate(nil)
                return
            }
            self.model = model
            if let menu = NSApp.mainMenu, let item = MainMenu.item(MainMenu.signinIdentifier, in: menu) {
                signinMenu = SigninMenuController(
                    item: item, separator: MainMenu.item(MainMenu.signinSeparatorIdentifier, in: menu), model: model
                )
            }
            if !pendingURLs.isEmpty {
                model.openURLs(pendingURLs)
                pendingURLs = []
            }
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        Log.info("quitting")
        model?.stop()
    }

    /// Like a mail client: closing the window leaves the app running.
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    /// The Dock icon brings the window back.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag {
            if let model {
                model.showMainWindow()
            } else {
                notice?.show()
            }
        }
        return true
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        if let model {
            model.openURLs(urls)
        } else {
            pendingURLs.append(contentsOf: urls)
        }
    }

    @objc func showAbout(_ sender: Any?) {
        let build = BuildLabel.text(commit: Bundle.main.object(forInfoDictionaryKey: "BerthBuildCommit"))
        var options: [NSApplication.AboutPanelOptionKey: Any] = [
            .credits: NSAttributedString(
                string: model.map { "\($0.site) · \(build)" } ?? build,
                attributes: [.font: NSFont.systemFont(ofSize: NSFont.smallSystemFontSize),
                             .foregroundColor: NSColor.secondaryLabelColor]
            ),
            .version: "",
        ]
        if let model { options[.applicationName] = model.displayName }
        NSApp.orderFrontStandardAboutPanel(options: options)
        NSApp.activate(ignoringOtherApps: true)
    }

    @objc func showSettings(_ sender: Any?) {
        guard let model else { return }
        SettingsWindowController.show(model: model)
        NSApp.activate(ignoringOtherApps: true)
    }

    func validateMenuItem(_ item: NSMenuItem) -> Bool {
        if item.action == #selector(showSettings(_:)) { return model != nil }
        return true
    }

    private func showNotice(title: String, message: String, detail: String) {
        let window = MessageWindowController(title: title, message: message, detail: detail,
                                             actions: [.init(title: "Quit") { NSApp.terminate(nil) }])
        notice = window
        window.show()
        NSApp.activate(ignoringOtherApps: true)
    }
}

@main
@MainActor
enum BerthMain {
    private static let delegate = AppDelegate()

    static func main() {
        let app = NSApplication.shared
        app.delegate = delegate
        app.run()
    }
}
