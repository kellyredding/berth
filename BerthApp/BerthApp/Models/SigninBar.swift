import Foundation

// Signing in from inside a site app: File → Sign In with 1Password and the
// bar above the page. The app runs `berth signin SITE --account LOGIN --json`,
// which reads 1Password and sends the values back over the app's own socket
// as `signin.fill`. These are the rules for when each appears and what it
// says; the views only draw them. No secret reaches this file: it knows
// login names, flows and the filler's progress.

/// Where a fill is, as SigninFiller reports it.
struct SigninProgress: Equatable {
    /// Zero-based.
    let step: Int
    let count: Int
    let flow: String
    /// Why it is waiting on the person, if it is.
    let waitingReason: String?

    init(step: Int, count: Int, flow: String, waitingReason: String? = nil) {
        self.step = step
        self.count = count
        self.flow = flow
        self.waitingReason = waitingReason
    }
}

/// How a sign-in ended, from the filler's reply or from the CLI.
enum SigninResult: Equatable {
    case signedIn(already: Bool)
    /// The filler stopped; the person finishes by hand.
    case stopped(reason: String)
    /// The CLI failed before or around the fill; shown as it is.
    case failed(String)

    init(_ data: SigninData) {
        if let stop = data.stoppedAt {
            self = .stopped(reason: stop.reason)
        } else {
            self = .signedIn(already: data.alreadySignedIn)
        }
    }

    var succeeded: Bool {
        if case .signedIn = self { return true }
        return false
    }
}

/// `berth signin` as the app runs it, and what its `--json` output and exit
/// status mean (docs/contract.md, "CLI exit codes").
enum SigninCommand {
    /// Above the fill's 120 s and the CLI's 130 s wait for it, plus up to 60 s
    /// for each 1Password approval.
    static let timeout: TimeInterval = 240

    static func arguments(site: String, login: String) -> [String] {
        ["signin", site, "--account", login, "--json"]
    }

    static func result(status: Int32, output: Data, error: Data, login: String) -> SigninResult {
        let json = (try? JSONSerialization.jsonObject(with: output)) as? [String: Any]
        switch status {
        case 0:
            return .signedIn(already: json?["already_signed_in"] as? Bool ?? false)
        case 4:
            return .failed("1Password didn't approve, or isn't available.")
        case 5:
            return .failed("There's no login named “\(login)” in this site's config.")
        default:
            if status == 1, let stop = json?["stopped_at"] as? [String: Any], let reason = stop["reason"] as? String {
                return .stopped(reason: reason)
            }
            return .failed("Sign-in failed: \(message(json: json, error: error, status: status))")
        }
    }

    /// The CLI's own message: its JSON `error`, else its last `berth:` line
    /// on stderr. Neither ever holds a secret.
    private static func message(json: [String: Any]?, error: Data, status: Int32) -> String {
        if let text = json?["error"] as? String, !text.isEmpty { return text }
        let lines = String(decoding: error, as: UTF8.self).split(separator: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        if let line = lines.last(where: { $0.hasPrefix("berth: ") }) { return String(line.dropFirst("berth: ".count)) }
        return lines.last ?? "berth exited with status \(status)"
    }
}

/// File → Sign In with 1Password: hidden without a login, a plain item with
/// one, a submenu of login names with several.
enum SigninMenuShape: Equatable {
    case hidden
    case item(login: String)
    case submenu(logins: [String])

    static let title = "Sign In with 1Password"

    init(logins: [String]) {
        switch logins.count {
        case 0: self = .hidden
        case 1: self = .item(login: logins[0])
        default: self = .submenu(logins: logins)
        }
    }
}

/// The sign-in bar's state: the site's logins, the page, and any sign-in
/// running or just ended. Every event is a mutation; `display` and
/// `presentation` say what shows.
struct SigninBarState: Equatable {
    enum Display: Equatable {
        case hidden
        /// A sign-in page, nothing running: offer to sign in.
        case offer
        /// The app ran the CLI, and no fill has arrived yet.
        case waitingFor1Password
        case progress(SigninProgress)
        case result(SigninResult)
    }

    enum Tone: Equatable { case normal, success, warning }

    /// What the bar draws.
    struct Presentation: Equatable {
        let symbol: String
        let tone: Tone
        let message: String
        /// The sign-in button's title, or nil for none. With several logins
        /// it pulls down a list of them.
        let button: String?
        let spinning: Bool
        let dismissible: Bool
    }

    /// How long "Signed in" stays before the bar hides.
    static let successDuration: TimeInterval = 2

    private(set) var name = ""
    /// Sorted, since the export's object order is not kept.
    private(set) var logins: [String] = []
    /// The flows the logins use; only their pages offer a sign-in.
    private(set) var flows: [SigninFlow] = []
    private(set) var keep = KeepList([])
    private(set) var host: String?
    /// Whether the page shows a flow's marker elements: a sign-in page on a
    /// host its flow does not list (a custom domain, a local fixture).
    private(set) var markerSeen = false
    /// The login the app's own CLI run is for, until the CLI exits.
    private(set) var launching: String?
    private(set) var filling = false
    private(set) var progress: SigninProgress?
    private(set) var result: SigninResult?
    private(set) var dismissed = false

