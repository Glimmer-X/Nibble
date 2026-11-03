import AppKit

extension NSWindow {
    /// Sends `event`, holding the window still when it is a mouse-down on selectable text.
    ///
    /// The main window moves by its background, and SwiftUI's view for selectable text says a
    /// mouse-down there may move the window, so without this a drag across text would move the
    /// window instead of selecting the text. (The panel does not move by its background at all.)
    func sendHoldingStillOverText(_ event: NSEvent, _ send: (NSEvent) -> Void) {
        guard event.type == .leftMouseDown, isMovableByWindowBackground,
              let frame = contentView?.superview,
              frame.hitTest(event.locationInWindow)?.isSelectableText == true
        else { return send(event) }
        isMovableByWindowBackground = false
        send(event)
        isMovableByWindowBackground = true
    }
}

extension NSView {
    /// A text view, or SwiftUI's view for text with selection enabled.
    var isSelectableText: Bool {
        var view: NSView? = self
        while let v = view {
            if v is NSTextView || String(describing: type(of: v)).contains("TextInteraction") { return true }
            view = v.superview
        }
        return false
    }
}

/// The main window: an ordinary window that moves by its background, except over text.
final class MainWindow: NSWindow {
    override func sendEvent(_ event: NSEvent) {
        sendHoldingStillOverText(event) { super.sendEvent($0) }
    }
}
