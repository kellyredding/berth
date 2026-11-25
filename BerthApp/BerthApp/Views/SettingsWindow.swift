import AppKit
import SwiftUI

/// Settings: Launch at Login, notifications, and what this app is.
@MainActor
final class SettingsWindowController: NSWindowController {
    private static var shared: SettingsWindowController?

    static func show(model: AppModel) {
        if shared == nil { shared = SettingsWindowController(model: model) }
        guard let window = shared?.window else { return }
        window.center()
        window.makeKeyAndOrderFront(nil)
    }

    private init(model: AppModel) {
        let hosting = NSHostingController(rootView: SettingsView(model: model))
        hosting.sizingOptions = [.preferredContentSize]
        let window = NSWindow(contentViewController: hosting)
        window.styleMask = [.titled, .closable]
        window.title = "Settings"
        window.isReleasedWhenClosed = false
        super.init(window: window)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
}

struct SettingsView: View {
    @ObservedObject var model: AppModel
    @State private var launchAtLogin = LaunchAtLogin.isEnabled
    @State private var requiresApproval = LaunchAtLogin.requiresApproval

    var body: some View {
        Form {
            Section {
                Toggle("Open \(model.displayName) at login", isOn: Binding(
                    get: { launchAtLogin },
                    set: { enabled in
                        launchAtLogin = LaunchAtLoginChoice.userSet(enabled, site: model.site)
                        requiresApproval = LaunchAtLogin.requiresApproval
                    }
                ))
                if requiresApproval {
                    Text("Waiting for approval in System Settings › General › Login Items.")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
            }
            if model.configStore.config?.notifications == true {
                notificationsSection
            }
            Section {
                LabeledContent("Site", value: model.site)
                LabeledContent("Name", value: model.displayName)
                LabeledContent("URL", value: model.configStore.config?.url.absoluteString ?? "not loaded")
                LabeledContent("Version", value: model.version)
                LabeledContent("Build", value: model.buildLabel)
                LabeledContent("Signed by", value: CodeSigning.signer)
                if let error = model.configStore.error {
                    LabeledContent("Config", value: "the last load failed: \(error)")
                }
            }
        }
        .formStyle(.grouped)
        .frame(width: 460)
        .fixedSize(horizontal: false, vertical: true)
        .onAppear {
            launchAtLogin = LaunchAtLogin.isEnabled
            requiresApproval = LaunchAtLogin.requiresApproval
            model.notifier.refreshAuthorization()
        }
    }

    /// macOS's answer, not a preference of the app's: turning it on asks
    /// macOS the first time, and after that only System Settings changes it.
    private var notificationsSection: some View {
        let notifier = model.notifier
        return Section {
            Toggle("Show notifications", isOn: Binding(
                get: { notifier.authorization == .authorized },
                set: { on in
                    if on && notifier.authorization == .notDetermined {
                        notifier.requestAuthorization()
                    } else {
                        notifier.openSystemSettings()
                    }
                }
            ))
            switch notifier.authorization {
            case .notDetermined:
                Text("macOS asks the first time \(model.displayName) asks to notify you, or when you turn this on.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            case .denied:
                HStack {
                    Text("Turned off in System Settings › Notifications.")
                        .font(.caption)
                        .foregroundStyle(.orange)
                    Spacer()
                    Button("Open Notification Settings…") { notifier.openSystemSettings() }
                        .controlSize(.small)
                }
            case .authorized:
                Text("\(model.displayName) also needs its own desktop notifications setting turned on.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }
}
