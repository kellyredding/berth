import Foundation

// Everything `signin.fill` knows about Google's and Okta's sign-in pages: the
// selectors as data, and the step model that decides what to do with what a
// page shows. When their markup changes, this file and SigninScript.swift are
// the only places to look. No secret ever enters this model; it knows only
// whether a step has a password or a code.

enum SigninField: String, CaseIterable, Equatable {
    case username, password, code
}

/// How to find and submit one field on a flow's pages.
struct FieldSpec: Equatable {
    /// Tried in order; the first visible match wins.
    let selectors: [String]
    /// Buttons that submit it, tried in order, before `labels`.
    let submit: [String]
    /// Button text that submits it, ignoring case.
    let labels: [String]
}

/// A Google account chooser: an entry whose `attribute` is the email, or a
/// button labelled to use another account.
struct ChooserSpec: Equatable {
    let attribute: String
    let labels: [String]
}

/// A list of verification methods, each a row with its own button. The row
/// is found from the button, so no markup beyond the button's text is assumed.
/// Which method to choose is the step's, from the person's config.
struct MethodSpec: Equatable {
    /// Text of the button on each method's row.
    let buttons: [String]
}

struct FlowSpec: Equatable {
    /// Hosts whose pages belong to the flow.
    let hosts: KeepList
    /// Elements that mark a page as the flow's wherever it is served.
    let markers: [String]
    let username: FieldSpec
    let password: FieldSpec
    let code: FieldSpec
    /// Whether username and password can share a page (Okta's classic widget).
    let together: Bool
    let chooser: ChooserSpec?
    /// Shown by some sign-ins, not every time, before the code.
    let methods: MethodSpec?
    /// Said while the flow waits on its own second factor.
    let waitingReason: String

    func field(_ field: SigninField) -> FieldSpec {
        switch field {
        case .username: return username
        case .password: return password
        case .code: return code
        }
    }

    /// The selectors as the sign-in script takes them.
    var scriptArgument: [String: Any] {
        func fieldArgument(_ spec: FieldSpec) -> [String: Any] {
            ["selectors": spec.selectors, "submit": spec.submit, "labels": spec.labels]
        }
        var argument: [String: Any] = [
            "markers": markers,
            "fields": Dictionary(uniqueKeysWithValues: SigninField.allCases.map { ($0.rawValue, fieldArgument(field($0))) }),
        ]
        argument["chooser"] = chooser.map { ["attribute": $0.attribute, "labels": $0.labels] as [String: Any] } ?? NSNull()
        argument["methods"] = methods.map { ["buttons": $0.buttons] as [String: Any] } ?? NSNull()
        return argument
    }
}

enum SigninFlow: String, Equatable {
    case google, okta

    var spec: FlowSpec {
        switch self {
        case .google: return Self.googleSpec
        case .okta: return Self.oktaSpec
        }
    }

    static let googleSpec = FlowSpec(
        hosts: KeepList(["accounts.google.com"]),
        markers: ["#initialView", "#identifierId", "#identifierNext", "#passwordNext", "#totpPin"],
        username: FieldSpec(selectors: ["#identifierId", "input[type=email]"],
                            submit: ["#identifierNext button", "#identifierNext"], labels: ["Next"]),
        // Google's identifier page also carries a hidden password input,
        // which `together: false` and the visibility test keep out.
        password: FieldSpec(selectors: ["input[name=Passwd]", "input[type=password]"],
                            submit: ["#passwordNext button", "#passwordNext"], labels: ["Next"]),
        code: FieldSpec(selectors: ["input[name=totpPin]", "#totpPin", "input[autocomplete=one-time-code]"],
                        submit: ["#totpNext button", "#totpNext"], labels: ["Next", "Verify"]),
        together: false,
        chooser: ChooserSpec(attribute: "data-identifier", labels: ["Use another account"]),
        methods: nil,
        waitingReason: "waiting for you: finish Google's verification in the app"
    )

