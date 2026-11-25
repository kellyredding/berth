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
        check("mail: an email_from step, then okta, each in an account", mail.signin["work"] == [
            SigninStep(flow: "google", item: nil, emailFrom: "op://Work/Example SSO", account: "example.1password.com"),
            SigninStep(flow: "okta", item: "op://Work/Example SSO", emailFrom: nil, account: "example.1password.com"),
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
      with: #""signin":{"me":[{"flow":"okta","item":"op://V/I","account":null}]}"#)))
check("a step without account is a drift", !decodes(siteJSON(#""signin":{}"#,
      with: #""signin":{"me":[{"flow":"okta","item":"op://V/I","email_from":null}]}"#)))
check("a step with every key decodes", decodes(siteJSON(#""signin":{}"#,
      with: #""signin":{"me":[{"flow":"okta","item":"op://V/I","email_from":null,"account":"example.1password.com"}]}"#)))

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
check("userinfo cannot smuggle a host", !keep.keeps(URL(string: "https://mail.example.com@evil.net/")!))
check("an empty keep keeps nothing", !KeepList([]).keeps(host: "mail.example.com"))

func url(_ text: String) -> URL { URL(string: text)! }
typealias Route = LinkPolicy.Route

check("a kept page stays", LinkPolicy.navigation(url("https://mail.example.com/x"), mainFrame: true, commandClick: false, keep: keep) == .app)
check("an outside page goes to the browser",
      LinkPolicy.navigation(url("https://news.example.org/"), mainFrame: true, commandClick: false, keep: keep) == .browser)
check("a ⌘-click on a kept page goes to the browser",
      LinkPolicy.navigation(url("https://mail.example.com/x"), mainFrame: true, commandClick: true, keep: keep) == .browser)
check("an outside subframe loads in place",
      LinkPolicy.navigation(url("https://cdn.example.net/frame"), mainFrame: false, commandClick: false, keep: keep) == .app)
check("mailto goes out", LinkPolicy.navigation(url("mailto:someone@example.com"), mainFrame: true, commandClick: false, keep: keep) == .browser)
check("tel goes out", LinkPolicy.navigation(url("tel:+15555550100"), mainFrame: true, commandClick: false, keep: keep) == .browser)
check("an app scheme goes out", LinkPolicy.navigation(url("zoommtg://example.com/join"), mainFrame: false, commandClick: false, keep: keep) == .browser)
check("about:blank stays", LinkPolicy.navigation(url("about:blank"), mainFrame: true, commandClick: false, keep: keep) == .app)
check("blob stays", LinkPolicy.navigation(url("blob:https://mail.example.com/1"), mainFrame: true, commandClick: false, keep: keep) == .app)
check("file is dropped", LinkPolicy.navigation(url("file:///etc/hosts"), mainFrame: true, commandClick: false, keep: keep) == .ignore)
check("a kept popup opens a second window", LinkPolicy.newWindow(url("https://accounts.example.com/choose"), commandClick: false, keep: keep) == .app)
check("an outside popup goes to the browser", LinkPolicy.newWindow(url("https://docs.example.org/"), commandClick: false, keep: keep) == .browser)
check("a ⌘-clicked target=_blank goes to the browser", LinkPolicy.newWindow(url("https://mail.example.com/x"), commandClick: true, keep: keep) == .browser)
check("a blank popup opens a window the page fills in", LinkPolicy.newWindow(nil, commandClick: false, keep: keep) == .app
      && LinkPolicy.newWindow(url("about:blank"), commandClick: false, keep: keep) == .app)
check("a mailto popup goes out", LinkPolicy.newWindow(url("mailto:someone@example.com"), commandClick: false, keep: keep) == .browser)
check("an outside URL handed to the app goes to the browser",
      LinkPolicy.external(url("https://news.example.org/"), keep: keep) == .browser)
check("a kept URL handed to the app loads", LinkPolicy.external(url("https://mail.example.com/#inbox"), keep: keep) == .app)

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
check("signin.fill parses without reading its detail",
      parsed(#"{"v":1,"event":"signin.fill","ts":1,"detail_data":{"login":"work","steps":[]}}"#) == .success(.signinFill))
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
let refusal = replyObject(Reply.failure(.signinNotImplemented))
check("an error reply is not ok and carries its code",
      refusal?["ok"] as? Bool == false && refusal?["code"] as? String == "unavailable")
check("signin.fill says it is not implemented yet", (refusal?["error"] as? String)?.contains("not implemented yet") == true)

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
