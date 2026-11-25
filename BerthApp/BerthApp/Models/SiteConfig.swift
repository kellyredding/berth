import Foundation

/// The normalized config from `berth config export --json [--site SITE]`.
/// Every key the export writes is required, `null` included, so a drift
/// between the CLI and the app fails decoding rather than reading as absent.
///
/// MIRROR: tools/berth/src/berth/config/export.cr (see docs/contract.md,
/// "Config export"); fixtures/export.json pins the shape.
struct ConfigExport: Decodable, Equatable {
    let version: Int
    let source: String
    let path: String
    let sites: [String: SiteConfig]
    let warnings: [String]

    static func decode(_ data: Data) throws -> ConfigExport {
        try JSONDecoder().decode(ConfigExport.self, from: data)
    }
}

struct SiteConfig: Decodable, Equatable {
    let site: String
    let bundleID: String
    let name: String
    let url: URL
    let keep: KeepList
    let icon: String?
    let badge: BadgeConfig?
    let handles: [String]
    let mailto: String?
    let notifications: Bool
    let launchAtLogin: Bool
    let signin: [String: [SigninStep]]

    enum CodingKeys: String, CodingKey {
        case site
        case bundleID = "bundle_id"
        case name, url, keep, icon, badge, handles, mailto, notifications
        case launchAtLogin = "launch_at_login"
        case signin
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        site = try container.decode(String.self, forKey: .site)
        bundleID = try container.decode(String.self, forKey: .bundleID)
        name = try container.decode(String.self, forKey: .name)
        let raw = try container.decode(String.self, forKey: .url)
        guard let url = URL(string: raw), url.scheme?.lowercased() == "https", url.host != nil else {
            throw DecodingError.dataCorruptedError(
                forKey: .url, in: container, debugDescription: "\(raw) is not an https URL"
            )
        }
        self.url = url
        keep = KeepList(try container.decode([String].self, forKey: .keep))
        icon = try container.decode(String?.self, forKey: .icon)
        badge = try container.decode(BadgeConfig?.self, forKey: .badge)
        handles = try container.decode([String].self, forKey: .handles)
        mailto = try container.decode(String?.self, forKey: .mailto)
        notifications = try container.decode(Bool.self, forKey: .notifications)
        launchAtLogin = try container.decode(Bool.self, forKey: .launchAtLogin)
        signin = try container.decode([String: [SigninStep]].self, forKey: .signin)
    }
}

struct BadgeConfig: Decodable, Equatable {
    let title: String
}

/// One step of a named sign-in login, as configured: which flow fills it, and
/// the 1Password reference the CLI reads. The app never sees a secret here.
struct SigninStep: Decodable, Equatable {
    let flow: String
    let item: String?
    let emailFrom: String?
    /// The 1Password account holding the item, for the CLI's `op --account`.
    let account: String?
    /// For okta, the verification method to choose when Okta lists them.
    let method: String?

    enum CodingKeys: String, CodingKey {
        case flow, item
        case emailFrom = "email_from"
        case account, method
    }

    init(flow: String, item: String?, emailFrom: String?, account: String? = nil, method: String? = nil) {
        self.flow = flow
        self.item = item
        self.emailFrom = emailFrom
        self.account = account
        self.method = method
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        flow = try container.decode(String.self, forKey: .flow)
        item = try container.decode(String?.self, forKey: .item)
        emailFrom = try container.decode(String?.self, forKey: .emailFrom)
        account = try container.decode(String?.self, forKey: .account)
        method = try container.decode(String?.self, forKey: .method)
    }
}