    /// The sign-in widget in both its classic and Identity Engine forms.
    static let oktaSpec = FlowSpec(
        hosts: KeepList(["*.okta.com", "*.oktapreview.com", "*.okta-emea.com"]),
        markers: ["#okta-sign-in", "#okta-signin-username", "[data-se=o-form]"],
        username: FieldSpec(selectors: ["input[name=identifier]", "#okta-signin-username", "input[name=username]"],
                            submit: ["#okta-signin-submit", "input[type=submit]", "button[type=submit]"],
                            labels: ["Next", "Sign in", "Verify"]),
        password: FieldSpec(selectors: ["input[name='credentials.passcode'][type=password]", "#okta-signin-password",
                                        "input[name=password]", "input[type=password]"],
                            submit: ["#okta-signin-submit", "input[type=submit]", "button[type=submit]"],
                            labels: ["Verify", "Sign in", "Next"]),
        // The same passcode input, but not a password, on an authenticator
        // page; `answer` on the classic widget's "Enter code" page.
        code: FieldSpec(selectors: ["input[name='credentials.passcode']:not([type=password])", "input[name=answer]",
                                    "input[autocomplete=one-time-code]"],
                        submit: ["input[type=submit]", "button[type=submit]"], labels: ["Verify", "Next"]),
        together: true,
        chooser: nil,
        // Identity Engine's "Verify it's you with a security method" list.
        methods: MethodSpec(buttons: ["Select"]),
        waitingReason: "waiting for you: approve the Okta sign-in"
    )
}

// MARK: - Request

/// One step's values as `signin.fill` carries them. Never printed: its
/// descriptions name the flow and which values are present, nothing more.
struct SigninValues: Equatable, CustomStringConvertible, CustomDebugStringConvertible, CustomReflectable {
    let flow: SigninFlow
    let username: String
    let password: String?
    let code: String?
    /// Not a secret: the verification method the person's config names.
    let method: String?

    init(flow: SigninFlow, username: String, password: String?, code: String?, method: String? = nil) {
        self.flow = flow
        self.username = username
        self.password = password
        self.code = code
        self.method = method
    }

    func value(_ field: SigninField) -> String? {
        switch field {
        case .username: return username
        case .password: return password
        case .code: return code
        }
    }

    var description: String {
        "\(flow.rawValue) step (username, \(password == nil ? "no " : "")password, \(code == nil ? "no " : "")code)"
    }

    var debugDescription: String { description }
    var customMirror: Mirror { Mirror(self, children: [:]) }
}

struct SigninRequest: Equatable, CustomStringConvertible, CustomDebugStringConvertible, CustomReflectable {
    let login: String?
    let steps: [SigninValues]

    var flows: [String] { steps.map(\.flow.rawValue) }

    var description: String { "sign-in \(login ?? "(unnamed)"): \(flows.joined(separator: ", then "))" }
    var debugDescription: String { description }
    var customMirror: Mirror { Mirror(self, children: [:]) }

    /// From `signin.fill`'s detail. A refusal never quotes a value.
    static func parse(_ detail: [String: JSONValue]) -> Result<SigninRequest, RequestError> {
        var login: String?
        switch detail["login"] {
        case nil, .null?: login = nil
        case .string(let text)?: login = text
        default: return .failure(.badRequest("login must be a string"))
        }
        guard case .array(let items)? = detail["steps"], !items.isEmpty else {
            return .failure(.badRequest("steps must be a non-empty list"))
        }
        var steps: [SigninValues] = []
        for (index, item) in items.enumerated() {
            guard case .object(let step) = item else { return .failure(.badRequest("steps[\(index)] must be an object")) }
            guard case .string(let name)? = step["flow"], let flow = SigninFlow(rawValue: name) else {
                return .failure(.badRequest("steps[\(index)].flow must be google or okta"))
            }
            guard case .string(let username)? = step["username"], !username.isEmpty else {
                return .failure(.badRequest("steps[\(index)].username must be a non-empty string"))
            }
            var optional: [String: String] = [:]
            for key in ["password", "code", "method"] {
                switch step[key] {
                case nil, .null?: break
                case .string(let text)? where !text.isEmpty: optional[key] = text
                default: return .failure(.badRequest("steps[\(index)].\(key) must be a non-empty string when given"))
                }
            }
            let unknown = Set(step.keys).subtracting(["flow", "username", "password", "code", "method"])
            if let key = unknown.sorted().first {
                return .failure(.badRequest("steps[\(index)]: unknown key \"\(key)\""))
            }
            steps.append(SigninValues(flow: flow, username: username, password: optional["password"],
                                      code: optional["code"], method: optional["method"]))
        }
        return .success(SigninRequest(login: login, steps: steps))
    }
}

// MARK: - Step model

/// What the sign-in script saw on the page: the host, the first marker found,
/// and for each field the selector of its first visible match.
struct PageObservation: Equatable {
    var host: String?
    var loading: Bool
    var marker: String?
    var username: String?
    var password: String?
    var code: String?
    /// Whether a list of verification methods is showing.
    var methods: Bool
    /// Whether that list has a row matching the step's method.
    var methodOffered: Bool

