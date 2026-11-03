import Carbon.HIToolbox
import NibbleCore

/// A system-wide shortcut, registered with Carbon's `RegisterEventHotKey`.
///
/// This is still the only public API that receives a key combination from any app and swallows
/// it. It needs no permission and is not deprecated (macOS 27 SDK). It cannot detect whether
/// another app registered the same combination (both registrations succeed); only a combination
/// held exclusively, by macOS for Spotlight say, refuses an exclusive registration (`isTaken`).
@MainActor
public final class GlobalHotKey {
    public struct RegistrationError: Error, CustomStringConvertible {
        public let status: OSStatus
        public var description: String { "RegisterEventHotKey failed (\(status))" }
    }

    /// 'NBBL', marks hotkey events that belong to Nibble.
    nonisolated static let signature: OSType = 0x4E42_424C

    private static var actions: [UInt32: @MainActor () -> Void] = [:]
    private static var nextID: UInt32 = 1
    private static var eventHandler: EventHandlerRef?

    private let id: UInt32
    private var reference: EventHotKeyRef?

    public init(_ combo: KeyCombo, action: @escaping @MainActor () -> Void) throws {
        try Self.installEventHandlerIfNeeded()
        id = Self.nextID
        Self.nextID += 1

        var reference: EventHotKeyRef?
        let status = RegisterEventHotKey(
            UInt32(combo.keyCode),
            Self.carbonModifiers(combo.modifiers),
            EventHotKeyID(signature: Self.signature, id: id),
            GetApplicationEventTarget(),
            0,
            &reference
        )
        guard status == noErr, let reference else { throw RegistrationError(status: status) }
        self.reference = reference
        Self.actions[id] = action
    }

    isolated deinit {
        unregister()
    }

    public func unregister() {
        if let reference {
            UnregisterEventHotKey(reference)
            self.reference = nil
        }
        Self.actions[id] = nil
    }

    /// Whether something holds the combination exclusively: an exclusive registration is refused.
    public static func isTaken(_ combo: KeyCombo) -> Bool {
        var reference: EventHotKeyRef?
        let status = RegisterEventHotKey(
            UInt32(combo.keyCode), carbonModifiers(combo.modifiers),
            EventHotKeyID(signature: signature, id: 0), GetApplicationEventTarget(),
            OptionBits(kEventHotKeyExclusive), &reference
        )
        if let reference { UnregisterEventHotKey(reference) }
        return status == OSStatus(eventHotKeyExistsErr)
    }

    // MARK: - Carbon plumbing

    private static func installEventHandlerIfNeeded() throws {
        guard eventHandler == nil else { return }
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        var handler: EventHandlerRef?
        let status = InstallEventHandler(GetApplicationEventTarget(), hotKeyPressed, 1, &spec, nil, &handler)
        guard status == noErr else { throw RegistrationError(status: status) }
        eventHandler = handler
    }

    fileprivate static func fire(_ id: UInt32) {
        actions[id]?()
    }

    private static func carbonModifiers(_ modifiers: KeyCombo.Modifiers) -> UInt32 {
        var result = 0
        if modifiers.contains(.command) { result |= cmdKey }
        if modifiers.contains(.option) { result |= optionKey }
        if modifiers.contains(.control) { result |= controlKey }
        if modifiers.contains(.shift) { result |= shiftKey }
        return UInt32(result)
    }
}

/// Carbon delivers hotkey events on the main thread, through the application event target.
private func hotKeyPressed(_: EventHandlerCallRef?, _ event: EventRef?, _: UnsafeMutableRawPointer?) -> OSStatus {
    guard let event else { return OSStatus(eventNotHandledErr) }
    var hotKeyID = EventHotKeyID()
    let status = GetEventParameter(
        event,
        EventParamName(kEventParamDirectObject),
        EventParamType(typeEventHotKeyID),
        nil,
        MemoryLayout<EventHotKeyID>.size,
        nil,
        &hotKeyID
    )
    guard status == noErr, hotKeyID.signature == GlobalHotKey.signature else {
        return OSStatus(eventNotHandledErr)
    }
    MainActor.assumeIsolated { GlobalHotKey.fire(hotKeyID.id) }
    return noErr
}
