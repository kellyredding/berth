import Foundation

/// Every path a site app uses, each overridable from the environment so checks
/// run against temporary directories.
///
/// MIRROR: tools/berth/src/berth/paths.cr (see docs/contract.md, "Paths")
struct BerthPaths: Equatable {
    let home: URL
    let root: URL
    let configFile: URL
    let runtimeDir: URL
    /// `BERTH_BINARY`; when set, it is the only CLI the app will run.
    let binaryOverride: URL?

    var logsDir: URL { runtimeDir.appendingPathComponent("logs") }

    /// The config is often a symlink into a dotfiles repository; hand edits
    /// land on the target, so that is the file worth watching.
    var resolvedConfigFile: URL { configFile.resolvingSymlinksInPath() }

    func socket(site: String) -> URL { runtimeDir.appendingPathComponent("\(site).sock") }

    func lockFile(site: String) -> URL { URL(fileURLWithPath: socket(site: site).path + ".lock") }

    func log(site: String) -> URL { logsDir.appendingPathComponent("\(site).log") }

    /// The template has no site; a capital letter keeps it from colliding with
    /// a site's log, since site names are lowercase.
    var templateLog: URL { logsDir.appendingPathComponent("Berth.log") }

    /// Where the CLI may be, in the order the app tries them.
    var binaryCandidates: [URL] {
        if let binaryOverride { return [binaryOverride] }
        return [
            root.appendingPathComponent("bin").appendingPathComponent("berth"),
            home.appendingPathComponent(".local").appendingPathComponent("bin").appendingPathComponent("berth"),
        ]
    }

    func binary(isExecutable: (String) -> Bool) -> URL? {
        binaryCandidates.first { isExecutable($0.path) }
    }

    init(environment: [String: String], home: URL) {
        func override(_ name: String) -> URL? {
            guard let value = environment[name], !value.isEmpty else { return nil }
            return URL(fileURLWithPath: (value as NSString).expandingTildeInPath)
        }
        self.home = home
        root = override("BERTH_ROOT") ?? home.appendingPathComponent(".berth")
        configFile = override("BERTH_CONFIG") ?? root.appendingPathComponent("config.json")
        runtimeDir = override("BERTH_RUNTIME_DIR") ?? root.appendingPathComponent("runtime")
        binaryOverride = override("BERTH_BINARY")
    }

    static var current: BerthPaths {
        BerthPaths(
            environment: ProcessInfo.processInfo.environment,
            home: FileManager.default.homeDirectoryForCurrentUser
        )
    }
}

/// Which site this copy of the app shows: `BerthSite` in its Info.plist (a
/// built site app), else `BERTH_SITE` (development), else none (the template).
enum SiteSelection: Equatable {
    enum Source: String, Equatable {
        case infoPlist = "Info.plist"
        case environment = "BERTH_SITE"
    }

    case site(String, source: Source)
    case template
    case invalid(String)

    static let maxLength = 32

    static func resolve(infoPlist: Any?, environment: [String: String]) -> SiteSelection {
        if let value = infoPlist as? String, !value.isEmpty {
            return validated(value, source: .infoPlist)
        }
        if let value = environment["BERTH_SITE"], !value.isEmpty {
            return validated(value, source: .environment)
        }
        return .template
    }

    /// MIRROR: tools/berth/src/berth/config/model.cr (SITE_PATTERN, SITE_MAX)
    static func isValidName(_ name: String) -> Bool {
        guard !name.isEmpty, name.count <= maxLength else { return false }
        let allowed = Set("abcdefghijklmnopqrstuvwxyz0123456789-")
        guard name.allSatisfy({ allowed.contains($0) }) else { return false }
        return name.first != "-"
    }

    private static func validated(_ name: String, source: Source) -> SiteSelection {
        guard isValidName(name) else {
            return .invalid("\(source.rawValue) names the site \"\(name)\", which is not a site name: "
                + "lowercase letters, digits and hyphens, at most \(maxLength) characters")
        }
        return .site(name, source: source)
    }
}
