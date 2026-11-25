import AppKit

/// The app macOS opens `mailto:` links with, and making this app it. macOS
/// asks the person to confirm the change.
@MainActor
enum DefaultMailApp {
    private static let probe = URL(string: "mailto:")!

    struct Current: Equatable {
        /// The default's name, or nil when nothing handles `mailto:`.
        let name: String?
        let isThisApp: Bool
    }

    static var current: Current {
        guard let url = NSWorkspace.shared.urlForApplication(toOpen: probe) else { return Current(name: nil, isThisApp: false) }
        let bundle = Bundle(url: url)
        let name = bundle?.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String
            ?? bundle?.object(forInfoDictionaryKey: "CFBundleName") as? String
            ?? url.deletingPathExtension().lastPathComponent
        let isThisApp = url.standardizedFileURL.resolvingSymlinksInPath() == Bundle.main.bundleURL.standardizedFileURL.resolvingSymlinksInPath()
        return Current(name: name, isThisApp: isThisApp)
    }

    /// Calls back on the main actor with the error, or nil once it is the default.
    static func makeThisApp(completion: @escaping @MainActor (Error?) -> Void) {
        NSWorkspace.shared.setDefaultApplication(at: Bundle.main.bundleURL, toOpenURLsWithScheme: "mailto") { error in
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    if let error {
                        Log.error("mailto: not made the default email app: \(error.localizedDescription)")
                    } else {
                        Log.info("mailto: made the default email app")
                    }
                    completion(error)
                }
            }
        }
    }
}
