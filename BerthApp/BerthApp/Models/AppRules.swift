import Foundation

/// The About panel's build line: `BerthBuildCommit`, which packaging stamps
/// into a released app's Info.plist, or "development build" without it.
enum BuildLabel {
    static func text(commit: Any?) -> String {
        guard let commit = commit as? String else { return "development build" }
        let trimmed = commit.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "development build" : "build \(trimmed)"
    }
}

/// View ▸ Zoom In / Zoom Out step through Safari's zoom levels.
enum PageZoom {
    static let levels: [Double] = [0.5, 0.75, 0.85, 1.0, 1.15, 1.25, 1.5, 1.75, 2.0, 2.5, 3.0]
    static let actualSize = 1.0

    static func zoomIn(from current: Double) -> Double {
        levels.first { $0 > current + 0.001 } ?? levels.last!
    }

    static func zoomOut(from current: Double) -> Double {
        levels.last { $0 < current - 0.001 } ?? levels.first!
    }

    static func clamped(_ value: Double) -> Double {
        min(max(value, levels.first!), levels.last!)
    }
}

/// `SMAppService.Status`, without ServiceManagement.
enum LoginItemStatus: Equatable {
    case notRegistered, enabled, requiresApproval, notFound
}

/// When a site's `launch_at_login` turns Launch at Login on. The user's own
/// choice always wins: once they flip the Settings toggle, or the app has
/// registered from the config, or the login item already exists (set in
/// System Settings), the config never changes it again.
enum LaunchAtLoginRule {
    static func shouldRegister(configured: Bool, decided: Bool, status: LoginItemStatus) -> Bool {
        guard configured, !decided else { return false }
        return status == .notRegistered || status == .notFound
    }

    /// Whether the status alone says someone has already chosen.
    static func statusDecides(_ status: LoginItemStatus) -> Bool {
        status == .enabled || status == .requiresApproval
    }
}

/// A download's file name in the Downloads folder: the page's suggestion made
/// safe, and numbered (`report 2.pdf`) when the name is taken.
enum DownloadName {
    static let fallback = "download"

    static func sanitize(_ suggested: String) -> String {
        var name = suggested
            .replacingOccurrences(of: "/", with: "-")
            .replacingOccurrences(of: ":", with: "-")
            .filter { !$0.isNewline && $0.unicodeScalars.allSatisfy { !CharacterSet.controlCharacters.contains($0) } }
            .trimmingCharacters(in: .whitespaces)
        while name.hasPrefix(".") { name.removeFirst() }
        return name.isEmpty ? fallback : name
    }

    static func unique(_ suggested: String, in directory: URL, exists: (URL) -> Bool) -> URL {
        let name = sanitize(suggested)
        let first = directory.appendingPathComponent(name)
        guard exists(first) else { return first }
        let ext = (name as NSString).pathExtension
        let stem = (name as NSString).deletingPathExtension
        var number = 2
        while true {
            let candidate = ext.isEmpty ? "\(stem) \(number)" : "\(stem) \(number).\(ext)"
            let url = directory.appendingPathComponent(candidate)
            if !exists(url) { return url }
            number += 1
        }
    }
}
