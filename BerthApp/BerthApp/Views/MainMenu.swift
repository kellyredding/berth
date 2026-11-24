import AppKit

/// The menu bar. Its Edit items use AppKit's standard selectors, which is what
/// makes copy, paste and undo work in a web page's text fields: WebKit
/// answers them through the responder chain, and without the menu the keys
/// do nothing. The View, File and find items reach BrowserWindowController.
@MainActor
enum MainMenu {
    static func build(appName: String, target: AppDelegate) -> NSMenu {
        let menu = NSMenu()
        menu.addItem(submenu(appMenu(appName, target: target), title: appName))
        menu.addItem(submenu(fileMenu(), title: "File"))
        menu.addItem(submenu(editMenu(), title: "Edit"))
        menu.addItem(submenu(viewMenu(), title: "View"))
        let window = windowMenu()
        menu.addItem(submenu(window, title: "Window"))
        NSApp.windowsMenu = window
        return menu
    }

    private static func appMenu(_ appName: String, target: AppDelegate) -> NSMenu {
        let menu = NSMenu(title: appName)
        menu.addItem(item("About \(appName)", #selector(AppDelegate.showAbout(_:)), "", target: target))
        menu.addItem(.separator())
        menu.addItem(item("Settings…", #selector(AppDelegate.showSettings(_:)), ",", target: target))
        menu.addItem(.separator())
        menu.addItem(item("Hide \(appName)", #selector(NSApplication.hide(_:)), "h"))
        menu.addItem(.separator())
        menu.addItem(item("Quit \(appName)", #selector(NSApplication.terminate(_:)), "q"))
        return menu
    }

    private static func fileMenu() -> NSMenu {
        let menu = NSMenu(title: "File")
        menu.addItem(item("Close Window", #selector(NSWindow.performClose(_:)), "w"))
        menu.addItem(.separator())
        menu.addItem(item("Print…", #selector(BrowserWindowController.printPage(_:)), "p"))
        return menu
    }

    private static func editMenu() -> NSMenu {
        let menu = NSMenu(title: "Edit")
        menu.addItem(item("Undo", Selector(("undo:")), "z"))
        menu.addItem(item("Redo", Selector(("redo:")), "z", [.command, .shift]))
        menu.addItem(.separator())
        menu.addItem(item("Cut", #selector(NSText.cut(_:)), "x"))
        menu.addItem(item("Copy", #selector(NSText.copy(_:)), "c"))
        menu.addItem(item("Paste", #selector(NSText.paste(_:)), "v"))
        menu.addItem(item("Paste and Match Style", #selector(NSTextView.pasteAsPlainText(_:)), "v",
                          [.command, .option, .shift]))
        menu.addItem(item("Delete", #selector(NSText.delete(_:)), ""))
        menu.addItem(item("Select All", #selector(NSText.selectAll(_:)), "a"))
        menu.addItem(.separator())
        let find = NSMenu(title: "Find")
        find.addItem(item("Find…", #selector(BrowserWindowController.showFindBar(_:)), "f"))
        find.addItem(item("Find Next", #selector(BrowserWindowController.findNextMatch(_:)), "g"))
        find.addItem(item("Find Previous", #selector(BrowserWindowController.findPreviousMatch(_:)), "g", [.command, .shift]))
        menu.addItem(submenu(find, title: "Find"))
        return menu
    }

    private static func viewMenu() -> NSMenu {
        let menu = NSMenu(title: "View")
        menu.addItem(item("Reload Page", #selector(BrowserWindowController.reloadPage(_:)), "r"))
        menu.addItem(.separator())
        menu.addItem(item("Back", #selector(BrowserWindowController.historyBack(_:)), "["))
        menu.addItem(item("Forward", #selector(BrowserWindowController.historyForward(_:)), "]"))
        menu.addItem(.separator())
        menu.addItem(item("Actual Size", #selector(BrowserWindowController.actualSize(_:)), "0"))
        menu.addItem(item("Zoom In", #selector(BrowserWindowController.zoomInPage(_:)), "+"))
        // ⌘= is ⌘+ without Shift on most layouts; it answers silently.
        let zoomInEquals = item("Zoom In", #selector(BrowserWindowController.zoomInPage(_:)), "=")
        zoomInEquals.isHidden = true
        zoomInEquals.allowsKeyEquivalentWhenHidden = true
        menu.addItem(zoomInEquals)
        menu.addItem(item("Zoom Out", #selector(BrowserWindowController.zoomOutPage(_:)), "-"))
        menu.addItem(.separator())
        menu.addItem(item("Copy Link to Page", #selector(BrowserWindowController.copyPageLink(_:)), "c", [.command, .shift]))
        menu.addItem(item("Open in Browser", #selector(BrowserWindowController.openInBrowser(_:)), "o", [.command, .shift]))
        return menu
    }

    private static func windowMenu() -> NSMenu {
        let menu = NSMenu(title: "Window")
        menu.addItem(item("Minimize", #selector(NSWindow.performMiniaturize(_:)), "m"))
        return menu
    }

    private static func item(_ title: String, _ action: Selector, _ key: String,
                             _ modifiers: NSEvent.ModifierFlags = .command, target: AnyObject? = nil) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
        item.keyEquivalentModifierMask = key.isEmpty ? [] : modifiers
        item.target = target
        return item
    }

    private static func submenu(_ menu: NSMenu, title: String) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.submenu = menu
        return item
    }
}
