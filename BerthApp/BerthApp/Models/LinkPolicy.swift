import Foundation

/// A site's `keep` hosts: exact (`mail.example.com`) or a suffix pattern
/// (`*.example.com`) matching subdomains only, never `example.com` itself.
/// Case and port are ignored.
///
/// MIRROR: tools/berth/src/berth/config/model.cr (`Config.keeps?`)
struct KeepList: Equatable {
    let patterns: [String]

    init(_ patterns: [String]) {
        self.patterns = patterns.map { $0.lowercased() }
    }

    func keeps(host: String?) -> Bool {
        guard let host = host.map(Self.normalize), !host.isEmpty else { return false }
        return patterns.contains { Self.matches(pattern: $0, host: host) }
    }

    /// Only web pages are kept; any other scheme belongs to another app.
    func keeps(_ url: URL) -> Bool {
        guard LinkPolicy.isWeb(url) else { return false }
        return keeps(host: url.host)
    }

    static func matches(pattern: String, host: String) -> Bool {
        let host = normalize(host)
        if pattern.hasPrefix("*.") {
            let suffix = String(pattern.dropFirst())
            return host.count > suffix.count && host.hasSuffix(suffix)
        }
        return host == pattern
    }

    /// `Mail.Example.com.` is `mail.example.com`.
    private static func normalize(_ host: String) -> String {
        var host = host.lowercased()
        if host.hasSuffix(".") { host.removeLast() }
        return host
    }
}

/// What started a navigation: `WKNavigationType` without WebKit.
enum NavigationKind: Equatable {
    case link, formSubmission, formResubmission, backForward, reload
    /// A server or script redirect, or anything else the page did itself.
    case other

    var label: String {
        switch self {
        case .link: return "link"
        case .formSubmission: return "form"
        case .formResubmission: return "form resubmission"
        case .backForward: return "back/forward"
        case .reload: return "reload"
        case .other: return "redirect"
        }
    }
}

/// Where a navigation or a new window goes. A clicked link out of scope, a
/// ⌘-click and other apps' schemes (`mailto:`, `tel:`, `zoommtg:`) leave the
/// app; redirects, form posts, reloads and history stay, whatever the host,
/// so a sign-in's chain of hosts finishes in the app.
enum LinkPolicy {
    enum Route: Equatable {
        /// Load it here (or, for a new window, in a second window of this app).
        case app
        /// Hand it to the default browser or the scheme's app.
        case browser
        /// Drop it.
        case ignore
    }

    /// Schemes a page uses for its own content.
    static let internalSchemes: Set<String> = ["about", "blob", "data"]

    static func isWeb(_ url: URL) -> Bool {
        guard let scheme = url.scheme?.lowercased() else { return false }
        return scheme == "http" || scheme == "https"
    }

    static func navigation(_ url: URL?, kind: NavigationKind, mainFrame: Bool, commandClick: Bool,
                           keep: KeepList) -> Route {
        guard let url, let scheme = url.scheme?.lowercased() else { return .app }
        if isWeb(url) {
            if !mainFrame { return .app }
            if commandClick { return .browser }
            guard kind == .link else { return .app }
            return keep.keeps(url) ? .app : .browser
        }
        return byScheme(scheme)
    }

    /// A main-frame navigation in a popup that has not shown a page yet. The
    /// popup exists to open a link, so an out-of-scope destination leaves
    /// however it was reached: through a redirector, say.
    static func popupDestination(_ url: URL?, keep: KeepList) -> Route {
        guard let url, let scheme = url.scheme?.lowercased() else { return .app }
        if isWeb(url) { return keep.keeps(url) ? .app : .browser }
        return byScheme(scheme)
    }

    /// Host and path, for the log: a URL's query and fragment can carry tokens.
    static func hostAndPath(_ url: URL) -> String {
        guard let host = url.host else { return "\(url.scheme ?? "a"): URL" }
        return "\(host)\(url.path.isEmpty ? "/" : url.path)"
    }

    /// `target=_blank` and `window.open`. A blank popup stays in the app: the
    /// page fills it in, and its first navigation is routed like any other.
    static func newWindow(_ url: URL?, commandClick: Bool, keep: KeepList) -> Route {
        guard let url, let scheme = url.scheme?.lowercased(), url.absoluteString != "about:blank" else {
            return commandClick ? .ignore : .app
        }
        if isWeb(url) {
            if commandClick { return .browser }
            return keep.keeps(url) ? .app : .browser
        }
        return byScheme(scheme)
    }

    /// A URL from outside the page: the socket's `open`, or one handed to the
    /// app by `open -a`. A web page in scope loads here; anything else leaves.
    static func external(_ url: URL, keep: KeepList) -> Route {
        guard let scheme = url.scheme?.lowercased() else { return .ignore }
        if isWeb(url) { return keep.keeps(url) ? .app : .browser }
        return scheme == "file" ? .ignore : .browser
    }

    private static func byScheme(_ scheme: String) -> Route {
        if internalSchemes.contains(scheme) { return .app }
        // A web page has no business opening local files in Finder's apps.
        if scheme == "file" { return .ignore }
        return .browser
    }
}
