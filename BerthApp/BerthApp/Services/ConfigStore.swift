import Foundation

/// The site's loaded config. Loads at launch, on the socket's `reload`, and
/// when the resolved config file changes on disk; a failed load keeps the
/// last good config live and exposes the error.
@MainActor
final class ConfigStore: ObservableObject {
    @Published private(set) var config: SiteConfig?
    @Published private(set) var error: String?
    @Published private(set) var hasFinishedFirstLoad = false

    /// Called after every load, successful or not.
    var onLoad: (() -> Void)?

    let paths: BerthPaths
    private let cli: CLIRunner
    private var watcher: FileWatcher?
    private var watchedDirectories: [String] = []
    /// One write reaches the app as the CLI's `reload` and one or more file
    /// events; the window folds them into a single load.
    private lazy var reloads = ReloadCoalescer(window: 0.25) { [unowned self] in await self.load() }

    init(paths: BerthPaths, cli: CLIRunner) {
        self.paths = paths
        self.cli = cli
    }

    var isLoaded: Bool { config != nil }

    var state: ConfigLoadState { ConfigLoadState(hasConfig: isLoaded, finishedFirstLoad: hasFinishedFirstLoad) }

    func start() {
        Task { await reload() }
    }

    @discardableResult
    func reload() async -> ReloadData {
        await reloads.request()
    }

    private func load() async -> ReloadData {
        defer {
            rewatch()
            hasFinishedFirstLoad = true
            onLoad?()
        }
        do {
            let loaded = try await cli.exportSite()
            if loaded != config { config = loaded }
            error = nil
            Log.info("config loaded: \(loaded.site) (\(loaded.name), \(loaded.url.absoluteString), keep \(loaded.keep.patterns.joined(separator: ", ")))")
            return ReloadData(loaded: true, error: nil)
        } catch {
            let message = error.localizedDescription
            self.error = message
            Log.error("config load failed: \(message)")
            return ReloadData(loaded: false, error: message)
        }
    }

    private func rewatch() {
        let candidates = [paths.configFile, paths.resolvedConfigFile]
            .map { $0.deletingLastPathComponent().path }
        var directories: [String] = []
        for directory in candidates where !directories.contains(directory) {
            var isDirectory: ObjCBool = false
            if FileManager.default.fileExists(atPath: directory, isDirectory: &isDirectory), isDirectory.boolValue {
                directories.append(directory)
            }
        }
        guard directories != watchedDirectories else { return }
        watchedDirectories = directories
        watcher = FileWatcher(directories: directories) { [weak self] changed in
            MainActor.assumeIsolated { self?.filesChanged(changed) }
        }
    }

    /// FSEvents is recursive, so only the config file itself counts.
    private func filesChanged(_ changed: [String]) {
        let watched = Set([paths.configFile.path, paths.resolvedConfigFile.path].map(Self.canonical))
        guard changed.contains(where: { watched.contains(Self.canonical($0)) }) else { return }
        Task { await reload() }
    }

    /// FSEvents reports real paths (`/private/tmp`, link targets); the file
    /// itself may already be gone, so only its directory is resolved.
    private static func canonical(_ path: String) -> String {
        let url = URL(fileURLWithPath: path).standardizedFileURL
        guard let real = realpath(url.deletingLastPathComponent().path, nil) else { return url.path }
        defer { free(real) }
        return (String(cString: real) as NSString).appendingPathComponent(url.lastPathComponent)
    }
}
