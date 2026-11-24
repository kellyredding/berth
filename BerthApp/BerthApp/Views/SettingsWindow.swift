import AppKit
import SwiftUI

/// Settings: Launch at Login, and what this app is.
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
        }
    }
}