    init(host: String?, loading: Bool = false, marker: String? = nil,
         username: String? = nil, password: String? = nil, code: String? = nil,
         methods: Bool = false, methodOffered: Bool = false) {
        self.host = host
        self.loading = loading
        self.marker = marker
        self.username = username
        self.password = password
        self.code = code
        self.methods = methods
        self.methodOffered = methodOffered
    }

    /// The script's result, or nil when it is not one.
    init?(script result: Any?, loading: Bool) {
        guard let fields = result as? [String: Any] else { return nil }
        func text(_ key: String) -> String? { fields[key] as? String }
        self.init(host: text("host"), loading: loading, marker: text("marker"),
                  username: text("username"), password: text("password"), code: text("code"),
                  methods: fields["methods"] as? Bool ?? false, methodOffered: fields["methodOffered"] as? Bool ?? false)
    }
}

struct SigninStop: Equatable {
    let step: Int
    let flow: String
    let reason: String
}

struct SigninOutcome: Equatable {
    let completed: [String]
    let stoppedAt: SigninStop?
    let alreadySignedIn: Bool
}

enum SigninDecision: Equatable {
    case wait
    /// Fill these fields, then submit the last one.
    case fill([SigninField])
    /// Pick the account on a Google account chooser.
    case choose
    /// Pick this verification method from a list of them.
    case chooseMethod(String)
    case finish(SigninOutcome)
}

/// The steps of one sign-in, driven by what the page shows at each poll. It
/// fills a field once, waits for the page to move on, and counts a step done
/// once the page has left its flow and stayed away.
struct SigninRun {
    struct Step: Equatable {
        let flow: SigninFlow
        let hasPassword: Bool
        let hasCode: Bool
        /// The verification method to choose when the flow lists them.
        let method: String?

        init(flow: SigninFlow, hasPassword: Bool, hasCode: Bool, method: String? = nil) {
            self.flow = flow
            self.hasPassword = hasPassword
            self.hasCode = hasCode
            self.method = method
        }
    }

    static let timeout: TimeInterval = 120
    /// How long a step's page may take to appear.
    static let arrival: TimeInterval = 30
    /// How long a submitted field may stay on screen before the step stops.
    static let stall: TimeInterval = 15
    /// How long the page must stay off a flow before its step counts as done.
    static let settle: TimeInterval = 1.5

    let steps: [Step]
    let siteHost: String?
    let deadline: Date
    private(set) var index = 0
    private(set) var completed: [String] = []
    /// Why it is waiting on the person at the screen, if it is.
    private(set) var waitingReason: String?
    private var stepStarted: Date
    private var arrived: Date?
    private var sent: [SigninField: Date] = [:]
    private var chooserTried = false
    private var methodChosen: Date?
    private var awaySince: Date?

    init(steps: [Step], siteHost: String?, start: Date) {
        self.steps = steps
        self.siteHost = siteHost?.lowercased()
        deadline = start.addingTimeInterval(Self.timeout)
        stepStarted = start
    }

    var currentFlow: SigninFlow? { index < steps.count ? steps[index].flow : nil }

    mutating func filled(_ fields: [SigninField], at now: Date) {
        for field in fields { sent[field] = now }
    }

    mutating func choseAccount() {
        chooserTried = true
    }

    mutating func choseMethod(at now: Date) {
        methodChosen = now
    }

