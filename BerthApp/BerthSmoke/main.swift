import Foundation

// Exercises the Foundation-only model layer: no app, no window server, no
// WebKit. Usage: BerthSmoke <path to fixtures/export.json>

setvbuf(stdout, nil, _IONBF, 0)

var passed = 0
var failures: [String] = []

func check(_ name: String, _ condition: @autoclosure () -> Bool) {
    if condition() {
        passed += 1
        print("ok    \(name)")
    } else {
        failures.append(name)
        print("FAIL  \(name)")
    }
}

// MARK: - Paths

let home = URL(fileURLWithPath: "/Users/someone")
let defaults = BerthPaths(environment: [:], home: home)
check("root defaults to ~/.berth", defaults.root.path == "/Users/someone/.berth")
check("config defaults under root", defaults.configFile.path == "/Users/someone/.berth/config.json")
check("runtime defaults under root", defaults.runtimeDir.path == "/Users/someone/.berth/runtime")
check("a site's socket is under runtime", defaults.socket(site: "mail").path == "/Users/someone/.berth/runtime/mail.sock")
check("its lock sits beside it", defaults.lockFile(site: "mail").path == "/Users/someone/.berth/runtime/mail.sock.lock")
check("a site's log is under runtime/logs", defaults.log(site: "mail").path == "/Users/someone/.berth/runtime/logs/mail.log")
check("the CLI is looked for in ~/.berth/bin, then ~/.local/bin",
      defaults.binaryCandidates.map(\.path) == ["/Users/someone/.berth/bin/berth", "/Users/someone/.local/bin/berth"])
check("the first executable candidate wins",
      defaults.binary { $0 == "/Users/someone/.local/bin/berth" }?.path == "/Users/someone/.local/bin/berth")
check("no executable candidate is none", defaults.binary { _ in false } == nil)

let overridden = BerthPaths(environment: [
    "BERTH_ROOT": "/tmp/b", "BERTH_CONFIG": "/tmp/c.json", "BERTH_RUNTIME_DIR": "/tmp/r", "BERTH_BINARY": "/tmp/bin/berth",
], home: home)
check("BERTH_CONFIG overrides", overridden.configFile.path == "/tmp/c.json")
check("BERTH_RUNTIME_DIR moves the socket", overridden.socket(site: "docs").path == "/tmp/r/docs.sock")
check("BERTH_BINARY is the only candidate", overridden.binaryCandidates.map(\.path) == ["/tmp/bin/berth"])
check("BERTH_ROOT moves the defaults",
      BerthPaths(environment: ["BERTH_ROOT": "/tmp/b"], home: home).socket(site: "docs").path == "/tmp/b/runtime/docs.sock")
check("an empty override is ignored", BerthPaths(environment: ["BERTH_ROOT": ""], home: home) == defaults)

// MARK: - Which site

check("Info.plist names the site", SiteSelection.resolve(infoPlist: "mail", environment: ["BERTH_SITE": "docs"])
      == .site("mail", source: .infoPlist))
check("BERTH_SITE names it in development", SiteSelection.resolve(infoPlist: nil, environment: ["BERTH_SITE": "docs"])
      == .site("docs", source: .environment))
check("an empty BerthSite falls through", SiteSelection.resolve(infoPlist: "", environment: ["BERTH_SITE": "docs"])
      == .site("docs", source: .environment))
check("neither is the template", SiteSelection.resolve(infoPlist: nil, environment: [:]) == .template)
check("a bad site name is refused", {
    if case .invalid = SiteSelection.resolve(infoPlist: "Mail", environment: [:]) { return true }; return false
}())
check("a site name may not start with a hyphen", !SiteSelection.isValidName("-mail"))
check("a 33-character site name is too long", !SiteSelection.isValidName(String(repeating: "a", count: 33)))
check("digits and hyphens are fine", SiteSelection.isValidName("work-2"))

// MARK: - Config export (fixtures/export.json)

let fixturePath = CommandLine.arguments.dropFirst().first
let fixtureData = fixturePath.flatMap { FileManager.default.contents(atPath: $0) }
check("the export fixture is readable", fixtureData != nil)

var fixture: ConfigExport?
do {
    if let fixtureData { fixture = try ConfigExport.decode(fixtureData) }
} catch {
    print("      decode error: \(error)")
}
check("the export fixture decodes", fixture != nil)

if let export = fixture {
    check("version", export.version == 1)
    check("source", export.source == "file")
    check("two sites", export.sites.keys.sorted() == ["docs", "mail"])
    check("no warnings", export.warnings.isEmpty)
    if let mail = export.sites["mail"] {
        check("mail: site and bundle id", mail.site == "mail" && mail.bundleID == "com.kellyredding.berth.mail")
        check("mail: name and url", mail.name == "Mail" && mail.url.absoluteString == "https://mail.example.com/")
        check("mail: keep", mail.keep.patterns == ["mail.example.com", "accounts.example.com", "*.sso.example.com"])
        check("mail: icon", mail.icon == "fixtures/icons/mail.png")
        check("mail: badge", mail.badge?.title == "\\((\\d+)\\)")
        check("mail: handles and mailto",
              mail.handles == ["mailto"] && mail.mailto == "https://mail.example.com/compose?to=%s")
        check("mail: notifications and launch at login", mail.notifications && mail.launchAtLogin)
        check("mail: two logins", mail.signin.keys.sorted() == ["personal", "work"])
        check("mail: a step with an item",
              mail.signin["personal"] == [SigninStep(flow: "google", item: "op://Personal/Example Mail", emailFrom: nil)])
        check("mail: an email_from step, then okta with a method, each in an account", mail.signin["work"] == [
            SigninStep(flow: "google", item: nil, emailFrom: "op://Work/Example SSO", account: "example.1password.com"),
            SigninStep(flow: "okta", item: "op://Work/Example SSO", emailFrom: nil, account: "example.1password.com",
                       method: "Example Authenticator"),
        ])
    } else {
        check("the fixture has mail", false)
    }
    if let docs = export.sites["docs"] {
        check("docs: nulls decode as absent", docs.icon == nil && docs.badge == nil && docs.mailto == nil)
        check("docs: defaults", docs.handles.isEmpty && !docs.notifications && !docs.launchAtLogin && docs.signin.isEmpty)
        check("docs: keep defaults to the url's host", docs.keep.patterns == ["docs.example.com"])
    } else {
        check("the fixture has docs", false)
    }
}

func siteJSON(_ replacing: String = "", with: String = "") -> String {
    let site = #"{"site":"docs","bundle_id":"com.kellyredding.berth.docs","name":"Docs","url":"https://docs.example.com/","keep":["docs.example.com"],"icon":null,"badge":null,"handles":[],"mailto":null,"notifications":false,"launch_at_login":false,"signin":{}}"#
    let body = replacing.isEmpty ? site : site.replacingOccurrences(of: replacing, with: with)
    return #"{"version":1,"source":"starter","path":"x","sites":{"docs":"# + body + #"},"warnings":[]}"#
}

func decodes(_ json: String) -> Bool { (try? ConfigExport.decode(Data(json.utf8))) != nil }

