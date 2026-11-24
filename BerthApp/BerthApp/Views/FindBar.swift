import AppKit

/// The find bar above the page: Safari's shape (field, previous, next, Done)
/// driving `WKWebView.find`, which selects and scrolls to each match.
@MainActor
final class FindBar: NSView, NSSearchFieldDelegate {
    static let height: CGFloat = 34

    let field = NSSearchField()
    private let result = NSTextField(labelWithString: "")
    var onFind: ((_ text: String, _ backwards: Bool) -> Void)?
    var onClose: (() -> Void)?

    var text: String { field.stringValue }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor

        field.placeholderString = "Find on Page"
        field.sendsSearchStringImmediately = false
        field.sendsWholeSearchString = false
        field.delegate = self
        field.target = self
        field.action = #selector(search(_:))

        let previous = NSButton(image: NSImage(systemSymbolName: "chevron.left", accessibilityDescription: "Previous")!,
                                target: self, action: #selector(previous(_:)))
        let next = NSButton(image: NSImage(systemSymbolName: "chevron.right", accessibilityDescription: "Next")!,
                            target: self, action: #selector(next(_:)))
        for button in [previous, next] {
            button.bezelStyle = .texturedRounded
            button.controlSize = .small
        }
        let done = NSButton(title: "Done", target: self, action: #selector(done(_:)))
        done.bezelStyle = .rounded
        done.controlSize = .small
        result.textColor = .secondaryLabelColor
        result.font = .systemFont(ofSize: NSFont.smallSystemFontSize)

        let separator = NSBox()
        separator.boxType = .separator

        let row = NSStackView(views: [result, field, previous, next, done])
        row.orientation = .horizontal
        row.spacing = 6
        row.edgeInsets = NSEdgeInsets(top: 0, left: 10, bottom: 0, right: 10)
        for view in [row, separator] {
            view.translatesAutoresizingMaskIntoConstraints = false
            addSubview(view)
        }
        NSLayoutConstraint.activate([
            row.leadingAnchor.constraint(greaterThanOrEqualTo: leadingAnchor),
            row.trailingAnchor.constraint(equalTo: trailingAnchor),
            row.centerYAnchor.constraint(equalTo: centerYAnchor),
            field.widthAnchor.constraint(equalToConstant: 240),
            separator.leadingAnchor.constraint(equalTo: leadingAnchor),
            separator.trailingAnchor.constraint(equalTo: trailingAnchor),
            separator.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func showResult(found: Bool) {
        result.stringValue = found || text.isEmpty ? "" : "Not found"
    }

    @objc private func search(_ sender: Any?) {
        guard !text.isEmpty else {
            showResult(found: true)
            return
        }
        onFind?(text, false)
    }

    @objc private func previous(_ sender: Any?) { if !text.isEmpty { onFind?(text, true) } }

    @objc private func next(_ sender: Any?) { if !text.isEmpty { onFind?(text, false) } }

    @objc private func done(_ sender: Any?) { onClose?() }

    /// Escape closes the bar; Return finds the next match, Shift-Return the previous.
    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        switch selector {
        case #selector(NSResponder.cancelOperation(_:)):
            onClose?()
            return true
        case #selector(NSResponder.insertNewline(_:)):
            if !text.isEmpty { onFind?(text, NSEvent.modifierFlags.contains(.shift)) }
            return true
        default:
            return false
        }
    }
}
