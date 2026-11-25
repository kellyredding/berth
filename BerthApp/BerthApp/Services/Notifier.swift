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
    @Published private(set) var badgeSetting: NotificationSetting = .notSupported
    /// From the site's config: whether its pages may notify, and from where.
    var enabled = false
    var keep = KeepList([])
    /// Whether the site sets `badge.title`, the only reason to ask for badges.
    var badgeRule = false
    /// macOS's answer for notifications, or for badges, changed.
    var onAuthorizationChange: (() -> Void)?
    /// A notification was clicked: the web view that posted it, if it is
    /// still open, and the page's id for it, if the app still knows it.
    var onClick: ((WKWebView?, String?) -> Void)?

    private let center = UNUserNotificationCenter.current()
    private var limit = NotificationRateLimit()
    private var targets = NotificationTargets<WKWebView>()
    private var isAsking = false
    private var askedForBadge = false
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
            self.settingsChanged(await self.center.notificationSettings())
        }
    }

    /// Asks macOS, which shows its prompt only the first time; every later
    /// call gets the answer it gave.
    func requestAuthorization(_ answer: ((NotificationPermission) -> Void)? = nil) {
        let options = Self.options(DockBadgePermission.options(notifications: enabled, badgeRule: badgeRule))
        guard authorization == .notDetermined, !options.isEmpty else {
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
                _ = try await self.center.requestAuthorization(options: options)
            } catch {
                Log.error("notification: macOS refused the request: \(error.localizedDescription)")
            }
            self.settingsChanged(await self.center.notificationSettings())
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

    /// An app allowed to notify before it asked for badges never gets them
    /// from the page's or Settings' request, which asks only when macOS has no
    /// answer yet, so a site with a badge rule asks with badges once at launch.
    /// INFERRED, not confirmed: macOS adds the option without a full prompt.
    func requestBadgeIfNeeded() {
        guard enabled, badgeRule, !askedForBadge else { return }
        askedForBadge = true
        Task { [weak self] in
            guard let self else { return }
            let before = await self.center.notificationSettings()
            guard DockBadgePermission.needsRequest(
                badgeRule: self.badgeRule,
                authorization: Self.authorization(before.authorizationStatus), badge: Self.setting(before.badgeSetting)
            ) else { return }
            let options = Self.options(DockBadgePermission.options(notifications: self.enabled, badgeRule: self.badgeRule))
            do {
                _ = try await self.center.requestAuthorization(options: options)
            } catch {
                Log.error("notification: macOS refused the badge request: \(error.localizedDescription)")
            }
            let after = await self.center.notificationSettings()
            Log.info("notification: asked macOS for badges; Badges is \(Self.setting(after.badgeSetting).rawValue)")
            self.settingsChanged(after)
        }
    }

    private func settingsChanged(_ settings: UNNotificationSettings) {
        let badge = Self.setting(settings.badgeSetting)
        let badgeChanged = badge != badgeSetting
        if badgeChanged { badgeSetting = badge }
        if !authorizationChanged(Self.authorization(settings.authorizationStatus)) && badgeChanged {
            onAuthorizationChange?()
        }
    }

    private static func options(_ wanted: Set<NotificationOption>) -> UNAuthorizationOptions {
        var options: UNAuthorizationOptions = []
        if wanted.contains(.alert) { options.insert(.alert) }
        if wanted.contains(.sound) { options.insert(.sound) }
        if wanted.contains(.badge) { options.insert(.badge) }
        return options
    }

    private static func setting(_ value: UNNotificationSetting) -> NotificationSetting {
        switch value {
        case .enabled: return .enabled
        case .disabled: return .disabled
        case .notSupported: return .notSupported
        @unknown default: return .disabled
        }
    }

    /// Whether it changed, and so already told onAuthorizationChange.
    @discardableResult
    private func authorizationChanged(_ value: NotificationAuthorization) -> Bool {
        guard value != authorization else { return false }
        authorization = value
        Log.info("notification: macOS permission is \(value.pagePermission.rawValue)")
        onAuthorizationChange?()
        return true
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
