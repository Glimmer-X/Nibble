import NibbleCore
import Testing
@testable import NibbleSystem

@Suite struct HotKeyConflictTests {
    private let optionSpace = KeyCombo(keyCode: 49, modifiers: [.option])

    @Test func systemShortcutsUseDefaultsUnlessChanged() {
        let commandSpace = KeyCombo(keyCode: 49, modifiers: [.command])
        // Nothing changed: Spotlight is on ⌘Space.
        #expect(HotKeyConflicts.system(commandSpace, symbolicHotKeys: [:]) == [.spotlight])
        // Spotlight turned off.
        #expect(HotKeyConflicts.system(commandSpace, symbolicHotKeys: ["64": ["enabled": false]]).isEmpty)
        // Spotlight moved to ⌥Space (parameters: character, key code, modifier flags).
        let moved: [String: Any] = ["64": ["enabled": true, "value": ["parameters": [32, 49, 1 << 19], "type": "standard"]]]
        #expect(HotKeyConflicts.system(optionSpace, symbolicHotKeys: moved) == [.spotlight])
        #expect(HotKeyConflicts.system(commandSpace, symbolicHotKeys: moved).isEmpty)
    }

    @Test func keyboardShortcutsLibraryEntriesAreRead() {
        #expect(HotKeyConflicts.keyboardShortcut(#"{"carbonKeyCode":49,"carbonModifiers":2048}"#) == optionSpace)
        #expect(HotKeyConflicts.keyboardShortcut(#"{"carbonModifiers":2560,"carbonKeyCode":18}"#)
            == KeyCombo(keyCode: 18, modifiers: [.option, .shift]))
        #expect(HotKeyConflicts.keyboardShortcut("not json") == nil)
    }

    @Test func shortcutsEveryAppSharesAreFlagged() {
        #expect(CommonShortcut.matching(KeyCombo(keyCode: 8, modifiers: [.command])) == .copy)
        #expect(CommonShortcut.matching(KeyCombo(keyCode: 6, modifiers: [.command, .shift])) == .redo)
        #expect(CommonShortcut.matching(optionSpace) == nil)
    }
}
