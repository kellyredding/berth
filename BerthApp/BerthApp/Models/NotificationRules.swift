import Foundation

/// `UNAuthorizationStatus`, without UserNotifications. Provisional and
/// ephemeral authorization both post, so both read as authorized.
enum NotificationAuthorization: Equatable {
    case notDetermined, denied, authorized

    /// What the page's `Notification.permission` says.
    var pagePermission: NotificationPermission {
        switch self {
        case .notDetermined: return .default
        case .denied: return .denied
        case .authorized: return .granted
        }
    }
}

/// The web's `NotificationPermission` strings.
enum NotificationPermission: String, Equatable {
    case `default`, denied, granted
}

/// One message from the page's notification shim, checked and clipped. The
/// shim's `data` and `icon` never leave the page.
enum NotificationMessage: Equatable {
    /// `Notification.requestPermission()`.
    case request
    case show(NotificationContent)
    /// `notification.close()`.
    case close(id: String, tag: String)

    static let maxTitle = 200
    static let maxBody = 1000
    static let maxTag = 256
    static let maxID = 64

    /// A refusal names the key at fault, never a value.
    static func parse(_ body: Any?) -> Result<NotificationMessage, NotificationRefusal> {
        guard let object = body as? [String: Any], let op = object["op"] as? String else {
            return .failure(.badMessage("not an object with an op"))
        }
        switch op {
        case "request":
            return .success(.request)
        case "show":
            guard let id = identifier(object["id"]) else { return .failure(.badMessage("id")) }
            guard let title = object["title"] as? String else { return .failure(.badMessage("title")) }
            guard let body = optionalString(object["body"]) else { return .failure(.badMessage("body")) }
            guard let tag = tag(object["tag"]) else { return .failure(.badMessage("tag")) }
            guard let silent = optionalBool(object["silent"]) else { return .failure(.badMessage("silent")) }
            return .success(.show(NotificationContent(
                id: id, title: clip(title, to: maxTitle), body: clip(body, to: maxBody), tag: tag, silent: silent
            )))
        case "close":
            guard let id = identifier(object["id"]) else { return .failure(.badMessage("id")) }
            guard let tag = tag(object["tag"]) else { return .failure(.badMessage("tag")) }
            return .success(.close(id: id, tag: tag))
        default:
            return .failure(.badMessage("op"))
        }
    }

    /// Longer text is cut to `limit` characters, the last an ellipsis.
    static func clip(_ text: String, to limit: Int) -> String {
        guard text.count > limit else { return text }
        return String(text.prefix(limit - 1)) + "…"
    }

    private static func identifier(_ value: Any?) -> String? {
        guard let id = value as? String, !id.isEmpty, id.count <= maxID else { return nil }
        return id
    }

    private static func tag(_ value: Any?) -> String? {
        guard let tag = optionalString(value), tag.count <= maxTag else { return nil }
        return tag
    }

    private static func optionalString(_ value: Any?) -> String? {
        if value == nil || value is NSNull { return "" }
        return value as? String
    }

    /// JSON's booleans only: Foundation would read the number 1 as true.
    private static func optionalBool(_ value: Any?) -> Bool? {
        if value == nil || value is NSNull { return false }
        guard let number = value as? NSNumber, CFGetTypeID(number) == CFBooleanGetTypeID() else { return nil }
        return number.boolValue
    }
}

struct NotificationContent: Equatable {
    /// The shim's own id for the `Notification` object, unique per page load.
    let id: String
    let title: String
    let body: String
    /// Empty when the page gave none.
    let tag: String
    let silent: Bool
}

/// Why a message was not acted on. Never carries the title or body.
enum NotificationRefusal: Error, Equatable {
    case off
    case subframe
    case host(String?)
    case badMessage(String)
    case rate
    case notAllowed

    var logLine: String {
        switch self {
        case .off: return "notification: refused (this site's notifications are off)"
        case .subframe: return "notification: refused (from a subframe)"
        case .host(let host): return "notification: refused (\(host ?? "no host") is not in keep)"
        case .badMessage(let key): return "notification: refused (bad message: \(key))"
        case .rate: return "notification: dropped (more than \(NotificationRateLimit.perSecond) a second or \(NotificationRateLimit.perMinute) a minute)"
        case .notAllowed: return "notification: not posted (macOS hasn't allowed notifications)"
        }
    }
}

/// Which messages the app hears at all: the site turns notifications on, and
/// the message comes from the main frame of a page on a kept host.
enum NotificationGate {
    static func check(enabled: Bool, mainFrame: Bool, host: String?, keep: KeepList) -> NotificationRefusal? {
        guard enabled else { return .off }
        guard mainFrame else { return .subframe }
        guard keep.keeps(host: host) else { return .host(host) }
        return nil
    }
}

/// At most a few notifications a second and a few dozen a minute; the rest
/// are dropped, so a page in a loop cannot flood Notification Center.
struct NotificationRateLimit {
    static let perSecond = 3
    static let perMinute = 30

    private var posted: [Date] = []

    mutating func allow(at now: Date) -> Bool {
        posted.removeAll { now.timeIntervalSince($0) >= 60 }
        let lastSecond = posted.filter { now.timeIntervalSince($0) < 1 }.count
        guard lastSecond < Self.perSecond, posted.count < Self.perMinute else { return false }
        posted.append(now)
        return true
    }
}

enum NotificationIdentity {
    /// The macOS request identifier: a tag names one notification per host,
    /// so posting the tag again replaces it; without one, each is its own.
    static func identifier(host: String, tag: String, id: String) -> String {
        tag.isEmpty ? "id|\(host)|\(id)" : "tag|\(host)|\(tag)"
    }

    /// The one line a posted notification logs: its tag, never its text.
    static func postedLine(tag: String) -> String {
        "notification: posted (\(describe(tag: tag)))"
    }

    static func describe(tag: String) -> String {
        tag.isEmpty ? "no tag" : "tag \(NotificationMessage.clip(tag, to: 64))"
    }
}

/// Which page made each delivered notification, so a click reaches its
/// handler: the latest notification for each identifier, at most `capacity`
/// of them, holding the page's web view weakly.
struct NotificationTargets<Target: AnyObject> {
    struct Entry {
        let identifier: String
        let pageID: String
        let tag: String
        weak var target: Target?
    }

    let capacity: Int
    private(set) var entries: [Entry] = []

    init(capacity: Int = 200) {
        self.capacity = capacity
    }

    mutating func record(identifier: String, pageID: String, tag: String, target: Target?) {
        entries.removeAll { $0.identifier == identifier }
        entries.append(Entry(identifier: identifier, pageID: pageID, tag: tag, target: target))
        if entries.count > capacity { entries.removeFirst(entries.count - capacity) }
    }

    func entry(identifier: String) -> Entry? {
        entries.first { $0.identifier == identifier }
    }

    /// The identifier of the page's notification `pageID`, forgotten; nil
    /// when a later notification has taken its identifier.
    mutating func remove(pageID: String, identifier: String) -> String? {
        guard let index = entries.firstIndex(where: { $0.identifier == identifier && $0.pageID == pageID }) else { return nil }
        entries.remove(at: index)
        return identifier
    }
}

/// System Settings › Notifications, opened at this app.
enum NotificationSettingsLink {
    static func url(bundleID: String) -> URL? {
        var components = URLComponents()
        components.scheme = "x-apple.systempreferences"
        components.path = "com.apple.Notifications-Settings.extension"
        components.queryItems = [URLQueryItem(name: "id", value: bundleID)]
        return components.url
    }
}
