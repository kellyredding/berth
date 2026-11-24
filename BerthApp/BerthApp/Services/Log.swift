import Foundation
import os

/// Unified logging plus a plain file, `<runtime>/logs/<site>.log`, so an agent
/// can read what a site app saw without `log show`. Nothing written here may
/// carry a secret: sign-in values and socket requests are never logged.
enum Log {
    private static let logger = Logger(subsystem: "com.kellyredding.berth", category: "app")
    private static let queue = DispatchQueue(label: "com.kellyredding.berth.log")
    private static let maxBytes: UInt64 = 1_000_000
    private static let formatter = ISO8601DateFormatter()
    nonisolated(unsafe) private static var file: URL?

    /// Lines logged before this are kept in unified logging only.
    static func configure(file url: URL) {
        queue.async { file = url }
    }

    static func info(_ message: String) {
        logger.notice("\(message, privacy: .public)")
        append("INFO  \(message)")
    }

    static func error(_ message: String) {
        logger.error("\(message, privacy: .public)")
        append("ERROR \(message)")
    }

    private static func append(_ line: String) {
        let stamp = formatter.string(from: Date())
        queue.async {
            guard let file else { return }
            let directory = file.deletingLastPathComponent()
            try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            if let size = (try? FileManager.default.attributesOfItem(atPath: file.path))?[.size] as? UInt64,
               size > maxBytes {
                let previous = URL(fileURLWithPath: file.path + ".1")
                try? FileManager.default.removeItem(at: previous)
                try? FileManager.default.moveItem(at: file, to: previous)
            }
            guard let data = "\(stamp) \(line)\n".data(using: .utf8) else { return }
            if let handle = try? FileHandle(forWritingTo: file) {
                defer { try? handle.close() }
                _ = try? handle.seekToEnd()
                try? handle.write(contentsOf: data)
            } else {
                try? data.write(to: file)
            }
        }
    }
}
