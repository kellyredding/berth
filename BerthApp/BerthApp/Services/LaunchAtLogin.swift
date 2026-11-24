import Foundation
import ServiceManagement

enum LaunchAtLogin {
    static var status: LoginItemStatus {
        switch SMAppService.mainApp.status {
        case .enabled: return .enabled
        case .requiresApproval: return .requiresApproval
        case .notFound: return .notFound
        case .notRegistered: return .notRegistered
        @unknown default: return .notRegistered
        }
    }

    static var isEnabled: Bool { status == .enabled }

    static var requiresApproval: Bool { status == .requiresApproval }

    /// Reports the real status afterwards rather than what was asked for.
    @discardableResult
    static func set(_ enabled: Bool) -> Bool {
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
        } catch {
            Log.error("launch at login \(enabled ? "on" : "off") failed: \(error.localizedDescription)")
        }
        return isEnabled
    }
}

/// Applies a site's `launch_at_login` once, unless the user has chosen (see
/// LaunchAtLoginRule). The choice is remembered per site in the app's
/// defaults, which a built site app has to itself.
@MainActor
enum LaunchAtLoginChoice {
    private static func key(site: String) -> String { "launchAtLoginDecided.\(site)" }

    static func isDecided(site: String) -> Bool {
        UserDefaults.standard.bool(forKey: key(site: site))
    }

    static func markDecided(site: String) {
        UserDefaults.standard.set(true, forKey: key(site: site))
    }

    /// The user flipped the Settings toggle.
    static func userSet(_ enabled: Bool, site: String) -> Bool {
        markDecided(site: site)
        return LaunchAtLogin.set(enabled)
    }

    static func apply(configured: Bool, site: String) {
        let status = LaunchAtLogin.status
        if LaunchAtLoginRule.statusDecides(status) {
            markDecided(site: site)
            return
        }
        guard LaunchAtLoginRule.shouldRegister(configured: configured, decided: isDecided(site: site), status: status) else {
            return
        }
        markDecided(site: site)
        let enabled = LaunchAtLogin.set(true)
        Log.info("launch at login: the config turns it on; now \(enabled ? "on" : "waiting for approval or off")")
    }
}
