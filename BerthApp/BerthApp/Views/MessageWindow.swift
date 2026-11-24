import AppKit

/// A small window in place of the page: the template's notice, or why the
/// site's config could not be loaded.
@MainActor
final class MessageWindowController: NSWindowController {
    struct Action {
        let title: String
        let perform: () -> Void
    }

    private var actions: [Action] = []
    private let detail = NSTextField(wrappingLabelWithString: "")

    init(title: String, message: String, detail text: String = "", actions: [Action]) {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 480, height: 200),
                              styleMask: [.titled, .closable, .miniaturizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.title = title
        super.init(window: window)
        self.actions = actions

        let heading = NSTextField(wrappingLabelWithString: message)
        heading.font = .boldSystemFont(ofSize: NSFont.systemFontSize + 1)
        detail.stringValue = text
        detail.isSelectable = true
        detail.font = .monospacedSystemFont(ofSize: NSFont.smallSystemFontSize, weight: .regular)
        detail.textColor = .secondaryLabelColor
        detail.isHidden = text.isEmpty

        let buttonViews: [NSView] = actions.enumerated().reversed().map { index, action in
            let button = NSButton(title: action.title, target: self, action: #selector(runAction(_:)))
            button.tag = index
            button.bezelStyle = .rounded
            if index == 0 { button.keyEquivalent = "\r" }
            return button
        }
        let buttons = NSStackView(views: buttonViews)
        buttons.orientation = .horizontal

        let stack = NSStackView(views: [heading, detail, buttons])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 12
        stack.edgeInsets = NSEdgeInsets(top: 20, left: 20, bottom: 20, right: 20)
        stack.translatesAutoresizingMaskIntoConstraints = false
        let content = NSView()
        content.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: content.topAnchor),
            stack.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            stack.bottomAnchor.constraint(equalTo: content.bottomAnchor),
            stack.widthAnchor.constraint(equalToConstant: 480),
            buttons.trailingAnchor.constraint(equalTo: stack.trailingAnchor, constant: -20),
        ])
        window.contentView = content
        window.center()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func update(detail text: String) {
        detail.stringValue = text
        detail.isHidden = text.isEmpty
    }

    func show() {
        window?.makeKeyAndOrderFront(nil)
    }

    @objc private func runAction(_ sender: NSButton) {
        actions[sender.tag].perform()
    }
}
