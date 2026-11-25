import AppKit
import UserNotifications
import WebKit

/// The page's web notifications as macOS notifications: answers
/// NotificationShim's messages, posts through UNUserNotificationCenter, and
/// sends a click back to the page that posted it. macOS is asked for
/// permission the first time a page asks, or from Settings. Its log names a
/// notification's tag, never its title or body.
@MainActor
final class Notifier: NSObject, ObservableObject {
    /// How often one kind of refusal is logged, so a page that keeps trying
    /// cannot fill the log.
    private static let refusalLogInterval: TimeInterval = 10

    @Published private(set) var authorization: NotificationAuthorization = .notDetermined
    /// From the site's config: whether its pages may notify, and from where.
    var enabled = false
    var keep = KeepList([])
    var onAuthorizationChange: (() -> Void)?
    /// A notification was clicked: the web view that posted it, if it is
    /// still open, and the page's id for it, if the app still knows it.
    var onClick: ((WKWebView?, String?) -> Void)?

    private let center = UNUserNotificationCenter.current()
    private var limit = NotificationRateLimit()
    private var targets = NotificationTargets<WKWebView>()
    private var isAsking = false
    private var waitingForAnswer: [(NotificationPermission) -> Void] = []
    private var refusalsLogged: [String: Date] = [:]
    private var activation: NSObjectProtocol?

    /// Before the app finishes launching, so a click that launched it arrives.
    func start() {
        center.delegate = self
        refreshAuthorization()
        activation = NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.refreshAuthorization() }
        }
    }

    func install(in controller: WKUserContentController) {
        controller.addScriptMessageHandler(self, contentWorld: .page, name: NotificationShim.handlerName)
    }

    /// macOS's answer can change in System Settings while the app runs.
    func refreshAuthorization() {
        Task { [weak self] in
            guard let self else { return }
            let settings = await self.center.notificationSettings()
            self.authorizationChanged(Self.authorization(settings.authorizationStatus))
        }
    }

    /// Asks macOS, which shows its prompt only the first time; every later
    /// call gets the answer it gave.
    func requestAuthorization(_ answer: ((NotificationPermission) -> Void)? = nil) {
        guard authorization == .notDetermined else {
            answer?(authorization.pagePermission)
            return
        }
        if let answer { waitingForAnswer.append(answer) }
        guard !isAsking else { return }
        isAsking = true
        Log.info("notification: asking macOS for permission")
        Task { [weak self] in
            guard let self else { return }
            do {
                _ = try await self.center.requestAuthorization(options: [.alert, .sound])
            } catch {
                Log.error("notification: macOS refused the request: \(error.localizedDescription)")
            }
            let settings = await self.center.notificationSettings()
            self.authorizationChanged(Self.authorization(settings.authorizationStatus))
            self.isAsking = false
            let answers = self.waitingForAnswer
            self.waitingForAnswer = []
            for answer in answers { answer(self.authorization.pagePermission) }
        }
    }

    func openSystemSettings() {
        guard let url = NotificationSettingsLink.url(bundleID: Bundle.main.bundleIdentifier ?? "") else { return }
        NSWorkspace.shared.open(url)
    }

    private func authorizationChanged(_ value: NotificationAuthorization) {
        guard value != authorization else { return }
        authorization = value
        Log.info("notification: macOS permission is \(value.pagePermission.rawValue)")
        onAuthorizationChange?()
    }

    private static func authorization(_ status: UNAuthorizationStatus) -> NotificationAuthorization {
        switch status {
        case .notDetermined: return .notDetermined
        case .denied: return .denied
        case .authorized, .provisional, .ephemeral: return .authorized
        @unknown default: return .denied
        }
    }

    private func log(_ refusal: NotificationRefusal) {
        let line = refusal.logLine
        let now = Date()
        if let last = refusalsLogged[line], now.timeIntervalSince(last) < Self.refusalLogInterval { return }
        refusalsLogged[line] = now
        Log.info(line)
    }

    // MARK: - Posting

    private func post(_ content: NotificationContent, host: String, from webView: WKWebView?, reply: @escaping (Bool) -> Void) {
        guard authorization == .authorized else {
            log(.notAllowed)
            reply(false)
            return
        }
        guard limit.allow(at: Date()) else {
            log(.rate)
            reply(false)
            return
        }
        let identifier = NotificationIdentity.identifier(host: host, tag: content.tag, id: content.id)
        let body = UNMutableNotificationContent()
        body.title = content.title
        body.body = content.body
        body.sound = content.silent ? nil : .default
        body.userInfo = ["silent": content.silent]
        targets.record(identifier: identifier, pageID: content.id, tag: content.tag, target: webView)
        let request = UNNotificationRequest(identifier: identifier, content: body, trigger: nil)
        Task { [weak self] in
            guard let self else { return }
            do {
                try await self.center.add(request)
                Log.info(NotificationIdentity.postedLine(tag: content.tag))
                reply(true)
            } catch {
                Log.error("notification: not posted (\(NotificationIdentity.describe(tag: content.tag))): \(error.localizedDescription)")
                reply(false)
            }
        }
    }

    private func close(id: String, tag: String, host: String) {
        let identifier = NotificationIdentity.identifier(host: host, tag: tag, id: id)
        guard targets.remove(pageID: id, identifier: identifier) != nil else { return }
        center.removeDeliveredNotifications(withIdentifiers: [identifier])
        center.removePendingNotificationRequests(withIdentifiers: [identifier])
    }

    fileprivate func clicked(_ identifier: String) {
        let entry = targets.entry(identifier: identifier)
        Log.info("notification: clicked (\(entry.map { NotificationIdentity.describe(tag: $0.tag) } ?? "from before this launch"))")
        onClick?(entry?.target, entry?.pageID)
    }
}

extension Notifier: WKScriptMessageHandlerWithReply {
    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage,
                               replyHandler: @escaping @MainActor (Any?, String?) -> Void) {
        let host = message.frameInfo.securityOrigin.host
        if let refusal = NotificationGate.check(enabled: enabled, mainFrame: message.frameInfo.isMainFrame, host: host, keep: keep) {
            log(refusal)
            replyHandler(nil, "refused")
            return
        }
        switch NotificationMessage.parse(message.body) {
        case .failure(let refusal):
            log(refusal)
            replyHandler(nil, "refused")
        case .success(.request):
            requestAuthorization { replyHandler($0.rawValue, nil) }
        case .success(.show(let content)):
            post(content, host: host, from: message.webView) { replyHandler($0, nil) }
        case .success(.close(let id, let tag)):
            close(id: id, tag: tag, host: host)
            replyHandler(nil, nil)
        }
    }
}

extension Notifier: UNUserNotificationCenterDelegate {
    /// Shown even while the app is in front: the page decides when to notify.
    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification,
                                            withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        let silent = notification.request.content.userInfo["silent"] as? Bool ?? false
        completionHandler(silent ? [.banner, .list] : [.banner, .list, .sound])
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse,
                                            withCompletionHandler completionHandler: @escaping () -> Void) {
        let identifier = response.notification.request.identifier
        if response.actionIdentifier == UNNotificationDefaultActionIdentifier {
            DispatchQueue.main.async { [weak self] in
                MainActor.assumeIsolated { self?.clicked(identifier) }
            }
        }
        completionHandler()
    }
}
