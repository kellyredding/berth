import Foundation

/// A `mailto:` link handed to the app, made into the site's compose URL: the
/// site's `mailto` template with `%s` replaced by the whole link
/// percent-encoded, as a browser's registered protocol handler does. The site
/// decodes it once and reads the link as it was, its own escapes intact.
enum MailtoLink {
    enum Route: Equatable {
        case compose(URL)
        /// The site's config does not handle `mailto`.
        case notHandled
        /// The template has no single `%s`, or the result is not a web URL.
        case badTemplate
    }

    /// Everything but RFC 3986's unreserved characters is encoded, `+`, `&`,
    /// `=`, `?`, `@`, `,` and `%` included.
    static let unreserved = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")

    static func isMailto(_ url: URL) -> Bool {
        url.scheme?.lowercased() == "mailto"
    }

    static func route(_ link: String, handles: [String], template: String?) -> Route {
        guard handles.contains("mailto"), let template else { return .notHandled }
        guard let url = composeURL(template: template, link: link) else { return .badTemplate }
        return .compose(url)
    }

    static func composeURL(template: String, link: String) -> URL? {
        guard template.components(separatedBy: "%s").count == 2,
              let encoded = link.addingPercentEncoding(withAllowedCharacters: unreserved),
              let url = URL(string: template.replacingOccurrences(of: "%s", with: encoded)),
              LinkPolicy.isWeb(url), url.host != nil else { return nil }
        return url
    }
}
