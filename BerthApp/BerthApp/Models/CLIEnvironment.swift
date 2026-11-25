import Foundation

/// The environment a site app runs the berth CLI in: its own, with a PATH
/// that finds Homebrew's tools. An app opened from the Dock gets launchd's
/// minimal PATH, and `berth signin` runs 1Password's `op` from PATH, which
/// Homebrew installs under /opt/homebrew/bin (or /usr/local/bin on Intel).
/// Everything else, the `BERTH_*` paths included, passes through unchanged.
enum CLIEnvironment {
    static let leading = ["/opt/homebrew/bin", "/usr/local/bin"]
    static let trailing = ["/usr/bin", "/bin", "/usr/sbin", "/sbin"]

    /// Homebrew's directories, then the inherited PATH, then the system's,
    /// each directory once, in the first place it appears.
    static func path(inherited: String?) -> String {
        let inheritedParts = (inherited ?? "").split(separator: ":").map(String.init)
        var seen: Set<String> = []
        return (leading + inheritedParts + trailing)
            .filter { !$0.isEmpty && seen.insert($0).inserted }
            .joined(separator: ":")
    }

    static func child(of environment: [String: String]) -> [String: String] {
        var child = environment
        child["PATH"] = path(inherited: environment["PATH"])
        return child
    }
}
