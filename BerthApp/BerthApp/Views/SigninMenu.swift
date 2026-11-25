import AppKit
import Combine

/// File → Sign In with 1Password (⇧⌘L), shaped by SigninMenuShape: hidden
/// without a login, one item with one, a submenu of login names with several.
/// Each runs `berth signin` for its login; all are disabled while a sign-in
/// runs.
@MainActor
final class SigninMenuController: NSObject, NSMenuItemValidation {
    private let item: NSMenuItem
    private let separator: NSMenuItem?
    private unowned let model: AppModel
    private var shape: SigninMenuShape?
    private var subscription: AnyCancellable?

    init(item: NSMenuItem, separator: NSMenuItem?, model: AppModel) {
        self.item = item
        self.separator = separator
        self.model = model
        super.init()
        subscription = model.$signinBar
            .map(\.menu)
            .removeDuplicates()
            .sink { [weak self] in self?.apply($0) }
    }

    private func apply(_ shape: SigninMenuShape) {
        guard shape != self.shape else { return }
        self.shape = shape
        item.isHidden = shape == .hidden
        separator?.isHidden = shape == .hidden
        switch shape {
        case .hidden:
            item.submenu = nil
            item.action = nil
        case .item(let login):
            item.submenu = nil
            item.target = self
            item.action = #selector(signIn(_:))
            item.representedObject = login
            item.keyEquivalent = "l"
            item.keyEquivalentModifierMask = [.command, .shift]
        case .submenu(let logins):
            // A submenu's title cannot run an action, so ⇧⌘L has none to run.
            item.action = nil
            item.keyEquivalent = ""
            let menu = NSMenu(title: SigninMenuShape.title)
            for login in logins {
                let entry = NSMenuItem(title: login, action: #selector(signIn(_:)), keyEquivalent: "")
                entry.target = self
                entry.representedObject = login
                menu.addItem(entry)
            }
            item.submenu = menu
        }
    }

    @objc func signIn(_ sender: NSMenuItem) {
        guard let login = sender.representedObject as? String else { return }
        model.startSignin(login: login)
    }

    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        model.signinBar.menuEnabled
    }
}