check("a minimal export decodes", decodes(siteJSON()))
check("a missing nullable key is a drift, not an absence", !decodes(siteJSON(#""icon":null,"#, with: "")))
check("a missing launch_at_login is a drift", !decodes(siteJSON(#""launch_at_login":false,"#, with: "")))
check("an http url is refused", !decodes(siteJSON("https://docs", with: "http://docs")))
check("a step without email_from is a drift", !decodes(siteJSON(#""signin":{}"#,
      with: #""signin":{"me":[{"flow":"okta","item":"op://V/I","account":null,"method":null}]}"#)))
check("a step without account is a drift", !decodes(siteJSON(#""signin":{}"#,
      with: #""signin":{"me":[{"flow":"okta","item":"op://V/I","email_from":null,"method":null}]}"#)))
check("a step without method is a drift", !decodes(siteJSON(#""signin":{}"#,
      with: #""signin":{"me":[{"flow":"okta","item":"op://V/I","email_from":null,"account":null}]}"#)))
check("a step with every key decodes", decodes(siteJSON(#""signin":{}"#,
      with: #""signin":{"me":[{"flow":"okta","item":"op://V/I","email_from":null,"account":"example.1password.com","method":"Example Authenticator"}]}"#)))

// MARK: - Keep matching

let keep = KeepList(["mail.example.com", "*.sso.example.com", "Accounts.Example.com"])
check("an exact host is kept", keep.keeps(host: "mail.example.com"))
check("matching ignores case", keep.keeps(host: "MAIL.Example.COM"))
check("patterns are lowercased", keep.keeps(host: "accounts.example.com"))
check("a trailing dot is the same host", keep.keeps(host: "mail.example.com."))
check("a subdomain of an exact host is not kept", !keep.keeps(host: "x.mail.example.com"))
check("*. matches a subdomain", keep.keeps(host: "login.sso.example.com"))
check("*. matches deeper subdomains", keep.keeps(host: "a.b.sso.example.com"))
check("*. does not match the suffix itself", !keep.keeps(host: "sso.example.com"))
check("*. does not match a host merely ending in the suffix's text", !keep.keeps(host: "evilsso.example.com"))
check("*. does not match a lookalike suffix", !keep.keeps(host: "login.sso.example.com.evil.net"))
check("no host is not kept", !keep.keeps(host: nil) && !keep.keeps(host: ""))
check("the port is ignored", keep.keeps(URL(string: "https://mail.example.com:8443/inbox")!))
check("http on a kept host is kept", keep.keeps(URL(string: "http://mail.example.com/")!))
check("a non-web scheme is never kept", !keep.keeps(URL(string: "ftp://mail.example.com/")!))
check("userinfo cannot smuggle a host", !keep.keeps(URL(string: "https://mail.example.com@evil.example.net/")!))
check("an empty keep keeps nothing", !KeepList([]).keeps(host: "mail.example.com"))

func url(_ text: String) -> URL { URL(string: text)! }
typealias Route = LinkPolicy.Route

func route(_ text: String, _ kind: NavigationKind = .link, mainFrame: Bool = true, commandClick: Bool = false) -> Route {
    LinkPolicy.navigation(url(text), kind: kind, mainFrame: mainFrame, commandClick: commandClick, keep: keep)
}

check("a clicked link in scope stays", route("https://mail.example.com/x") == .app)
check("a clicked link out of scope goes to the browser", route("https://news.example.org/") == .browser)
check("a redirect out of scope stays", route("https://accounts.example.org/SetSID", .other) == .app)
check("a form post to another host stays", route("https://login.example.org/acs", .formSubmission) == .app)
check("a form resubmission, a reload and history stay out of scope too",
      [NavigationKind.formResubmission, .reload, .backForward].allSatisfy { route("https://news.example.org/", $0) == .app })
check("a ⌘-click on a kept page goes to the browser", route("https://mail.example.com/x", commandClick: true) == .browser)
check("a ⌘-click goes to the browser whatever started it", route("https://mail.example.com/x", .other, commandClick: true) == .browser)
check("an outside subframe loads in place", route("https://cdn.example.net/frame", mainFrame: false) == .app)
check("mailto goes out", route("mailto:someone@example.com") == .browser)
check("a redirect to a non-web scheme goes out", route("zoommtg://example.com/join", .other) == .browser)
check("tel goes out", route("tel:+15555550100") == .browser)
check("an app scheme goes out", route("zoommtg://example.com/join", mainFrame: false) == .browser)
check("about:blank stays", route("about:blank") == .app)
check("blob stays", route("blob:https://mail.example.com/1") == .app)
check("file is dropped", route("file:///etc/hosts") == .ignore && route("file:///etc/hosts", .other) == .ignore)
check("an unshown popup's out-of-scope redirect leaves",
      LinkPolicy.popupDestination(url("https://news.example.org/"), keep: keep) == .browser)
check("an unshown popup's blank and in-scope pages stay",
      LinkPolicy.popupDestination(url("about:blank"), keep: keep) == .app
        && LinkPolicy.popupDestination(nil, keep: keep) == .app
        && LinkPolicy.popupDestination(url("https://mail.example.com/url?q=x"), keep: keep) == .app)
check("the log gets host and path, never the query",
      LinkPolicy.hostAndPath(url("https://accounts.example.org/SetSID?ssdc=1&token=abc#x")) == "accounts.example.org/SetSID")
check("a kept popup opens a second window", LinkPolicy.newWindow(url("https://accounts.example.com/choose"), commandClick: false, keep: keep) == .app)
check("an outside popup goes to the browser", LinkPolicy.newWindow(url("https://docs.example.org/"), commandClick: false, keep: keep) == .browser)
check("a ⌘-clicked target=_blank goes to the browser", LinkPolicy.newWindow(url("https://mail.example.com/x"), commandClick: true, keep: keep) == .browser)
check("a blank popup opens a window the page fills in", LinkPolicy.newWindow(nil, commandClick: false, keep: keep) == .app
      && LinkPolicy.newWindow(url("about:blank"), commandClick: false, keep: keep) == .app)
check("a mailto popup goes out", LinkPolicy.newWindow(url("mailto:someone@example.com"), commandClick: false, keep: keep) == .browser)
check("an outside URL handed to the app goes to the browser",
      LinkPolicy.external(url("https://news.example.org/"), keep: keep) == .browser)
check("a kept URL handed to the app loads", LinkPolicy.external(url("https://mail.example.com/#inbox"), keep: keep) == .app)

// MARK: - Popup gate

func popupRun(_ events: [(PopupGate) -> (PopupGate, PopupGate.Action)]) -> (PopupGate, [PopupGate.Action]) {
    var gate = PopupGate()
    var actions: [PopupGate.Action] = []
    for event in events {
        let (next, action) = event(gate)
        gate = next
        actions.append(action)
    }
    return (gate, actions)
}

func nav(_ route: Route) -> (PopupGate) -> (PopupGate, PopupGate.Action) {
    { var gate = $0; let action = gate.navigation(route); return (gate, action) }
}

func commit(inScope: Bool) -> (PopupGate) -> (PopupGate, PopupGate.Action) {
    { var gate = $0; let action = gate.committed(inScope: inScope); return (gate, action) }
}

func grace(_ generation: Int) -> (PopupGate) -> (PopupGate, PopupGate.Action) {
    { var gate = $0; let action = gate.graceElapsed(generation); return (gate, action) }
}

let blankThenKept = popupRun([nav(.app), commit(inScope: false), nav(.app), commit(inScope: true), grace(1)])
check("popup: about:blank, then in scope: shown once it settles",
      blankThenKept.1 == [.allow, .none, .allow, .startGrace(generation: 1), .show] && blankThenKept.0.isShown)
let redirector = popupRun([nav(.app), commit(inScope: false), nav(.app), commit(inScope: true), nav(.browser), grace(1)])
check("popup: about:blank, an in-scope redirect, then out of scope: handed off and closed, never shown",
      redirector.1 == [.allow, .none, .allow, .startGrace(generation: 1), .handOffAndClose, .none]
        && redirector.0.state == .closed)
let kept = popupRun([nav(.app), commit(inScope: true), grace(1)])
check("popup: in scope immediately: shown", kept.1 == [.allow, .startGrace(generation: 1), .show] && kept.0.isShown)
let outside = popupRun([nav(.browser), commit(inScope: true), grace(1)])
check("popup: out of scope immediately: handed off and closed",
      outside.1 == [.handOffAndClose, .none, .none] && outside.0.state == .closed)
let dropped = popupRun([nav(.ignore)])
check("popup: a dropped scheme closes it", dropped.1 == [.close] && dropped.0.state == .closed)
let twoPages = popupRun([nav(.app), commit(inScope: true), nav(.app), commit(inScope: true), grace(1), grace(2)])
check("popup: a second in-scope page restarts the grace",
      twoPages.1 == [.allow, .startGrace(generation: 1), .allow, .startGrace(generation: 2), .none, .show])
let afterShown = popupRun([nav(.app), commit(inScope: true), grace(1), nav(.browser), commit(inScope: false)])
check("popup: once shown it routes like any window and stays open",
      afterShown.1.suffix(2) == [.none, .none] && afterShown.0.isShown)

// MARK: - Badge

let badge = BadgeRule(pattern: "\\((\\d+)\\)")
check("the fixture's badge compiles", badge != nil)
check("the count in a title is the badge", badge?.label(for: "Inbox (3) - someone@example.com - Mail") == "3")
check("the first match wins", badge?.label(for: "Inbox (12) - Chat (4)") == "12")
check("no count clears it", badge?.label(for: "Inbox - someone@example.com - Mail") == nil)
check("no title clears it", badge?.label(for: nil) == nil && badge?.label(for: "") == nil)
check("an empty group clears it", BadgeRule(pattern: "\\[(\\d*)\\]")?.label(for: "Inbox []") == nil)
check("an expression without a group is refused", BadgeRule(pattern: "\\d+") == nil)
check("an expression that does not compile is refused", BadgeRule(pattern: "(") == nil)

// MARK: - User agent

let webKitUA = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko)"
check("the suffix names Safari's version and build",
      UserAgent.applicationName(safariVersion: "26.1") == "Version/26.1 Safari/605.1.15")
check("WebKit's own user agent plus the suffix reads as Safari's", UserAgent.full(webKit: webKitUA, safariVersion: "26.1")
      == "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/26.1 Safari/605.1.15")

func plist(_ version: String) -> Data {
    try! PropertyListSerialization.data(fromPropertyList: ["CFBundleShortVersionString": version], format: .xml, options: 0)
}

check("Safari's version comes from its Info.plist", UserAgent.safariVersion(infoPlist: plist("18.6.2")) == "18.6.2")
check("a version that is not one is refused", UserAgent.safariVersion(infoPlist: plist("26.1 beta")) == nil)
check("an empty part is refused", UserAgent.safariVersion(infoPlist: plist("26..1")) == nil)
check("no Info.plist is no version", UserAgent.safariVersion(infoPlist: nil) == nil)
check("garbage is no version", UserAgent.safariVersion(infoPlist: Data("nope".utf8)) == nil)
check("the fallback for macOS 14 is Safari 17", UserAgent.fallbackVersion(osMajor: 14) == "17.0")
check("the fallback for macOS 15 is Safari 18", UserAgent.fallbackVersion(osMajor: 15) == "18.0")
check("the fallback from macOS 26 is the same number", UserAgent.fallbackVersion(osMajor: 26) == "26.0")
check("resolving prefers the Info.plist", UserAgent.resolveSafariVersion(infoPlist: plist("26.1"), osMajor: 15) == "26.1")
check("resolving falls back", UserAgent.resolveSafariVersion(infoPlist: nil, osMajor: 26) == "26.0")

// MARK: - Data store identifier

check("SHA-1 of abc", SHA1.digest(Array("abc".utf8)).map { String(format: "%02x", $0) }.joined()
      == "a9993e364706816aba3e25717850c26c9cd0d89d")
check("SHA-1 across two blocks", SHA1.digest(Array("abcdbcdecdefdefgefghfghighijhijkijkljklmklmnlmnomnopnopq".utf8))
      .map { String(format: "%02x", $0) }.joined() == "84983e441c3bd26ebaae4aa1f95129e5e54670f1")
let dns = UUID(uuidString: "6ba7b810-9dad-11d1-80b4-00c04fd430c8")!
check("a version 5 UUID matches RFC 9562's construction",
      DataStoreID.uuid(namespace: dns, name: "python.org").uuidString == "886313E1-3B8A-5372-9B90-0C9AEE199E5D")
check("a site's data store is stable", DataStoreID.uuid(site: "mail").uuidString == "7464E8EA-D12E-5F89-BDF9-749B4B552DDF")
check("the same site always gets the same store", DataStoreID.uuid(site: "docs") == DataStoreID.uuid(site: "docs"))
check("sites get different stores", DataStoreID.uuid(site: "mail") != DataStoreID.uuid(site: "docs"))
check("a store identifier is never all zeros", DataStoreID.uuid(site: "") != UUID(uuid: (0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0)))

// MARK: - Envelope

func parsed(_ json: String) -> Result<BerthRequest, RequestError> { BerthRequest.parse(Data(json.utf8)) }

func parsedCode(_ json: String) -> ErrorCode? {
    if case .failure(let error) = parsed(json) { return error.code }
    return nil
}

check("status parses", parsed(#"{"v":1,"event":"status","ts":1}"#) == .success(.status))
check("reload parses", parsed(#"{"v":1,"event":"reload","ts":1}"#) == .success(.reload))
check("open without a url brings the app forward", parsed(#"{"v":1,"event":"open","ts":1}"#) == .success(.open(nil)))
check("open with a null url too", parsed(#"{"v":1,"event":"open","ts":1,"detail_data":{"url":null}}"#) == .success(.open(nil)))
check("open with a url parses",
      parsed(#"{"v":1,"event":"open","ts":1,"detail_data":{"url":"https://mail.example.com/#inbox"}}"#)
        == .success(.open(url("https://mail.example.com/#inbox"))))
check("open refuses a non-web url", parsedCode(#"{"v":1,"event":"open","ts":1,"detail_data":{"url":"mailto:a@example.com"}}"#) == .badRequest)
check("open refuses a url that is not a string", parsedCode(#"{"v":1,"event":"open","ts":1,"detail_data":{"url":3}}"#) == .badRequest)
check("signin.fill parses its steps", parsed(#"{"v":1,"event":"signin.fill","ts":1,"detail_data":{"login":"work","steps":[{"flow":"google","username":"someone@example.com"},{"flow":"okta","username":"someone","password":"pw","code":"123456"}]}}"#)
      == .success(.signinFill(SigninRequest(login: "work", steps: [
          SigninValues(flow: .google, username: "someone@example.com", password: nil, code: nil),
          SigninValues(flow: .okta, username: "someone", password: "pw", code: "123456"),
      ]))))
check("signin.fill takes a step's method", parsed(#"{"v":1,"event":"signin.fill","ts":1,"detail_data":{"login":null,"steps":[{"flow":"okta","username":"someone","method":"Example Authenticator"}]}}"#)
      == .success(.signinFill(SigninRequest(login: nil, steps: [
          SigninValues(flow: .okta, username: "someone", password: nil, code: nil, method: "Example Authenticator"),
      ]))))
check("signin.fill reads a null method as none", parsed(#"{"v":1,"event":"signin.fill","ts":1,"detail_data":{"steps":[{"flow":"okta","username":"someone","method":null}]}}"#)
      == .success(.signinFill(SigninRequest(login: nil, steps: [SigninValues(flow: .okta, username: "someone", password: nil, code: nil)]))))
check("signin.fill refuses an empty method",
      parsedCode(#"{"v":1,"event":"signin.fill","ts":1,"detail_data":{"steps":[{"flow":"okta","username":"a","method":""}]}}"#) == .badRequest)
check("signin.fill refuses a method that is not a string",
      parsedCode(#"{"v":1,"event":"signin.fill","ts":1,"detail_data":{"steps":[{"flow":"okta","username":"a","method":3}]}}"#) == .badRequest)
check("signin.fill without steps is bad_request",
      parsedCode(#"{"v":1,"event":"signin.fill","ts":1,"detail_data":{"login":"work","steps":[]}}"#) == .badRequest)
check("an unknown event is bad_request", parsedCode(#"{"v":1,"event":"teleport","ts":1}"#) == .badRequest)
check("another envelope version is bad_request", parsedCode(#"{"v":2,"event":"status","ts":1}"#) == .badRequest)
check("garbage is bad_request", parsedCode("not json") == .badRequest)

func replyObject(_ data: Data) -> [String: Any]? { (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] }

let statusReply = Reply.ok(StatusData(version: "0.1.0", pid: 42, site: "mail", url: "https://mail.example.com/",
                                      title: "Inbox (3)", badge: "3", config: .init(state: .loaded, error: nil)))
let statusObject = replyObject(statusReply)
let statusFields = statusObject?["data"] as? [String: Any]
check("a reply is one line", !statusReply.contains(0x0A))
check("a success reply is ok", statusObject?["ok"] as? Bool == true)
check("status carries site, title and badge",
      statusFields?["site"] as? String == "mail" && statusFields?["title"] as? String == "Inbox (3)" && statusFields?["badge"] as? String == "3")
check("slashes stay unescaped", String(decoding: statusReply, as: UTF8.self).contains("https://mail.example.com/"))
let loadingFields = replyObject(Reply.ok(StatusData(version: "0.1.0", pid: 42, site: "mail", url: nil, title: nil, badge: nil,
                                                    config: .init(state: .loading, error: nil))))?["data"] as? [String: Any]
check("status keeps null keys", loadingFields?["url"] is NSNull && loadingFields?["title"] is NSNull && loadingFields?["badge"] is NSNull)
let loadingConfig = loadingFields?["config"] as? [String: Any]
check("status says the config is still loading",
      loadingConfig?["state"] as? String == "loading" && loadingConfig?["loaded"] as? Bool == false && loadingConfig?["error"] is NSNull)
check("config is loading until the first load finishes", ConfigLoadState(hasConfig: false, finishedFirstLoad: false) == .loading)
check("config failed when the first load gave none", ConfigLoadState(hasConfig: false, finishedFirstLoad: true) == .failed)
check("a live config is loaded", ConfigLoadState(hasConfig: true, finishedFirstLoad: true) == .loaded)

let openFields = replyObject(Reply.ok(OpenData(url: nil, openedIn: .app)))?["data"] as? [String: Any]
check("open replies where it opened, with a null url", openFields?["opened_in"] as? String == "app" && openFields?["url"] is NSNull)
let reloadFields = replyObject(Reply.ok(ReloadData(loaded: false, error: "bad")))?["data"] as? [String: Any]
check("reload replies loaded and error", reloadFields?["loaded"] as? Bool == false && reloadFields?["error"] as? String == "bad")
let refusal = replyObject(Reply.failure(.signinBusy))
check("an error reply is not ok and carries its code",
      refusal?["ok"] as? Bool == false && refusal?["code"] as? String == "unavailable")
check("a second signin.fill is refused while one runs", (refusal?["error"] as? String)?.contains("already being filled") == true)

// MARK: - Sign-in

let google = SigninFlow.google.spec
let okta = SigninFlow.okta.spec
check("google: the identifier page's fields", google.username.selectors == ["#identifierId", "input[type=email]"]
      && google.username.submit.first == "#identifierNext button" && google.username.labels == ["Next"])
check("google: the password and code fields", google.password.selectors.first == "input[name=Passwd]"
      && google.code.selectors.prefix(2) == ["input[name=totpPin]", "#totpPin"])
check("google: lives on accounts.google.com only", google.hosts.keeps(host: "accounts.google.com")
      && !google.hosts.keeps(host: "mail.google.com") && !google.together && google.chooser != nil)
check("okta: both widgets' username and password", okta.username.selectors.prefix(2) == ["input[name=identifier]", "#okta-signin-username"]
      && okta.password.selectors.prefix(2) == ["input[name='credentials.passcode'][type=password]", "#okta-signin-password"])
check("okta: a code is the passcode input that is not a password",
      okta.code.selectors.first == "input[name='credentials.passcode']:not([type=password])" && okta.together)
check("okta: any okta.com tenant", okta.hosts.keeps(host: "example.okta.com") && !okta.hosts.keeps(host: "okta.com"))
check("okta: says what it waits for", okta.waitingReason == "waiting for you: approve the Okta sign-in")
let argument = okta.scriptArgument
check("the script gets every field's selectors as data",
      ((argument["fields"] as? [String: Any])?["password"] as? [String: Any])?["selectors"] as? [String] == okta.password.selectors
        && argument["chooser"] is NSNull && argument["markers"] as? [String] == okta.markers)
check("the script defines berthSignin and returns its result",
      SigninScript.source.contains("const berthSignin = async function (request)") && SigninScript.body.hasSuffix("return await berthSignin(request);"))

let secretValues = SigninValues(flow: .okta, username: "someone@example.com", password: "hunter2-secret", code: "654321")
let secretRequest = SigninRequest(login: "work", steps: [secretValues])
let printed = [String(describing: secretValues), String(reflecting: secretValues), "\(secretRequest)",
               String(reflecting: secretRequest), { var out = ""; dump(secretRequest, to: &out); return out }()].joined(separator: "\n")
check("a sign-in request never prints its values",
      !printed.contains("hunter2-secret") && !printed.contains("654321") && !printed.contains("someone@example.com"))
check("it says which flows and values it carries", "\(secretRequest)" == "sign-in work: okta"
      && "\(secretValues)" == "okta step (username, password, code)")
func signinParseCode(_ detail: String) -> ErrorCode? {
    parsedCode(#"{"v":1,"event":"signin.fill","ts":1,"detail_data":"# + detail + "}")
}
check("signin.fill refuses an unknown flow", signinParseCode(#"{"steps":[{"flow":"saml","username":"a"}]}"#) == .badRequest)
check("signin.fill refuses an empty username", signinParseCode(#"{"steps":[{"flow":"okta","username":""}]}"#) == .badRequest)
check("signin.fill refuses an unknown key", signinParseCode(#"{"steps":[{"flow":"okta","username":"a","otp":"1"}]}"#) == .badRequest)
if case .failure(let error) = parsed(#"{"v":1,"event":"signin.fill","ts":1,"detail_data":{"steps":[{"flow":"okta","username":"a","password":7}]}}"#) {
    check("a refusal names the key, not the value", error.message == "steps[0].password must be a non-empty string when given")
} else {
    check("a bad password is refused", false)
}

let t0 = Date(timeIntervalSince1970: 1_000_000)
func at(_ seconds: TimeInterval) -> Date { t0.addingTimeInterval(seconds) }
func googlePage(_ fields: (username: Bool, password: Bool, code: Bool) = (false, false, false)) -> PageObservation {
    PageObservation(host: "accounts.google.com", marker: "#initialView", username: fields.username ? "#identifierId" : nil,
                    password: fields.password ? "input[name=Passwd]" : nil, code: fields.code ? "#totpPin" : nil)
}
func oktaPage(username: Bool = false, password: Bool = false, code: Bool = false) -> PageObservation {
    PageObservation(host: "example.okta.com", marker: "#okta-sign-in", username: username ? "input[name=identifier]" : nil,
                    password: password ? "#okta-signin-password" : nil, code: code ? "input[name=answer]" : nil)
}
let inbox = PageObservation(host: "mail.example.com")

var personal = SigninRun(steps: [.init(flow: .google, hasPassword: true, hasCode: true)], siteHost: "mail.example.com", start: t0)
check("google: fills the identifier first", personal.next(googlePage((true, false, false)), now: at(1)) == .fill([.username]))
personal.filled([.username], at: at(1))
check("google: waits while the identifier page is still up", personal.next(googlePage((true, false, false)), now: at(2)) == .wait)
check("google: never takes the identifier page's hidden password for the password page",
      personal.next(googlePage((true, true, false)), now: at(2)) == .wait)
check("google: then the password", personal.next(googlePage((false, true, false)), now: at(3)) == .fill([.password]))
personal.filled([.password], at: at(3))
check("google: then the code", personal.next(googlePage((false, false, true)), now: at(4)) == .fill([.code]))
personal.filled([.code], at: at(4))
check("google: waits while the page is loading", personal.next(PageObservation(host: "mail.example.com", loading: true), now: at(5)) == .wait)
check("google: off the flow, waits for it to settle", personal.next(inbox, now: at(5)) == .wait)
check("google: done once the page has left accounts.google.com",
      personal.next(inbox, now: at(7)) == .finish(SigninOutcome(completed: ["google"], stoppedAt: nil, alreadySignedIn: false)))

var work = SigninRun(steps: [.init(flow: .google, hasPassword: false, hasCode: false),
                             .init(flow: .okta, hasPassword: true, hasCode: false)], siteHost: "mail.example.com", start: t0)
check("work: gives google the email", work.next(googlePage((true, false, false)), now: at(1)) == .fill([.username]))
work.filled([.username], at: at(1))
// Each poll looks for the current flow's own markers and fields, so Okta's
// page seen through Google's selectors shows only its host.
let oktaThroughGoogle = PageObservation(host: "example.okta.com")
check("work: google hands off to okta", work.next(oktaThroughGoogle, now: at(2)) == .wait
      && work.next(oktaThroughGoogle, now: at(4)) == .wait && work.completed == ["google"])
check("work: okta's identifier page", work.next(oktaPage(username: true), now: at(4.5)) == .fill([.username]))
work.filled([.username], at: at(4.5))
check("work: okta's password page", work.next(oktaPage(password: true), now: at(5)) == .fill([.password]))
work.filled([.password], at: at(5))
check("work: a push page waits for the person", work.next(oktaPage(), now: at(6)) == .wait
      && work.waitingReason == "waiting for you: approve the Okta sign-in")
check("work: a push never approved stops at the timeout, saying so", work.next(oktaPage(), now: at(121)) == .finish(SigninOutcome(
    completed: ["google"], stoppedAt: SigninStop(step: 1, flow: "okta", reason: "waiting for you: approve the Okta sign-in"),
    alreadySignedIn: false)))

var classic = SigninRun(steps: [.init(flow: .okta, hasPassword: true, hasCode: true)], siteHost: "mail.example.com", start: t0)
check("okta classic: username and password together", classic.next(oktaPage(username: true, password: true), now: at(1))
      == .fill([.username, .password]))
classic.filled([.username, .password], at: at(1))
check("okta: fills a code on an Enter code page", classic.next(oktaPage(code: true), now: at(2)) == .fill([.code]))
check("okta: a password still showing after the stall stops",
      { () -> SigninDecision in var copy = classic; return copy.next(oktaPage(password: true), now: at(17)) }()
        == .finish(SigninOutcome(completed: [], stoppedAt: SigninStop(step: 0, flow: "okta",
            reason: "the page didn't accept the password on the okta password step"), alreadySignedIn: false)))

check("okta: a method list is rows with a Select button, naming no method; google has none",
      okta.methods == MethodSpec(buttons: ["Select"]) && google.methods == nil)
check("the script gets the method list's buttons as data",
      okta.scriptArgument["methods"] as? [String: [String]] == ["buttons": ["Select"]]
        && google.scriptArgument["methods"] is NSNull)
func methodList(offered: Bool) -> PageObservation {
    PageObservation(host: "example.okta.com", marker: "#okta-sign-in", methods: true, methodOffered: offered)
}
func methodRun(_ method: String?) -> SigninRun {
    var run = SigninRun(steps: [.init(flow: .okta, hasPassword: true, hasCode: true, method: method)],
                        siteHost: "mail.example.com", start: t0)
    run.filled([.username, .password], at: at(1))
    return run
}
var listed = methodRun("Example Authenticator")
check("okta: a method list offering the step's method chooses it",
      listed.next(methodList(offered: true), now: at(2)) == .chooseMethod("Example Authenticator"))
listed.choseMethod(at: at(2))
check("okta: chooses it once, then waits for the code page", listed.next(methodList(offered: true), now: at(3)) == .wait)
check("okta: a list that never moves on stops after the stall",
      { () -> SigninDecision in var copy = listed; return copy.next(methodList(offered: true), now: at(18)) }()
        == .finish(SigninOutcome(completed: [], stoppedAt: SigninStop(step: 0, flow: "okta",
            reason: "the page didn't move on from the okta verification method list"), alreadySignedIn: false)))
check("okta: then fills the code", listed.next(oktaPage(code: true), now: at(4)) == .fill([.code]))
var unlisted = methodRun("Example Authenticator")
check("okta: no method list goes straight to the code", unlisted.next(oktaPage(code: true), now: at(2)) == .fill([.code]))
var unnamedUnlisted = methodRun(nil)
check("okta: no method list and no method named goes straight to the code too",
      unnamedUnlisted.next(oktaPage(code: true), now: at(2)) == .fill([.code]))
var notOffered = methodRun("Example Authenticator")
check("okta: a list without the step's method waits for the person", notOffered.next(methodList(offered: false), now: at(2)) == .wait
      && notOffered.waitingReason == "waiting for you: choose a verification method (the list has no Example Authenticator)")
var unnamed = methodRun(nil)
check("okta: a step naming no method leaves the list to the person", unnamed.next(methodList(offered: false), now: at(2)) == .wait
      && unnamed.waitingReason == "waiting for you: choose a verification method (this step names none)")
check("okta: and still fills the code page the person's choice brings", unnamed.next(oktaPage(code: true), now: at(3)) == .fill([.code]))
var lateOffer = methodRun("Example Authenticator")
_ = lateOffer.next(methodList(offered: false), now: at(2))
check("okta: a method offered on a later poll is chosen, and stops being waited on",
      lateOffer.next(methodList(offered: true), now: at(3)) == .chooseMethod("Example Authenticator") && lateOffer.waitingReason == nil)
let pushOnly = SigninRun.Step(flow: .okta, hasPassword: true, hasCode: false, method: "Example Push")
var push = SigninRun(steps: [pushOnly], siteHost: "mail.example.com", start: t0)
push.filled([.username, .password], at: at(1))
check("okta: a named method is chosen whether or not 1Password has a code",
      push.next(methodList(offered: true), now: at(2)) == .chooseMethod("Example Push"))

var onlyEmail = SigninRun(steps: [.init(flow: .google, hasPassword: false, hasCode: false),
                                  .init(flow: .okta, hasPassword: true, hasCode: false)], siteHost: "mail.example.com", start: t0)
onlyEmail.filled([.username], at: at(1))
check("google asking for a password on an email-only step stops", onlyEmail.next(googlePage((false, true, false)), now: at(2))
      == .finish(SigninOutcome(completed: [], stoppedAt: SigninStop(step: 0, flow: "google",
          reason: "the page asked for a password, but this google step gives only the email"), alreadySignedIn: false)))

var noCode = SigninRun(steps: [.init(flow: .google, hasPassword: true, hasCode: false)], siteHost: "mail.example.com", start: t0)
check("a code page without a code waits for the person", noCode.next(googlePage((false, false, true)), now: at(1)) == .wait
      && noCode.waitingReason?.hasPrefix("waiting for you: enter the one-time code") == true)

var signedIn = SigninRun(steps: [.init(flow: .google, hasPassword: true, hasCode: false)], siteHost: "mail.example.com", start: t0)
check("already on the site: waits for it to settle", signedIn.next(inbox, now: at(1)) == .wait)
check("already on the site: nothing to do", signedIn.next(inbox, now: at(3))
      == .finish(SigninOutcome(completed: [], stoppedAt: nil, alreadySignedIn: true)))

var lost = SigninRun(steps: [.init(flow: .google, hasPassword: true, hasCode: false)], siteHost: "mail.example.com", start: t0)
check("another page: waits for the sign-in to appear", lost.next(PageObservation(host: "www.example.org"), now: at(5)) == .wait)
check("another page: stops when it never appears", lost.next(PageObservation(host: "www.example.org"), now: at(31))
      == .finish(SigninOutcome(completed: [], stoppedAt: SigninStop(step: 0, flow: "google",
          reason: "the page didn't match the google sign-in: it shows www.example.org"), alreadySignedIn: false)))

var chooser = SigninRun(steps: [.init(flow: .google, hasPassword: true, hasCode: false)], siteHost: "mail.example.com", start: t0)
check("google: an account chooser is clicked through once", chooser.next(googlePage(), now: at(1)) == .choose)
chooser.choseAccount()
check("google: then waits for a field", chooser.next(googlePage(), now: at(2)) == .wait)
check("google: a page with no field stops after the arrival time", chooser.next(googlePage(), now: at(32))
      == .finish(SigninOutcome(completed: [], stoppedAt: SigninStop(step: 0, flow: "google",
          reason: "the page didn't match the google username step: no username field"), alreadySignedIn: false)))

check("a sign-in starting at google on google's page fills it where it is",
      !SigninStart.reloadFirst(firstFlow: .google, host: "accounts.google.com"))
check("a sign-in starting at google on an okta page goes back to the site first",
      SigninStart.reloadFirst(firstFlow: .google, host: "example.okta.com"))
check("a sign-in on the site itself goes back to the start too, which finds it signed in",
      SigninStart.reloadFirst(firstFlow: .google, host: "mail.example.com"))
check("a sign-in starting at okta on okta's page stays", !SigninStart.reloadFirst(firstFlow: .okta, host: "example.okta.com"))

var remembered = SigninRun(steps: [.init(flow: .google, hasPassword: false, hasCode: false),
                                   .init(flow: .okta, hasPassword: true, hasCode: true)], siteHost: "mail.example.com", start: t0)
check("a remembered account: the chooser is clicked", remembered.next(googlePage(), now: at(1)) == .choose)
remembered.choseAccount()
check("a remembered account: leaving google for okta waits to settle", remembered.next(oktaThroughGoogle, now: at(2)) == .wait)
check("a remembered account: then google counts as done and okta takes over",
      remembered.next(oktaThroughGoogle, now: at(4)) == .wait && remembered.completed == ["google"] && remembered.currentFlow == .okta)
check("a remembered account: okta's page is filled next", remembered.next(oktaPage(username: true, password: true), now: at(5))
      == .fill([.username, .password]))

var skipped = SigninRun(steps: [.init(flow: .google, hasPassword: false, hasCode: false),
                                .init(flow: .okta, hasPassword: true, hasCode: false)], siteHost: "mail.example.com", start: t0)
_ = skipped.next(googlePage((true, false, false)), now: at(1))
skipped.filled([.username], at: at(1))
_ = skipped.next(inbox, now: at(2))
_ = skipped.next(inbox, now: at(4))
check("a later step the site no longer needs ends the sign-in", skipped.next(inbox, now: at(5)) == .wait
      && skipped.next(inbox, now: at(7)) == .finish(SigninOutcome(completed: ["google"], stoppedAt: nil, alreadySignedIn: false)))
check("a fixture page on any host counts by its markers",
      { () -> SigninDecision in
        var run = SigninRun(steps: [.init(flow: .okta, hasPassword: true, hasCode: false)], siteHost: "127.0.0.1", start: t0)
        return run.next(PageObservation(host: "127.0.0.1", marker: "#okta-sign-in", username: "input[name=identifier]"), now: at(1)) }()
        == SigninDecision.fill([.username]))

let signinReply = replyObject(Reply.ok(SigninData(completed: ["google"], stoppedAt: SigninStop(step: 1, flow: "okta", reason: "r"),
                                                  url: "https://example.okta.com/signin", alreadySignedIn: false)))?["data"] as? [String: Any]
check("signin.fill replies completed, stopped_at, url and already_signed_in",
      signinReply?["completed"] as? [String] == ["google"] && (signinReply?["stopped_at"] as? [String: Any])?["flow"] as? String == "okta"
        && (signinReply?["stopped_at"] as? [String: Any])?["step"] as? Int == 1 && signinReply?["already_signed_in"] as? Bool == false)
let doneReply = replyObject(Reply.ok(SigninData(completed: [], stoppedAt: nil, url: nil, alreadySignedIn: true)))?["data"] as? [String: Any]
check("a finished sign-in keeps stopped_at and url as null", doneReply?["stopped_at"] is NSNull && doneReply?["url"] is NSNull)

// MARK: - Signing in from the app

check("File → Sign In with 1Password is hidden without a login", SigninMenuShape(logins: []) == .hidden)
check("one login is a plain item", SigninMenuShape(logins: ["work"]) == .item(login: "work"))
check("several logins are a submenu of their names",
      SigninMenuShape(logins: ["personal", "work"]) == .submenu(logins: ["personal", "work"]))
check("the app runs berth signin for the login, with --json",
      SigninCommand.arguments(site: "mail", login: "work") == ["signin", "mail", "--account", "work", "--json"])
check("its timeout covers the fill and 1Password's approvals", SigninCommand.timeout >= SigninRun.timeout + 60 + 10)

func signinOutput(_ json: String) -> Data { Data(json.utf8) }
check("exit 0 is signed in", SigninCommand.result(status: 0, output: signinOutput(
    #"{"ok": true, "completed": ["google"], "stopped_at": null, "already_signed_in": false}"#), error: Data(), login: "work")
      == .signedIn(already: false))
check("exit 0 with already_signed_in says so", SigninCommand.result(status: 0, output: signinOutput(
    #"{"ok": true, "completed": [], "stopped_at": null, "already_signed_in": true}"#), error: Data(), login: "work")
      == .signedIn(already: true))
check("exit 1 with stopped_at is the reason", SigninCommand.result(status: 1, output: signinOutput(
    #"{"ok": false, "stopped_at": {"step": 1, "flow": "okta", "reason": "waiting for you: approve the Okta sign-in"}, "code": "stopped"}"#),
    error: Data(), login: "work") == .stopped(reason: "waiting for you: approve the Okta sign-in"))
check("exit 4 is 1Password", SigninCommand.result(status: 4, output: signinOutput(
    #"{"ok": false, "error": "1Password declined to give the username", "code": "not_permitted"}"#), error: Data(), login: "work")
      == .failed("1Password didn't approve, or isn't available."))
check("exit 5 is an unknown login", SigninCommand.result(status: 5, output: Data(), error: Data(), login: "school")
      == .failed("There's no login named “school” in this site's config."))
check("anything else is the CLI's message", SigninCommand.result(status: 1, output: signinOutput(
    #"{"ok": false, "error": "a sign-in is already being filled in this app", "code": "unavailable"}"#), error: Data(), login: "work")
      == .failed("Sign-in failed: a sign-in is already being filled in this app"))
check("without JSON, the CLI's last berth: line", SigninCommand.result(status: 3, output: Data(),
    error: Data("filling Mail's sign-in\nberth: mail's app did not reply within 130 s\n".utf8), login: "work")
      == .failed("Sign-in failed: mail's app did not reply within 130 s"))
check("without any message, the status", SigninCommand.result(status: 9, output: Data(), error: Data(), login: "work")
      == .failed("Sign-in failed: berth exited with status 9"))
check("the filler's reply is a result too",
      SigninResult(SigninData(completed: ["google"], stoppedAt: nil, url: nil, alreadySignedIn: false)) == .signedIn(already: false)
        && SigninResult(SigninData(completed: [], stoppedAt: SigninStop(step: 0, flow: "okta", reason: "r"), url: nil,
                                   alreadySignedIn: false)) == .stopped(reason: "r"))

let twoLogins: [String: [SigninStep]] = [
    "work": [SigninStep(flow: "google", item: nil, emailFrom: "op://Work/Example SSO"),
             SigninStep(flow: "okta", item: "op://Work/Example SSO", emailFrom: nil)],
    "personal": [SigninStep(flow: "google", item: "op://Personal/Example Mail", emailFrom: nil)],
]
let mailKeep = KeepList(["mail.example.com", "127.0.0.1"])
func barState(_ signin: [String: [SigninStep]] = twoLogins, host: String? = "accounts.google.com") -> SigninBarState {
    var state = SigninBarState()
    state.configure(name: "Mail", signin: signin, keep: mailKeep)
    state.pageChanged(host: host)
    return state
}

let signedOut = barState()
check("bar: on Google's sign-in, with logins, it offers to sign in", signedOut.display == .offer
      && signedOut.presentation == .init(symbol: "person.badge.key.fill", tone: .normal, message: "Signed out of Mail.",
                                         button: "Sign In with 1Password", spinning: false, dismissible: true))
check("bar: logins are sorted, and the menu lists them", signedOut.logins == ["personal", "work"]
      && signedOut.menu == .submenu(logins: ["personal", "work"]) && signedOut.menuEnabled)
check("bar: any Okta tenant a login uses is a sign-in page", barState(host: "example.okta.com").display == .offer)
check("bar: Okta is not a sign-in page when no login uses it",
      barState(["personal": twoLogins["personal"]!], host: "example.okta.com").display == .hidden)
check("bar: no logins, no bar and no menu item", barState([:]).display == .hidden && barState([:]).menu == .hidden
      && !barState([:]).menuEnabled)
check("bar: the site itself shows none", barState(host: "mail.example.com").display == .hidden
      && barState(host: "mail.example.com").onSite)
var marked = barState(host: "127.0.0.1")
check("bar: a page on another host is not a sign-in page by its host", marked.display == .hidden)
marked.markers(seen: true)
check("bar: but is by a flow's markers", marked.display == .offer && !marked.onSite)
marked.pageChanged(host: "127.0.0.1")
check("bar: the same host keeps its markers until they are looked for again", marked.display == .offer)
marked.pageChanged(host: "mail.example.com")
check("bar: a new host forgets them", marked.display == .hidden && !marked.markerSeen)

var dismissedBar = barState()
dismissedBar.dismiss()
check("bar: × hides it", dismissedBar.display == .hidden)
dismissedBar.pageChanged(host: "example.okta.com")
check("bar: and it stays hidden across sign-in pages", dismissedBar.display == .hidden)
dismissedBar.pageChanged(host: "mail.example.com")
dismissedBar.pageChanged(host: "accounts.google.com")
check("bar: until the page leaves them and comes back", dismissedBar.display == .offer)

var fromApp = barState()
fromApp.launched(login: "work")
check("bar: the app's own sign-in waits for 1Password first", fromApp.display == .waitingFor1Password
      && fromApp.presentation?.message == "Waiting for 1Password…" && fromApp.presentation?.spinning == true
      && fromApp.presentation?.button == nil && fromApp.presentation?.dismissible == false)
check("bar: and the menu is disabled while it runs", !fromApp.menuEnabled && fromApp.menu == .submenu(logins: ["personal", "work"]))
fromApp.fillStarted(flows: ["google", "okta"])
check("bar: then the fill's steps", fromApp.presentation?.message == "Signing in: google (1 of 2)…")
fromApp.progressed(SigninProgress(step: 1, count: 2, flow: "okta"))
check("bar: step by step", fromApp.presentation?.message == "Signing in: okta (2 of 2)…")
fromApp.progressed(SigninProgress(step: 1, count: 2, flow: "okta", waitingReason: "waiting for you: approve the Okta sign-in"))
check("bar: and what it waits on", fromApp.presentation?.message == "Waiting for you: approve the Okta sign-in")
fromApp.fillFinished(.signedIn(already: false))
check("bar: signed in", fromApp.presentation?.message == "Signed in to Mail." && fromApp.presentation?.tone == .success
      && fromApp.isRunning)
fromApp.cliFinished(.signedIn(already: false))
fromApp.pageChanged(host: "mail.example.com")
check("bar: still says so on the site, briefly", fromApp.display == .result(.signedIn(already: false)) && fromApp.menuEnabled)
fromApp.expireSuccess()
check("bar: then hides", fromApp.display == .hidden)

var fromTerminal = barState(host: "mail.example.com")
fromTerminal.fillStarted(flows: ["google"])
check("bar: a terminal's sign-in shows its progress, with no wait for 1Password",
      fromTerminal.presentation?.message == "Signing in: google (1 of 1)…" && fromTerminal.isRunning && !fromTerminal.menuEnabled)
fromTerminal.fillFinished(.signedIn(already: true))
check("bar: already signed in says so", fromTerminal.presentation?.message == "Already signed in to Mail." && !fromTerminal.isRunning)

var stopped = barState()
stopped.launched(login: "work")
stopped.fillStarted(flows: ["google", "okta"])
stopped.fillFinished(.stopped(reason: "the page didn't accept the password on the okta password step"))
check("bar: a stop shows while the CLI finishes, with nothing to click",
      stopped.presentation?.button == nil && stopped.presentation?.dismissible == false)
stopped.cliFinished(.stopped(reason: "the page didn't accept the password on the okta password step"))
stopped.expireSuccess()
check("bar: a stop stays, offering to try again",
      stopped.presentation == .init(symbol: "exclamationmark.triangle.fill", tone: .warning,
                                    message: "Sign-in stopped: the page didn't accept the password on the okta password step",
                                    button: "Try Again", spinning: false, dismissible: true))
stopped.pageChanged(host: "example.okta.com")
check("bar: across sign-in pages", stopped.display == .result(.stopped(reason: "the page didn't accept the password on the okta password step")))
stopped.pageChanged(host: "mail.example.com")
check("bar: until the page reaches the site", stopped.display == .hidden)

var declined = barState(host: "mail.example.com")
declined.launched(login: "personal")
declined.cliFinished(.failed("1Password didn't approve, or isn't available."))
check("bar: a CLI error shows even on the site", declined.presentation?.message == "1Password didn't approve, or isn't available."
      && declined.presentation?.button == "Try Again")
declined.pageChanged(host: "mail.example.com")
check("bar: and stays until dismissed", declined.display == .result(.failed("1Password didn't approve, or isn't available.")))
declined.dismiss()
check("bar: × clears it", declined.display == .hidden)
var retried = barState()
retried.cliFinished(.failed("Sign-in failed: x"))
retried.launched(login: "work")
check("bar: trying again replaces it", retried.display == .waitingFor1Password)

// MARK: - Small rules

check("no build commit is a development build", BuildLabel.text(commit: nil) == "development build")
check("a blank build commit is a development build", BuildLabel.text(commit: " ") == "development build")
check("a build commit is shown", BuildLabel.text(commit: "abc123def456") == "build abc123def456")

check("zoom in steps up", PageZoom.zoomIn(from: 1.0) == 1.15)
check("zoom out steps down", PageZoom.zoomOut(from: 1.0) == 0.85)
check("zoom in stops at the top", PageZoom.zoomIn(from: 3.0) == 3.0)
check("zoom out stops at the bottom", PageZoom.zoomOut(from: 0.5) == 0.5)
check("an off-level zoom steps to the next level", PageZoom.zoomIn(from: 1.1) == 1.15 && PageZoom.zoomOut(from: 1.1) == 1.0)

check("launch at login registers on first launch when configured",
      LaunchAtLoginRule.shouldRegister(configured: true, decided: false, status: .notRegistered))
check("not when the config leaves it off", !LaunchAtLoginRule.shouldRegister(configured: false, decided: false, status: .notRegistered))
check("not once the user has chosen", !LaunchAtLoginRule.shouldRegister(configured: true, decided: true, status: .notRegistered))
check("not when it is already on", !LaunchAtLoginRule.shouldRegister(configured: true, decided: false, status: .enabled))
check("an existing login item counts as a choice",
      LaunchAtLoginRule.statusDecides(.enabled) && LaunchAtLoginRule.statusDecides(.requiresApproval)
        && !LaunchAtLoginRule.statusDecides(.notRegistered))

let downloads = URL(fileURLWithPath: "/Users/someone/Downloads")
check("a free name is kept", DownloadName.unique("report.pdf", in: downloads) { _ in false }.lastPathComponent == "report.pdf")
let taken: Set<String> = ["report.pdf", "report 2.pdf", "notes"]
check("a taken name is numbered", DownloadName.unique("report.pdf", in: downloads) { taken.contains($0.lastPathComponent) }
      .lastPathComponent == "report 3.pdf")
check("a name without an extension is numbered", DownloadName.unique("notes", in: downloads) { taken.contains($0.lastPathComponent) }
      .lastPathComponent == "notes 2")
check("slashes cannot leave the folder", DownloadName.sanitize("../../etc/passwd") == "-..-etc-passwd")
check("a hidden name is made visible", DownloadName.sanitize(".profile") == "profile")
check("an empty name has a fallback", DownloadName.sanitize("  ") == "download" && DownloadName.sanitize("...") == "download")

// MARK: - Process runner (the CLI's error path)

let runner = ProcessRunner(defaultTimeout: 5)
let echoed = try? await runner.run(executable: URL(fileURLWithPath: "/bin/echo"), arguments: ["hi"])
check("a subprocess's stdout is returned", echoed.map { String(decoding: $0, as: UTF8.self) } == "hi\n")
do {
    _ = try await runner.run(executable: URL(fileURLWithPath: "/bin/sh"), arguments: ["-c", "echo 'config is invalid' >&2; exit 1"])
    check("a failing subprocess throws", false)
} catch {
    check("a failing subprocess reports its stderr", error.localizedDescription == "config is invalid")
}
do {
    _ = try await runner.run(executable: URL(fileURLWithPath: "/bin/sleep"), arguments: ["5"], timeout: 0.2)
    check("a slow subprocess times out", false)
} catch {
    check("a slow subprocess times out", (error as? ProcessRunError).map { if case .timedOut = $0 { return true }; return false } ?? false)
}
do {
    _ = try await runner.run(executable: URL(fileURLWithPath: "/nonexistent/berth"), arguments: [])
    check("a missing binary fails to launch", false)
} catch {
    check("a missing binary fails to launch", (error as? ProcessRunError).map { if case .launchFailed = $0 { return true }; return false } ?? false)
}
let given = try? await runner.run(executable: URL(fileURLWithPath: "/bin/sh"), arguments: ["-c", "printf '%s|%s' \"$PATH\" \"$BERTH_ROOT\""],
                                  environment: ["PATH": "/opt/homebrew/bin:/usr/bin", "BERTH_ROOT": "/tmp/b"])
check("a subprocess gets the environment it is given",
      given.map { String(decoding: $0, as: UTF8.self) } == "/opt/homebrew/bin:/usr/bin|/tmp/b")

// MARK: - The CLI's environment

check("from the Dock, the CLI's PATH finds Homebrew first, then the system",
      CLIEnvironment.path(inherited: "/usr/bin:/bin:/usr/sbin:/sbin") == "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin")
check("an inherited PATH keeps its order between Homebrew's and the system's",
      CLIEnvironment.path(inherited: "/Users/someone/.local/bin:/usr/local/bin:/opt/x/bin")
        == "/opt/homebrew/bin:/usr/local/bin:/Users/someone/.local/bin:/opt/x/bin:/usr/bin:/bin:/usr/sbin:/sbin")
check("no inherited PATH, or empty parts, still gives the whole PATH",
      CLIEnvironment.path(inherited: nil) == "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"
        && CLIEnvironment.path(inherited: "::") == CLIEnvironment.path(inherited: nil))
let childEnvironment = CLIEnvironment.child(of: ["PATH": "/usr/bin:/bin", "HOME": "/Users/someone", "BERTH_ROOT": "/tmp/b",
                                                 "BERTH_CONFIG": "/tmp/c.json", "BERTH_BINARY": "/tmp/bin/berth"])
check("the CLI gets the app's BERTH_* paths and the rest of its environment",
      childEnvironment["BERTH_ROOT"] == "/tmp/b" && childEnvironment["BERTH_CONFIG"] == "/tmp/c.json"
        && childEnvironment["BERTH_BINARY"] == "/tmp/bin/berth" && childEnvironment["HOME"] == "/Users/someone"
        && childEnvironment["PATH"] == "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"
        && childEnvironment.count == 5)

// MARK: - Reload coalescing

actor RunCounter {
    private(set) var count = 0
    func next() -> Int { count += 1; return count }
}

let quickRuns = RunCounter()
let quick = ReloadCoalescer(window: 0.05) { await quickRuns.next() }
async let firstRequest = quick.request()
async let secondRequest = quick.request()
async let thirdRequest = quick.request()
let burst = await [firstRequest, secondRequest, thirdRequest]
check("requests within the window share one reload", burst == [1, 1, 1])
let afterBurst = await quick.request()
check("a request after the window gets its own reload", afterBurst == 2)

print("")
if failures.isEmpty {
    print("\(passed) checks passed")
    exit(0)
} else {
    print("\(failures.count) of \(passed + failures.count) checks FAILED:")
    for name in failures { print("  \(name)") }
    exit(1)
}
