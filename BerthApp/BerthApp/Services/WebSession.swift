import Foundation
import WebKit

/// The WebKit setup every window of a site shares: one persistent data store
/// (cookies, storage) per site, and the Safari user agent suffix. A popup
/// window reuses the configuration WebKit hands it, so it shares both.
@MainActor
enum WebSession {
    static let safariInfoPlist = URL(fileURLWithPath: "/Applications/Safari.app/Contents/Info.plist")

    static func configuration(site: String, safariVersion: String) -> WKWebViewConfiguration {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = WKWebsiteDataStore(forIdentifier: DataStoreID.uuid(site: site))
        configuration.applicationNameForUserAgent = UserAgent.applicationName(safariVersion: safariVersion)
        configuration.preferences.isElementFullscreenEnabled = true
        return configuration
    }

    /// Read at each launch, so the user agent follows Safari's updates.
    static func safariVersion() -> String {
        let data = try? Data(contentsOf: safariInfoPlist)
        let major = ProcessInfo.processInfo.operatingSystemVersion.majorVersion
        let version = UserAgent.resolveSafariVersion(infoPlist: data, osMajor: major)
        if UserAgent.safariVersion(infoPlist: data) == nil {
            Log.error("could not read Safari's version from \(safariInfoPlist.path); using \(version)")
        }
        return version
    }
}
