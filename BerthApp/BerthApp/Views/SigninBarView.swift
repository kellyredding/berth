import AppKit

/// The slim bar above the page that offers to sign in with 1Password and
/// follows a sign-in as it runs. SigninBarState decides what it says; this
/// only draws a Presentation: a symbol, one line of text, a spinner, the
/// sign-in button (a pull-down of login names when there are several) and ×.
@MainActor
final class SigninBarView: NSView {
    static let height: CGFloat = 34

    var onSignIn: ((_ login: String) -> Void)?
    var onDismiss: (() -> Void)?

    private let symbol = NSImageView()
    private let message = NSTextField(labelWithString: "")
    private let spinner = NSProgressIndicator()
    private let button = NSButton(title: "", target: nil, action: nil)
    private let pullDown = NSPopUpButton(frame: .zero, pullsDown: true)
    private let close = NSButton()
    private var logins: [String] = []

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        let material = NSVisualEffectView()
        material.material = .headerView
        material.blendingMode = .withinWindow
        material.state = .followsWindowActiveState

        symbol.symbolConfiguration = .init(pointSize: NSFont.systemFontSize, weight: .regular)
        symbol.setContentHuggingPriority(.required, for: .horizontal)
        message.lineBreakMode = .byTruncatingTail
        message.maximumNumberOfLines = 1
        message.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        message.setContentHuggingPriority(.defaultLow, for: .horizontal)
        spinner.style = .spinning
        spinner.controlSize = .small
        spinner.isDisplayedWhenStopped = false

        button.bezelStyle = .rounded
        button.controlSize = .small
        button.target = self
        button.action = #selector(signIn(_:))
        pullDown.bezelStyle = .rounded
        pullDown.controlSize = .small
        pullDown.target = self
        pullDown.action = #selector(pickLogin(_:))
        for control in [button, pullDown] as [NSControl] {
            control.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
            control.setContentCompressionResistancePriority(.required, for: .horizontal)
        }

        close.image = NSImage(systemSymbolName: "xmark", accessibilityDescription: "Dismiss")
        close.isBordered = false
        close.bezelStyle = .smallSquare
        close.imagePosition = .imageOnly
        close.symbolConfiguration = .init(pointSize: NSFont.smallSystemFontSize, weight: .medium)
        close.contentTintColor = .secondaryLabelColor
        close.toolTip = "Dismiss"
        close.target = self
        close.action = #selector(dismiss(_:))

        let separator = NSBox()
        separator.boxType = .separator

        let row = NSStackView(views: [symbol, message, spinner, button, pullDown, close])
        row.orientation = .horizontal
        row.spacing = 8
        row.setCustomSpacing(10, after: pullDown)
        row.setCustomSpacing(10, after: button)
        row.edgeInsets = NSEdgeInsets(top: 0, left: 12, bottom: 0, right: 10)
        row.detachesHiddenViews = true
        for view in [material, row, separator] {
            view.translatesAutoresizingMaskIntoConstraints = false
            addSubview(view)
        }
        NSLayoutConstraint.activate([
            material.topAnchor.constraint(equalTo: topAnchor),
            material.bottomAnchor.constraint(equalTo: bottomAnchor),
            material.leadingAnchor.constraint(equalTo: leadingAnchor),
            material.trailingAnchor.constraint(equalTo: trailingAnchor),
            row.leadingAnchor.constraint(equalTo: leadingAnchor),
            row.trailingAnchor.constraint(equalTo: trailingAnchor),
            row.centerYAnchor.constraint(equalTo: centerYAnchor),
            separator.leadingAnchor.constraint(equalTo: leadingAnchor),
            separator.trailingAnchor.constraint(equalTo: trailingAnchor),
            separator.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    /// Draws one state. With nothing to show, the window collapses the bar.
    func show(_ presentation: SigninBarState.Presentation, logins: [String]) {
        self.logins = logins
        symbol.image = NSImage(systemSymbolName: presentation.symbol, accessibilityDescription: nil)
        switch presentation.tone {
        case .normal: symbol.contentTintColor = .secondaryLabelColor
        case .success: symbol.contentTintColor = .systemGreen
        case .warning: symbol.contentTintColor = .systemOrange
        }
        message.stringValue = presentation.message
        message.toolTip = presentation.message
        if presentation.spinning {
            spinner.startAnimation(nil)
        } else {
            spinner.stopAnimation(nil)
        }
        spinner.isHidden = !presentation.spinning

        let title = presentation.button
        button.isHidden = title == nil || logins.count > 1
        pullDown.isHidden = title == nil || logins.count <= 1
        if let title {
            if logins.count > 1 {
                pullDown.removeAllItems()
                pullDown.addItem(withTitle: title)
                pullDown.addItems(withTitles: logins)
            } else {
                button.title = title
            }
        }
        close.isHidden = !presentation.dismissible
        setAccessibilityLabel(presentation.message)
    }

    @objc private func signIn(_ sender: Any?) {
        if let login = logins.first { onSignIn?(login) }
    }

    @objc private func pickLogin(_ sender: NSPopUpButton) {
        // Item 0 is the pull-down's own title.
        let index = sender.indexOfSelectedItem - 1
        guard logins.indices.contains(index) else { return }
        onSignIn?(logins[index])
    }

    @objc private func dismiss(_ sender: Any?) { onDismiss?() }
}
