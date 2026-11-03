import AppKit

/// The app's menus, in the interface's language: the app menu (about, settings, hide, quit), Edit
/// (so ⌘C, ⌘V and the rest reach whatever has focus, the panel included) and Window. With Nibble
/// in the menu bar only they are never shown, but their shortcuts still work.
@MainActor
enum MainMenu {
    static func make(_ s: Strings, target: Interface) -> NSMenu {
        let main = NSMenu(title: "Main")

        let app = NSMenu(title: "Nibble")
        let about = app.addItem(withTitle: s.aboutNibble, action: #selector(Interface.openAbout(_:)), keyEquivalent: "")
        about.target = target
        app.addItem(.separator())
        let settings = app.addItem(withTitle: s.settingsMenu, action: #selector(Interface.openSettings(_:)), keyEquivalent: ",")
        settings.target = target
        app.addItem(.separator())
        app.addItem(withTitle: s.hideNibble, action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        let others = app.addItem(withTitle: s.hideOthers, action: #selector(NSApplication.hideOtherApplications(_:)), keyEquivalent: "h")
        others.keyEquivalentModifierMask = [.command, .option]
        app.addItem(withTitle: s.showAll, action: #selector(NSApplication.unhideAllApplications(_:)), keyEquivalent: "")
        app.addItem(.separator())
        app.addItem(withTitle: s.quitNibble, action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        main.addItem(submenu(app))

        let edit = NSMenu(title: s.edit)
        edit.addItem(withTitle: s.undo, action: Selector(("undo:")), keyEquivalent: "z")
        let redo = edit.addItem(withTitle: s.redo, action: Selector(("redo:")), keyEquivalent: "z")
        redo.keyEquivalentModifierMask = [.command, .shift]
        edit.addItem(.separator())
        edit.addItem(withTitle: s.cut, action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        edit.addItem(withTitle: s.copyMenu, action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        edit.addItem(withTitle: s.paste, action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        edit.addItem(withTitle: s.selectAll, action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        main.addItem(submenu(edit))

        let window = NSMenu(title: s.window)
        window.addItem(withTitle: s.minimize, action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")
        window.addItem(withTitle: s.closeWindow, action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        window.addItem(.separator())
        let home = window.addItem(withTitle: s.openNibble, action: #selector(Interface.openHome(_:)), keyEquivalent: "0")
        home.target = target
        let quick = window.addItem(withTitle: s.showQuickChat, action: #selector(Interface.showPanel(_:)), keyEquivalent: "")
        quick.target = target
        main.addItem(submenu(window))
        NSApp.windowsMenu = window
        return main
    }

    private static func submenu(_ menu: NSMenu) -> NSMenuItem {
        let item = NSMenuItem(title: menu.title, action: nil, keyEquivalent: "")
        item.submenu = menu
        return item
    }
}
