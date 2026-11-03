import AppKit
import Carbon.HIToolbox
import NibbleCore

/// Finds what else answers a key combination: macOS's own shortcuts (from the symbolic hotkeys
/// System Settings keeps, with macOS's defaults for those never changed), shortcuts every app
/// shares, other apps' shortcuts saved by the common KeyboardShortcuts library in their
/// preferences, and anything that holds the combination exclusively. Shortcuts another app takes
/// by other means cannot be seen: Carbon lets several apps register the same combination.
enum HotKeyConflicts {
    /// macOS's shortcuts on by default, by their symbolic hotkey number. System Settings writes an
    /// entry only once one is changed.
    static let systemDefaults: [Int: (shortcut: SystemShortcut, keyCode: UInt16, modifiers: KeyCombo.Modifiers)] = [
        64: (.spotlight, 49, [.command]),
        65: (.finderSearch, 49, [.command, .option]),
        60: (.inputSource, 49, [.control]),
        61: (.inputSource, 49, [.control, .option]),
        32: (.missionControl, 126, [.control]),
        33: (.appWindows, 125, [.control]),
        79: (.switchSpace, 123, [.control]),
        81: (.switchSpace, 124, [.control]),
        28: (.screenshot, 20, [.command, .shift]),
        29: (.screenshot, 20, [.command, .shift, .control]),
        30: (.screenshot, 21, [.command, .shift]),
        31: (.screenshot, 21, [.command, .shift, .control]),
        184: (.screenshotTool, 23, [.command, .shift]),
        98: (.helpMenu, 44, [.command, .shift]),
        52: (.dockHiding, 2, [.command, .option]),
    ]

    /// macOS's shortcuts on the combination, given `AppleSymbolicHotKeys` from
    /// com.apple.symbolichotkeys.
    static func system(_ combo: KeyCombo, symbolicHotKeys entries: [String: Any]) -> [SystemShortcut] {
        var found: [SystemShortcut] = []
        for (id, standard) in systemDefaults {
            var keyCode = standard.keyCode
            var modifiers = standard.modifiers
            if let entry = entries[String(id)] as? [String: Any] {
                guard (entry["enabled"] as? Bool) ?? ((entry["enabled"] as? Int) == 1) else { continue }
                if let parameters = (entry["value"] as? [String: Any])?["parameters"] as? [Int], parameters.count == 3 {
                    keyCode = UInt16(truncatingIfNeeded: parameters[1])
                    modifiers = eventModifiers(parameters[2])
                }
            }
            if keyCode == combo.keyCode, modifiers == combo.modifiers, !found.contains(standard.shortcut) {
                found.append(standard.shortcut)
            }
        }
        return found
    }

    /// A shortcut saved by the KeyboardShortcuts library: `{"carbonKeyCode":49,"carbonModifiers":2048}`.
    static func keyboardShortcut(_ json: String) -> KeyCombo? {
        guard let data = json.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let code = object["carbonKeyCode"] as? Int, let carbon = object["carbonModifiers"] as? Int
        else { return nil }
        var modifiers: KeyCombo.Modifiers = []
        if carbon & cmdKey != 0 { modifiers.insert(.command) }
        if carbon & optionKey != 0 { modifiers.insert(.option) }
        if carbon & controlKey != 0 { modifiers.insert(.control) }
        if carbon & shiftKey != 0 { modifiers.insert(.shift) }
        return KeyCombo(keyCode: UInt16(truncatingIfNeeded: code), modifiers: modifiers)
    }

    /// Bundle identifiers of apps whose preferences save a KeyboardShortcuts shortcut on the
    /// combination. Reads ~/Library/Preferences; only files that mention the library are parsed.
    static func apps(_ combo: KeyCombo, excluding own: String) -> [String] {
        let folder = URL.libraryDirectory.appending(path: "Preferences", directoryHint: .isDirectory)
        guard let files = try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil) else { return [] }
        let marker = Data("KeyboardShortcuts_".utf8)
        var found: [String] = []
        for file in files where file.pathExtension == "plist" {
            let bundleID = file.deletingPathExtension().lastPathComponent
            guard !bundleID.hasPrefix(own),
                  let data = try? Data(contentsOf: file), data.range(of: marker) != nil,
                  let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any]
            else { continue }
            let hit = plist.contains { key, value in
                key.hasPrefix("KeyboardShortcuts_") && (value as? String).flatMap(keyboardShortcut) == combo
            }
            if hit { found.append(bundleID) }
        }
        return found
    }

    private static func eventModifiers(_ flags: Int) -> KeyCombo.Modifiers {
        var modifiers: KeyCombo.Modifiers = []
        if flags & (1 << 20) != 0 { modifiers.insert(.command) }
        if flags & (1 << 19) != 0 { modifiers.insert(.option) }
        if flags & (1 << 18) != 0 { modifiers.insert(.control) }
        if flags & (1 << 17) != 0 { modifiers.insert(.shift) }
        return modifiers
    }
}