    init() {}

    var isRunning: Bool { launching != nil || filling }

    var menu: SigninMenuShape { SigninMenuShape(logins: logins) }

    var menuEnabled: Bool { !logins.isEmpty && !isRunning }

    var onSigninPage: Bool {
        guard !logins.isEmpty else { return false }
        return markerSeen || flows.contains { $0.spec.hosts.keeps(host: host) }
    }

    /// The site itself: a kept host that is not a sign-in page.
    var onSite: Bool { !onSigninPage && keep.keeps(host: host) }

    var display: Display {
        if filling, let progress { return .progress(progress) }
        if let result { return .result(result) }
        if launching != nil { return .waitingFor1Password }
        if onSigninPage && !dismissed { return .offer }
        return .hidden
    }

    var presentation: Presentation? {
        let signIn = SigninMenuShape.title
        switch display {
        case .hidden:
            return nil
        case .offer:
            return Presentation(symbol: "person.badge.key.fill", tone: .normal, message: "Signed out of \(name).",
                                button: signIn, spinning: false, dismissible: true)
        case .waitingFor1Password:
            return Presentation(symbol: "key.fill", tone: .normal, message: "Waiting for 1Password…",
                                button: nil, spinning: true, dismissible: false)
        case .progress(let progress):
            let message = progress.waitingReason.map(Self.sentence)
                ?? "Signing in: \(progress.flow) (\(progress.step + 1) of \(progress.count))…"
            return Presentation(symbol: "key.fill", tone: .normal, message: message,
                                button: nil, spinning: true, dismissible: false)
        case .result(.signedIn(let already)):
            return Presentation(symbol: "checkmark.circle.fill", tone: .success,
                                message: already ? "Already signed in to \(name)." : "Signed in to \(name).",
                                button: nil, spinning: false, dismissible: !isRunning)
        case .result(.stopped(let reason)):
            return Presentation(symbol: "exclamationmark.triangle.fill", tone: .warning,
                                message: "Sign-in stopped: \(reason)", button: isRunning ? nil : "Try Again",
                                spinning: false, dismissible: !isRunning)
        case .result(.failed(let message)):
            return Presentation(symbol: "exclamationmark.triangle.fill", tone: .warning, message: message,
                                button: isRunning ? nil : "Try Again", spinning: false, dismissible: !isRunning)
        }
    }

    // MARK: - Events

    mutating func configure(name: String, signin: [String: [SigninStep]], keep: KeepList) {
        let before = onSite
        self.name = name
        logins = signin.keys.sorted()
        var used: [SigninFlow] = []
        for flow in signin.values.flatMap({ $0 }).compactMap({ SigninFlow(rawValue: $0.flow) }) where !used.contains(flow) {
            used.append(flow)
        }
        flows = used
        self.keep = keep
        settle(wasOnSite: before)
    }

    /// The main frame's page changed. A new host forgets the last page's
    /// markers until they are looked for again.
    mutating func pageChanged(host newHost: String?) {
        let before = onSite
        if newHost?.lowercased() != host?.lowercased() { markerSeen = false }
        host = newHost
        settle(wasOnSite: before)
    }

    mutating func markers(seen: Bool) {
        let before = onSite
        markerSeen = seen
        settle(wasOnSite: before)
    }

    /// The app ran `berth signin` for this login.
    mutating func launched(login: String) {
        launching = login
        result = nil
        dismissed = false
    }

    /// A `signin.fill` arrived, from the app's own run or a terminal's.
    mutating func fillStarted(flows: [String]) {
        filling = true
        progress = flows.first.map { SigninProgress(step: 0, count: flows.count, flow: $0) }
        result = nil
        dismissed = false
    }

    mutating func progressed(_ progress: SigninProgress) {
        guard filling else { return }
        self.progress = progress
    }

    mutating func fillFinished(_ result: SigninResult) {
        filling = false
        progress = nil
        self.result = result
    }

    /// The app's CLI run ended; its result includes the fill's, and covers
    /// what happened before one (1Password, an unknown login).
    mutating func cliFinished(_ result: SigninResult) {
        launching = nil
        self.result = result
    }

    /// The bar's ×: it stays away until the page next leaves the sign-in
    /// pages, or a sign-in starts.
    mutating func dismiss() {
        guard !isRunning else { return }
        result = nil
        dismissed = onSigninPage
    }

    /// "Signed in" has had its moment.
    mutating func expireSuccess() {
        guard !isRunning, result?.succeeded == true else { return }
        result = nil
    }

    private mutating func settle(wasOnSite: Bool) {
        if !onSigninPage { dismissed = false }
        // Reaching the site means the person finished: a stop or failure no
        // longer applies.
        if onSite && !wasOnSite && !isRunning, let result, !result.succeeded {
            self.result = nil
        }
    }

    /// "waiting for you: …" as a sentence: capitalized.
    private static func sentence(_ text: String) -> String {
        text.prefix(1).uppercased() + text.dropFirst()
    }
}
