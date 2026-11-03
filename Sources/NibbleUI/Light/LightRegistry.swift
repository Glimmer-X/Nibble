import SwiftUI

/// The coordinate space of a window's board: points from its top left, the board's own
/// coordinates. Every window with a board names its root view this.
enum BoardSpace {
    static let name = "nibble.board"
}

/// What a board needs to know about the controls and text floating on it: where they are, which
/// is under the pointer, where the reader's own text sits. Views report here as they lay out; the
/// window's controller reads it once a frame. Not observed, so reporting never re-renders anything.
/// Each window with a board has its own registry, handed to its views through the environment.
///
/// Every entry remembers the view that made it, and a view that goes away removes only its own:
/// when one view takes another's place under the same name (the next transcript in history), the
/// new one reports before the old one leaves, and the old one must not take the new entry with it.
@MainActor
final class LightRegistry {
    /// The soft light a control gets.
    enum Kind {
        /// A round glow under a key.
        case key
        /// The send key's halo.
        case send
        /// A feathered glow under a text button, a choice or a row.
        case segment
        /// Whole cells lit at the control's level (a bar of the settings' section ruler).
        case cells
    }

    /// Where a control lives: the page it belongs to (pages fade in and out as a whole) and,
    /// for controls inside a scrolling area, the area its light is clipped to.
    struct Place: Hashable {
        var page: String
        var clip: String?

        static let chat = Place(page: "chat")
        /// The panel folded into its strip.
        static let strip = Place(page: "strip")
        static let log = Place(page: "chat", clip: "log")
        static let sheet = Place(page: "sheet")
        static let sheetBody = Place(page: "sheet", clip: "sheet")
        static let main = Place(page: "main")
        static func main(_ clip: String) -> Place { Place(page: "main", clip: clip) }
    }

    struct Control {
        var rect: CGRect = .zero
        var kind: Kind
        var place: Place
        var hot = false
        var pressed = false
        /// The light's current value, easing toward its target.
        var level = 0.0
        /// The view that reported it.
        var owner: UUID?
    }

    struct Plate {
        var rect: CGRect
        var rose: Bool
        /// The page the plate belongs to; it shows only while that page is the one in view.
        var page: String
        /// The scrolling area the plate is clipped to.
        var clip: String?
        /// How bright its cells are (a plate under text is 0.27; a lamp brighter).
        var value = 0.27
        /// A lamp lights exactly the cells under it; a plate under text reaches a little past.
        var lamp = false
        /// The view that reported it.
        var owner: UUID?
    }

    struct Scroll: Equatable {
        var offset: CGFloat = 0
        var content: CGFloat = 0
        var container: CGFloat = 0
        /// When the reader last scrolled.
        var touched: Date?
    }

    private(set) var controls: [String: Control] = [:]
    private(set) var plates: [String: Plate] = [:]
    /// The scrolling areas lights are clipped to, by name.
    private(set) var clips: [String: CGRect] = [:]
    private var clipOwners: [String: UUID] = [:]
    /// Places the board's light starts from or stands at (the strip's key and the end of its text),
    /// by name.
    private(set) var anchors: [String: CGRect] = [:]
    private var anchorOwners: [String: UUID] = [:]
    /// The panel's conversation, for the soft column of light at its edge while it scrolls.
    var scroll = Scroll()
    /// Where a dragged file is over the window.
    var drop: CGPoint?

    func update(_ id: String, kind: Kind, place: Place, owner: UUID, _ change: (inout Control) -> Void) {
        var control = controls[id] ?? Control(kind: kind, place: place)
        control.place = place
        control.owner = owner
        change(&control)
        controls[id] = control
    }

    func removeControl(_ id: String, owner: UUID) {
        if controls[id]?.owner == owner { controls[id] = nil }
    }

    func setPlate(_ id: String, _ plate: Plate) {
        plates[id] = plate
    }

    /// Changes a plate's brightness or colour, if `owner` reported it.
    func changePlate(_ id: String, owner: UUID, _ change: (inout Plate) -> Void) {
        guard var plate = plates[id], plate.owner == owner else { return }
        change(&plate)
        plates[id] = plate
    }

