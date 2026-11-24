import Foundation

enum CLIError: LocalizedError {
    case missing([String])
    case failed(String)
    case undecodable(String)
    case siteMissing(String)

    var errorDescription: String? {
        switch self {
        case .missing(let paths):
            return "the berth CLI is not installed; looked for \(paths.joined(separator: ", "))"
        case .failed(let message): return message
        case .undecodable(let message): return "could not read the config export: \(message)"
        case .siteMissing(let site): return "the config export has no site \"\(site)\""
        }
    }
}

/// Runs the berth CLI. The app never reads or writes the config itself; its
/// site's settings arrive through `berth config export`.
final class CLIRunner: @unchecked Sendable {
    let paths: BerthPaths
    let site: String
    private let runner = ProcessRunner(defaultTimeout: 10)

    init(paths: BerthPaths, site: String) {
        self.paths = paths
        self.site = site
    }

    var binary: URL? { paths.binary { FileManager.default.isExecutableFile(atPath: $0) } }

    func exportSite() async throws -> SiteConfig {
        let data = try await run(["config", "export", "--json", "--site", site])
        let export: ConfigExport
        do {
            export = try ConfigExport.decode(data)
        } catch {
            throw CLIError.undecodable(String(describing: error))
        }
        guard let config = export.sites[site] else { throw CLIError.siteMissing(site) }
        return config
    }

    private func run(_ arguments: [String], timeout: TimeInterval? = nil) async throws -> Data {
        guard let binary else { throw CLIError.missing(paths.binaryCandidates.map(\.path)) }
        do {
            return try await runner.run(executable: binary, arguments: arguments, timeout: timeout)
        } catch {
            throw CLIError.failed(error.localizedDescription)
        }
    }
}
