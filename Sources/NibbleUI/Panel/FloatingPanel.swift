import AppKit

/// The window Nibble lives in: a borderless panel that floats above other windows and the Dock on
/// every Space, including other apps' full-screen Spaces, and takes keyboard input without
/// activating Nibble.
///
/// The rules that make this work (see docs/research/macos-platform.md):
/// - `.nonactivatingPanel` must be in the style mask at init; changing it later leaves the
///   window server out of sync and breaks typing.
/// - The panel may become key (to type) but never main, and the app is never activated:
///   activating would pull the user out of a full-screen Space.
final class FloatingPanel: NSPanel {
    /// Just above the Dock, so the panel can sit over it; below the menu bar and menus.
    static let aboveDock = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.dockWindow)) + 1)

    /// Called when the panel stops being the key window (the user clicked somewhere else).
    var onResignKey: (() -> Void)?
    /// Called for Esc.
    var onCancel: (() -> Void)?
    /// Called for ⌘M (Window ▸ Minimize), which a borderless panel cannot do itself; the quick chat
    /// folds into its strip. `canMiniaturize` says whether it may now.
    var onMiniaturize: (() -> Void)?
    var canMiniaturize: () -> Bool = { true }
    /// Whether the panel may take the keyboard. Not while the quick chat is folded into its strip:
    /// its keys take clicks while typing stays with the app underneath.
    var takesKeyboard = true
    /// Where the panel may go, top to bottom (its screen but the menu bar); empty for anywhere.
    /// A drag stops at its edges instead of being pulled back afterwards.
    var room = NSRect.zero

    init(contentRect: NSRect) {
        super.init(
            contentRect: contentRect,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        isFloatingPanel = true
        level = Self.aboveDock
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle, .stationary]
        hidesOnDeactivate = false
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        // The panel moves only where Nibble says so (its empty space, see `DragSurface`): SwiftUI
        // would otherwise let a press on almost anything move it, the space around text included.
        isMovableByWindowBackground = false
        isReleasedWhenClosed = false
        animationBehavior = .utilityWindow
    }

    override var canBecomeKey: Bool { takesKeyboard }
    override var canBecomeMain: Bool { false }

    override func performMiniaturize(_ sender: Any?) {
        if let onMiniaturize { onMiniaturize() } else { super.performMiniaturize(sender) }
    }

    override func validateUserInterfaceItem(_ item: any NSValidatedUserInterfaceItem) -> Bool {
        if item.action == #selector(performMiniaturize(_:)), onMiniaturize != nil { return canMiniaturize() }
        return super.validateUserInterfaceItem(item)
    }

    override func resignKey() {
        super.resignKey()
        onResignKey?()
    }

    override func cancelOperation(_ sender: Any?) {
        onCancel?()
    }

    /// Keeps the panel's top and bottom inside `room`; sideways it may go anywhere (onto another
    /// screen).
    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect {
        guard room.height > 0 else { return frameRect }
        var frame = frameRect
        frame.origin.y = max(room.minY, min(frame.minY, room.maxY - frame.height))
        return frame
    }

    // MARK: - The input method's windows

    /// Brings the input method's windows (Pinyin's candidates, the input source badge) to the
    /// panel, now and twice more shortly after: an input method answers a key, a change of input
    /// source or Caps Lock with windows of its own a moment later. Called while the composer has
    /// the keyboard, when nothing but the input method opens a window.
    ///
    /// The system makes them in Nibble's process without the panel's Space rules, so over another
    /// app's full-screen Space they open on the desktop, out of sight, and at levels below the
    /// panel's. Rules set once a window is showing do not move it; a child window does go with its
    /// parent, and sits above it. So a showing one becomes the panel's child, and every one also
    /// gets the rules for the next time it opens.
    func followInputMethod() {
        bringInputMethodWindows()
        for delay in [0.03, 0.15] {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in self?.bringInputMethodWindows() }
        }
    }

    private func bringInputMethodWindows() {
        // Closed ones are let go: the candidates are a new window each time.
        for child in childWindows ?? [] where !child.isVisible && Self.isInputMethodWindow(child) {
            removeChildWindow(child)
        }
        for window in NSApp.windows where Self.isInputMethodWindow(window) {
            window.collectionBehavior.formUnion([.canJoinAllSpaces, .fullScreenAuxiliary])
            if isVisible, window.isVisible, window.parent == nil {
                addChildWindow(window, ordered: .above)
            }
        }
    }

    /// A window Nibble did not make: not a panel, not the main window, not the menu bar item's.
    private static func isInputMethodWindow(_ window: NSWindow) -> Bool {
        !(window is FloatingPanel) && !(window is MainWindow) && window.className != "NSStatusBarWindow"
    }
}
