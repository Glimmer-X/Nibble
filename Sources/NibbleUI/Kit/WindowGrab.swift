import AppKit
import SwiftUI

/// A press on a window's empty space: once the pointer moves a few points the window follows it
/// exactly, as far as the window lets itself go (`constrainFrameRect`); a press that never moves is
/// a click. Positions are read on the screen, so the window moving under the pointer never feeds
/// back into how far it moves.
@MainActor
final class WindowGrab {
    private let window: NSWindow
    private let mouse: NSPoint
    private let origin: NSPoint
    /// The window has moved: this press is a drag, not a click.
    private(set) var moved = false

    init(_ window: NSWindow, _ event: NSEvent) {
        self.window = window
        mouse = event.screenLocation
        origin = window.frame.origin
    }

    func follow(_ event: NSEvent) {
        let now = event.screenLocation
        let dx = now.x - mouse.x
        let dy = now.y - mouse.y
        if !moved, hypot(dx, dy) < 3 { return }
        moved = true
        let target = NSRect(origin: NSPoint(x: origin.x + dx, y: origin.y + dy), size: window.frame.size)
        window.setFrameOrigin(window.constrainFrameRect(target, to: window.screen).origin)
    }
}

extension NSEvent {
    /// Where the event happened on screen (origin at the bottom left of the main screen), taken
    /// from the event itself: right even while its window moves.
    var screenLocation: NSPoint {
        guard let global = cgEvent?.location, let main = NSScreen.screens.first else { return NSEvent.mouseLocation }
        return NSPoint(x: global.x, y: main.frame.maxY - global.y)
    }
}

/// Empty space that moves the window when dragged; a click on it calls `onClick`. It sits behind
/// the content, so text, images and keys in front take their own presses.
struct DragSurface: NSViewRepresentable {
    var onClick: () -> Void = {}

    func makeNSView(context: Context) -> DragSurfaceView {
        let view = DragSurfaceView()
        view.onClick = onClick
        return view
    }

    func updateNSView(_ view: DragSurfaceView, context: Context) {
        view.onClick = onClick
    }
}

final class DragSurfaceView: NSView {
    var onClick: () -> Void = {}
    private var grab: WindowGrab?

    // The window moves only through `WindowGrab`, never by itself.
    override var mouseDownCanMoveWindow: Bool { false }
    // A panel that is not key still moves with the first press.
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func mouseDown(with event: NSEvent) {
        grab = window.map { WindowGrab($0, event) }
    }

    override func mouseDragged(with event: NSEvent) {
        grab?.follow(event)
    }

    override func mouseUp(with event: NSEvent) {
        if grab?.moved == false { onClick() }
        grab = nil
    }
}