    func removePlate(_ id: String, owner: UUID) {
        if plates[id]?.owner == owner { plates[id] = nil }
    }

    func setClip(_ name: String, _ rect: CGRect, owner: UUID) {
        clips[name] = rect
        clipOwners[name] = owner
    }

    func removeClip(_ name: String, owner: UUID) {
        guard clipOwners[name] == owner else { return }
        clips[name] = nil
        clipOwners[name] = nil
    }

    func setAnchor(_ name: String, _ rect: CGRect, owner: UUID) {
        anchors[name] = rect
        anchorOwners[name] = owner
    }

    func removeAnchor(_ name: String, owner: UUID) {
        guard anchorOwners[name] == owner else { return }
        anchors[name] = nil
        anchorOwners[name] = nil
    }

    /// Eases every control's light toward its target and adds the lights and plates to the scene.
    /// `alpha` says how visible each page is; `target` how bright each control should be.
    func light(_ scene: inout BoardScene, dt: Double, alpha: (String) -> Double, target: (Control) -> Double) {
        let step = min(dt, 0.05)
        for (id, var control) in controls {
            let goal = target(control)
            control.level += (goal - control.level) * (1 - exp(-step / 0.08))
            if abs(control.level - goal) < 0.003 { control.level = goal }
            controls[id] = control
            let v = control.level * alpha(control.place.page)
            guard v >= 0.004 else { continue }
            let clip = control.place.clip.flatMap { clips[$0] }.map(Self.rect)
            if control.place.clip != nil, clip == nil { continue }
            let r = control.rect
            switch control.kind {
            case .key, .send:
                scene.lights.append(BoardScene.Round(x: r.midX, y: r.midY, r: control.kind == .send ? 30 : 15, v: v, clip: clip))
            case .segment:
                scene.softs.append(BoardScene.Soft(rect: Self.rect(r), v: v, soft: 7, clip: clip))
            case .cells:
                scene.plates.append(BoardScene.Plate(rect: Self.rect(r), clip: clip, rose: false, value: v, snap: true))
            }
        }
        // Dimmer plates first, so a plate under text shows on a dim plate that holds it.
        for plate in plates.values.sorted(by: { $0.value < $1.value }) where alpha(plate.page) > 0.5 {
            let clip = plate.clip.flatMap { clips[$0] }.map(Self.rect)
            if plate.clip != nil, clip == nil { continue }
            let r = plate.lamp ? plate.rect : plate.rect.insetBy(dx: -2, dy: -2)
            if let clip, r.maxY < clip.y0 || r.minY > clip.y1 { continue }
            scene.plates.append(BoardScene.Plate(rect: Self.rect(r), clip: clip, rose: plate.rose, value: plate.value, snap: plate.lamp))
        }
    }

    /// Whether some control's light is still on its way to its target.
    func isEasing(_ target: (Control) -> Double) -> Bool {
        controls.values.contains { abs($0.level - target($0)) > 0.003 }
    }

    static func rect(_ r: CGRect) -> BoardScene.Rect {
        BoardScene.Rect(x0: r.minX, y0: r.minY, x1: r.maxX, y1: r.maxY)
    }
}

extension EnvironmentValues {
    /// The registry of the window a view is in.
    @Entry var lightRegistry: LightRegistry? = nil
    /// The board of the window a view is in (for surfaces drawn as its cells).
    @Entry var board: Board? = nil
}

extension View {
    /// Reports this control to the board, which lights the cells under it on hover (and while
    /// `pressed`, for keys that stay down).
    func boardLight(_ id: String, _ kind: LightRegistry.Kind, in place: LightRegistry.Place, pressed: Bool = false) -> some View {
        modifier(BoardLightModifier(id: id, kind: kind, place: place, pressed: pressed))
    }

