import Foundation

/// The user agent's Safari suffix. WebKit's own user agent names no browser,
/// and some sites then warn that the browser is unsupported or withhold
/// features; Safari appends `Version/<version> Safari/605.1.15`, so a site app
/// appends the same, with the installed Safari's version.
enum UserAgent {
    /// Safari reports this frozen build number whatever its version.
    static let safariBuild = "605.1.15"

    /// What `WKWebViewConfiguration.applicationNameForUserAgent` appends to
    /// WebKit's own user agent.
    static func applicationName(safariVersion: String) -> String {
        "Version/\(safariVersion) Safari/\(safariBuild)"
    }

    static func full(webKit: String, safariVersion: String) -> String {
        "\(webKit) \(applicationName(safariVersion: safariVersion))"
    }

    /// `CFBundleShortVersionString` from Safari's Info.plist, when it reads as
    /// a version (`26.1`, `18.6.2`).
    static func safariVersion(infoPlist: Data?) -> String? {
        guard let infoPlist,
              let plist = try? PropertyListSerialization.propertyList(from: infoPlist, format: nil),
              let dictionary = plist as? [String: Any],
              let version = dictionary["CFBundleShortVersionString"] as? String,
              isVersion(version)
        else { return nil }
        return version
    }

    /// The Safari each macOS shipped with: 17 on macOS 14, 18 on 15, and from
    /// macOS 26 on, the same number.
    static func fallbackVersion(osMajor: Int) -> String {
        osMajor >= 26 ? "\(osMajor).0" : "\(max(osMajor, 14) + 3).0"
    }

    static func resolveSafariVersion(infoPlist: Data?, osMajor: Int) -> String {
        safariVersion(infoPlist: infoPlist) ?? fallbackVersion(osMajor: osMajor)
    }

    private static func isVersion(_ text: String) -> Bool {
        let parts = text.split(separator: ".", omittingEmptySubsequences: false)
        return (1...3).contains(parts.count)
            && parts.allSatisfy { !$0.isEmpty && $0.allSatisfy(\.isASCII) && $0.allSatisfy(\.isNumber) }
    }
}
