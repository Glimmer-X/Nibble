import AppKit

/// The panel's edges and corners, above everything else: dragging one changes the size, the
/// opposite side staying put. Each edge takes the outer 8 pt; each corner reaches 20 pt along both
/// of its sides, so it is as easy to catch as an edge. Elsewhere the view lets presses through.
///
/// The view only reports: which side is under the pointer (the board lights it) and the drag's
/// start, moves and end. The controller works out the size from the pointer's place on screen.
@MainActor
final class PanelEdges: NSView {
    struct Sides: OptionSet, Hashable {
        let rawValue: Int
        static let top = Sides(rawValue: 1)
        static let bottom = Sides(rawValue: 2)
        static let left = Sides(rawValue: 4)
        static let right = Sides(rawValue: 8)
        static let all: Sides = [.top, .bottom, .left, .right]
        static let across: Sides = [.left, .right]
    }

    static let thickness = 8.0
    static let cornerReach = 20.0

    /// The sides that may be dragged now (none while the panel opens or folds).
    var allowed: Sides = [] {
        didSet {
            guard allowed != oldValue else { return }
            window?.invalidateCursorRects(for: self)
            if !dragging { hover(sides(at: pointer)) }
        }
    }
    /// The sides under the pointer, or being dragged.
    private(set) var lit: Sides = []
    private(set) var dragging = false

    /// The drag's start, moves and end, with the pointer's place on screen.
    var onBegin: (Sides, NSPoint) -> Void = { _, _ in }
    var onMove: (NSPoint) -> Void = { _ in }
    var onEnd: () -> Void = {}

    override var isFlipped: Bool { true }
    override var mouseDownCanMoveWindow: Bool { false }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    /// The sides a point (view coordinates, from the top left) is on, among those allowed.
    func sides(at p: NSPoint) -> Sides {
        guard bounds.contains(p) else { return [] }
        var sides: Sides = []
        for (rect, piece) in pieces() where rect.contains(p) { sides.formUnion(piece) }
        return sides
    }

    /// The edges' strips and the corners' L shapes, each with the sides it drags. A corner reaches
    /// further along its sides only when both of them may be dragged.
    private func pieces() -> [(NSRect, Sides)] {
        let w = bounds.width, h = bounds.height
        let t = Self.thickness, c = Self.cornerReach
        let corners = Self.corners.filter { allowed.isSuperset(of: $0) }
        func reach(_ corner: Sides) -> CGFloat { corners.contains(corner) ? c : 0 }
        var result: [(NSRect, Sides)] = []
        if allowed.contains(.top) {
            let a = reach([.top, .left]), b = reach([.top, .right])
            result.append((NSRect(x: a, y: 0, width: w - a - b, height: t), .top))
        }
        if allowed.contains(.bottom) {
            let a = reach([.bottom, .left]), b = reach([.bottom, .right])
            result.append((NSRect(x: a, y: h - t, width: w - a - b, height: t), .bottom))
        }
        if allowed.contains(.left) {
            let a = reach([.top, .left]), b = reach([.bottom, .left])
            result.append((NSRect(x: 0, y: a, width: t, height: h - a - b), .left))
        }
        if allowed.contains(.right) {
            let a = reach([.top, .right]), b = reach([.bottom, .right])
            result.append((NSRect(x: w - t, y: a, width: t, height: h - a - b), .right))
        }
        for corner in corners {
            let x = corner.contains(.left) ? 0 : w - c
            let y = corner.contains(.top) ? 0 : h - c
            let along = NSRect(x: x, y: corner.contains(.top) ? 0 : h - t, width: c, height: t)
            let down = NSRect(x: corner.contains(.left) ? 0 : w - t, y: y, width: t, height: c)
            result.append((along, corner))
            result.append((down, corner))
        }
        return result
    }

    private static let corners: [Sides] = [[.top, .left], [.top, .right], [.bottom, .left], [.bottom, .right]]

    override func hitTest(_ point: NSPoint) -> NSView? {
        guard let superview else { return nil }
        let p = convert(point, from: superview)
        return sides(at: p).isEmpty ? nil : self
    }

    // MARK: - Pointer

    private var pointer: NSPoint {
        guard let window else { return NSPoint(x: -1, y: -1) }
        return convert(window.mouseLocationOutsideOfEventStream, from: nil)
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        for area in trackingAreas { removeTrackingArea(area) }
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseMoved, .mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self))
    }

    override func resetCursorRects() {
        for (rect, cursor) in cursorRects() { addCursorRect(rect, cursor: cursor) }
    }

    override func mouseMoved(with event: NSEvent) {
        guard !dragging else { return }
        hover(sides(at: convert(event.locationInWindow, from: nil)))
    }

    override func mouseExited(with event: NSEvent) {
        guard !dragging else { return }
        hover([])
    }

    override func mouseDown(with event: NSEvent) {
        let sides = sides(at: convert(event.locationInWindow, from: nil))
        guard !sides.isEmpty else { return }
        dragging = true
        lit = sides
        Self.cursor(for: sides).set()
        onBegin(sides, event.screenLocation)
    }

    override func mouseDragged(with event: NSEvent) {
        guard dragging else { return }
        onMove(event.screenLocation)
    }

    override func mouseUp(with event: NSEvent) {
        guard dragging else { return }
        dragging = false
        onEnd()
        hover(sides(at: convert(event.locationInWindow, from: nil)))
    }

    private func hover(_ sides: Sides) {
        let before = lit
        lit = sides
        if !sides.isEmpty {
            Self.cursor(for: sides).set()
        } else if !before.isEmpty {
            NSCursor.arrow.set()
        }
    }

    // MARK: - Cursors

    static func cursor(for sides: Sides) -> NSCursor {
        let position: NSCursor.FrameResizePosition
        switch sides {
        case [.top, .left]: position = .topLeft
        case [.top, .right]: position = .topRight
        case [.bottom, .left]: position = .bottomLeft
        case [.bottom, .right]: position = .bottomRight
        case .top: position = .top
        case .bottom: position = .bottom
        case .left: position = .left
        default: position = .right
        }
        return NSCursor.frameResize(position: position, directions: .all)
    }

    /// The cursor for each edge and corner (the system shows them while the panel is key; the
    /// pointer's moves set them otherwise).
    private func cursorRects() -> [(NSRect, NSCursor)] {
        pieces().map { ($0.0, Self.cursor(for: $0.1)) }
    }
}