    /// Reports a block of text that sits on a plate of lit cells (rose under an error) on
    /// `page`, clipped to the scrolling area `clip`. A plate under a field or a key may be dimmer
    /// than one under text (`value`).
    /// While `on` is false the plate is off; switching it keeps the view the same view, so its
    /// state (hover, a key about to confirm) carries over.
    func boardPlate(_ id: String, rose: Bool = false, value: Double = 0.27, page: String = "chat", clip: String? = "log", on: Bool = true) -> some View {
        modifier(BoardPlateModifier(id: id, rose: rose, page: page, clip: clip, value: value, lamp: false, on: on))
    }

    /// Reports a lamp: the board cells exactly under this view lit at `value` (a 9 × 9 pt view is
    /// one cell), rose for a warning.
    func boardLamp(_ id: String, value: Double, rose: Bool = false, page: String = "main", clip: String? = "body") -> some View {
        modifier(BoardPlateModifier(id: id, rose: rose, page: page, clip: clip, value: value, lamp: true))
    }

    /// Reports a scrolling area that lights inside it are clipped to.
    func boardClip(_ name: String) -> some View {
        modifier(BoardClipModifier(name: name))
    }

    /// Reports a place the board's light starts from or stands at.
    func boardAnchor(_ name: String) -> some View {
        modifier(BoardClipModifier(name: name, anchor: true))
    }
}

private struct BoardLightModifier: ViewModifier {
    @Environment(\.lightRegistry) private var registry
    @State private var owner = UUID()
    let id: String
    let kind: LightRegistry.Kind
    let place: LightRegistry.Place
    let pressed: Bool

    func body(content: Content) -> some View {
        content
            .onGeometryChange(for: CGRect.self) { $0.frame(in: .named(BoardSpace.name)) } action: { rect in
                registry?.update(id, kind: kind, place: place, owner: owner) { $0.rect = rect }
            }
            .onHover { hot in
                registry?.update(id, kind: kind, place: place, owner: owner) { $0.hot = hot }
            }
            .onChange(of: pressed, initial: true) {
                registry?.update(id, kind: kind, place: place, owner: owner) { $0.pressed = pressed }
            }
            .onDisappear { registry?.removeControl(id, owner: owner) }
    }
}

private struct BoardPlateModifier: ViewModifier {
    @Environment(\.lightRegistry) private var registry
    @State private var owner = UUID()
    let id: String
    let rose: Bool
    let page: String
    let clip: String?
    let value: Double
    let lamp: Bool
    var on = true
    /// Where the view is, kept for turning the plate on without waiting for it to move.
    @State private var seen = Seen()

    final class Seen {
        var rect: CGRect?
    }

    func body(content: Content) -> some View {
        content
            .onGeometryChange(for: CGRect.self) { $0.frame(in: .named(BoardSpace.name)) } action: { rect in
                seen.rect = rect
                if on { report(rect) }
            }
            .onChange(of: on) {
                if on, let rect = seen.rect { report(rect) } else { registry?.removePlate(id, owner: owner) }
            }
            .onChange(of: value) {
                registry?.changePlate(id, owner: owner) { $0.value = value }
            }
            .onChange(of: rose) {
                registry?.changePlate(id, owner: owner) { $0.rose = rose }
            }
            .onDisappear { registry?.removePlate(id, owner: owner) }
    }

    private func report(_ rect: CGRect) {
        registry?.setPlate(id, LightRegistry.Plate(rect: rect, rose: rose, page: page, clip: clip, value: value, lamp: lamp, owner: owner))
    }
}

/// A named rectangle on the board: a scrolling area that clips lights, or an anchor.
private struct BoardClipModifier: ViewModifier {
    @Environment(\.lightRegistry) private var registry
    @State private var owner = UUID()
    let name: String
    var anchor = false

    func body(content: Content) -> some View {
        content
            .onGeometryChange(for: CGRect.self) { $0.frame(in: .named(BoardSpace.name)) } action: { rect in
                if anchor { registry?.setAnchor(name, rect, owner: owner) } else { registry?.setClip(name, rect, owner: owner) }
            }
            .onDisappear {
                if anchor { registry?.removeAnchor(name, owner: owner) } else { registry?.removeClip(name, owner: owner) }
            }
    }
}
