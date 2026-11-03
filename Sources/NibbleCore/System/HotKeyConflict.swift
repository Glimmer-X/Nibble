import Foundation

/// Something else that answers the same key combination as Nibble's summon shortcut. Nibble still
/// lets the reader choose it; the settings page shows the conflict.
public enum HotKeyConflict: Sendable, Hashable {
    /// One of macOS's own shortcuts.
    case system(SystemShortcut)
    /// A shortcut nearly every app uses, which a global shortcut takes away from all of them.
    case common(CommonShortcut)
    /// Another app's global shortcut, by the app's name.
    case app(String)
    /// Something on the system holds the combination for itself (found by trying to take it).
    case taken
}

public enum SystemShortcut: Sendable, Hashable {
    case spotlight, finderSearch, inputSource, missionControl, appWindows, switchSpace
    case screenshot, screenshotTool, helpMenu, dockHiding
}

public enum CommonShortcut: Sendable, Hashable {
    case quit, closeWindow, copy, paste, cut, undo, redo, selectAll, save, new, newTab, open, print, find, hide, minimize
    case switchApps, switchWindows

    /// The shortcut every app shares for this combination, if any (⌘ with a letter, ⌘Tab, ⌘`).
    public static func matching(_ combo: KeyCombo) -> CommonShortcut? {
        // macOS virtual key codes (kVK_ANSI_*).
        let command: [UInt16: CommonShortcut] = [
            12: .quit, 13: .closeWindow, 8: .copy, 9: .paste, 7: .cut, 6: .undo, 0: .selectAll, 1: .save,
            45: .new, 17: .newTab, 31: .open, 35: .print, 3: .find, 4: .hide, 46: .minimize,
            48: .switchApps, 50: .switchWindows,
        ]
        if combo.modifiers == [.command] { return command[combo.keyCode] }
        if combo.modifiers == [.command, .shift], combo.keyCode == 6 { return .redo }
        return nil
    }
}
