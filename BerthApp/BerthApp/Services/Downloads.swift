import AppKit
import CoreServices
import WebKit

/// Saves every download to ~/Downloads under a free name, marks it as
/// downloaded from the web (so Gatekeeper checks anything it would run), and
/// reveals it in Finder when it finishes: the app has no downloads list, so
/// Finder is where the file shows up.
@MainActor
final class Downloads: NSObject, WKDownloadDelegate {
    private var destinations: [ObjectIdentifier: (file: URL, source: URL?)] = [:]
    private let appName: String

    init(appName: String) {
        self.appName = appName
    }

    var directory: URL {
        FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Downloads")
    }

    func adopt(_ download: WKDownload) {
        download.delegate = self
    }

    func download(_ download: WKDownload, decideDestinationUsing response: URLResponse,
                  suggestedFilename: String, completionHandler: @escaping @MainActor @Sendable (URL?) -> Void) {
        let file = DownloadName.unique(suggestedFilename, in: directory) { FileManager.default.fileExists(atPath: $0.path) }
        destinations[ObjectIdentifier(download)] = (file, download.originalRequest?.url)
        Log.info("download started: \(file.lastPathComponent)")
        completionHandler(file)
    }

    func downloadDidFinish(_ download: WKDownload) {
        guard let entry = destinations.removeValue(forKey: ObjectIdentifier(download)) else { return }
        quarantine(entry.file, source: entry.source)
        Log.info("download finished: \(entry.file.lastPathComponent)")
        NSWorkspace.shared.activateFileViewerSelecting([entry.file])
    }

    func download(_ download: WKDownload, didFailWithError error: Error, resumeData: Data?) {
        let entry = destinations.removeValue(forKey: ObjectIdentifier(download))
        Log.error("download failed: \(entry?.file.lastPathComponent ?? "unknown file"): \(error.localizedDescription)")
        NSSound.beep()
    }

    private func quarantine(_ file: URL, source: URL?) {
        var properties: [String: Any] = [
            kLSQuarantineAgentNameKey as String: appName,
            kLSQuarantineTypeKey as String: kLSQuarantineTypeWebDownload as String,
        ]
        if let source, LinkPolicy.isWeb(source) {
            properties[kLSQuarantineDataURLKey as String] = source
        }
        var values = URLResourceValues()
        values.quarantineProperties = properties
        var url = file
        do {
            try url.setResourceValues(values)
        } catch {
            Log.error("could not mark \(file.lastPathComponent) as downloaded: \(error.localizedDescription)")
        }
    }
}
