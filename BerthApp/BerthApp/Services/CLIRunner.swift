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
/// site's settings arrive through `berth config export`. Every run gets the
/// app's own environment with CLIEnvironment's PATH.
final class CLIRunner: @unchecked Sendable {
    let paths: BerthPaths
    let site: String
    private let runner = ProcessRunner(defaultTimeout: 10)
    private let environment = CLIEnvironment.child(of: ProcessInfo.processInfo.environment)

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

    /// `berth signin SITE --account LOGIN --json`. The CLI reads 1Password
    /// and sends the values to this app's socket; what comes back here is
    /// only its outcome, never a value.
    func signin(login: String) async -> SigninResult {
        do {
            let output = try await run(SigninCommand.arguments(site: site, login: login), timeout: SigninCommand.timeout,
                                       keepExit: true)
            return SigninCommand.result(status: 0, output: output, error: Data(), login: login)
        } catch ProcessRunError.exited(_, let status, let output, let error) {
            return SigninCommand.result(status: status, output: output, error: error, login: login)
        } catch {
            return .failed("Sign-in failed: \(error.localizedDescription)")
        }
    }

    /// `keepExit` passes a non-zero exit through as ProcessRunError, so the
    /// caller can read the status and output.
    private func run(_ arguments: [String], timeout: TimeInterval? = nil, keepExit: Bool = false) async throws -> Data {
        guard let binary else { throw CLIError.missing(paths.binaryCandidates.map(\.path)) }
        do {
            return try await runner.run(executable: binary, arguments: arguments, timeout: timeout, environment: environment)
        } catch let error as ProcessRunError where keepExit {
            if case .exited = error { throw error }
            throw CLIError.failed(error.localizedDescription)
        } catch {
            throw CLIError.failed(error.localizedDescription)
        }
    }
}