    mutating func next(_ page: PageObservation?, now: Date) -> SigninDecision {
        guard index < steps.count else { return .finish(outcome(stop: nil)) }
        let step = steps[index]
        let spec = step.flow.spec
        let name = step.flow.rawValue
        if now >= deadline {
            return stop(waitingReason ?? "timed out: the \(name) step did not finish in \(Int(Self.timeout)) s")
        }
        guard let page, !page.loading else { return .wait }

        let inFlow = spec.hosts.keeps(host: page.host) || page.marker != nil
        guard inFlow else { return away(page, step: step, now: now) }
        awaySince = nil
        if arrived == nil { arrived = now }

        if page.code != nil {
            if step.hasCode && sent[.code] == nil { return .fill([.code]) }
            if let at = sent[.code] {
                if now.timeIntervalSince(at) > Self.stall { return stop("the page didn't accept the one-time code on the \(name) code step") }
                return .wait
            }
            waitingReason = "waiting for you: enter the one-time code (1Password has none for this item)"
            return .wait
        }

        if page.methods && page.username == nil && page.password == nil {
            if let at = methodChosen {
                if now.timeIntervalSince(at) > Self.stall {
                    return stop("the page didn't move on from the \(name) verification method list")
                }
                return .wait
            }
            guard let method = step.method else {
                waitingReason = "waiting for you: choose a verification method (this step names none)"
                return .wait
            }
            guard page.methodOffered else {
                waitingReason = "waiting for you: choose a verification method (the list has no \(method))"
                return .wait
            }
            waitingReason = nil
            return .chooseMethod(method)
        }

        let passwordShowing = page.password != nil && (spec.together || page.username == nil)
        if passwordShowing {
            guard step.hasPassword else {
                return stop("the page asked for a password, but this \(name) step gives only the email")
            }
            if let at = sent[.password] {
                if now.timeIntervalSince(at) > Self.stall { return stop("the page didn't accept the password on the \(name) password step") }
                return .wait
            }
            if spec.together && page.username != nil && sent[.username] == nil { return .fill([.username, .password]) }
            return .fill([.password])
        }

        if page.username != nil {
            if let at = sent[.username] {
                if now.timeIntervalSince(at) > Self.stall { return stop("the page didn't move on from the \(name) username step") }
                return .wait
            }
            return .fill([.username])
        }

        if sent.isEmpty {
            if spec.chooser != nil && !chooserTried { return .choose }
            if now.timeIntervalSince(arrived ?? now) > Self.arrival {
                return stop("the page didn't match the \(name) username step: no username field")
            }
            return .wait
        }
        if sent[.password] != nil || sent[.code] != nil {
            waitingReason = spec.waitingReason
        }
        return .wait
    }

    /// The page is not the current step's flow.
    private mutating func away(_ page: PageObservation, step: Step, now: Date) -> SigninDecision {
        let onSite = siteHost != nil && page.host?.lowercased() == siteHost
        if sent.isEmpty && !onSite {
            awaySince = nil
            if now.timeIntervalSince(stepStarted) > Self.arrival {
                return stop("the page didn't match the \(step.flow.rawValue) sign-in: it shows \(page.host ?? "no page")")
            }
            return .wait
        }
        if awaySince == nil { awaySince = now }
        guard now.timeIntervalSince(awaySince!) >= Self.settle else { return .wait }
        if sent.isEmpty {
            // Already on the site: nothing to fill at the first step, and no
            // more to fill once an earlier step got it there.
            return .finish(outcome(stop: nil, alreadySignedIn: completed.isEmpty))
        }
        completed.append(step.flow.rawValue)
        index += 1
        stepStarted = now
        arrived = nil
        sent = [:]
        chooserTried = false
        methodChosen = nil
        awaySince = nil
        waitingReason = nil
        return index < steps.count ? .wait : .finish(outcome(stop: nil))
    }

    private func stop(_ reason: String) -> SigninDecision {
        .finish(outcome(stop: SigninStop(step: index, flow: steps[index].flow.rawValue, reason: reason)))
    }

    private func outcome(stop: SigninStop?, alreadySignedIn: Bool = false) -> SigninOutcome {
        SigninOutcome(completed: completed, stoppedAt: stop, alreadySignedIn: alreadySignedIn)
    }
}

// MARK: - Reply

struct SigninData: Encodable, Equatable {
    let completed: [String]
    let stoppedAt: SigninStop?
    /// Scheme, host and path only: a sign-in page's query can carry a token.
    let url: String?
    let alreadySignedIn: Bool

    enum CodingKeys: String, CodingKey {
        case completed
        case stoppedAt = "stopped_at"
        case url
        case alreadySignedIn = "already_signed_in"
    }

    enum StopKeys: String, CodingKey { case step, flow, reason }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(completed, forKey: .completed)
        if let stoppedAt {
            var stop = container.nestedContainer(keyedBy: StopKeys.self, forKey: .stoppedAt)
            try stop.encode(stoppedAt.step, forKey: .step)
            try stop.encode(stoppedAt.flow, forKey: .flow)
            try stop.encode(stoppedAt.reason, forKey: .reason)
        } else {
            try container.encodeNil(forKey: .stoppedAt)
        }
        try container.encode(url, forKey: .url)
        try container.encode(alreadySignedIn, forKey: .alreadySignedIn)
    }
}
