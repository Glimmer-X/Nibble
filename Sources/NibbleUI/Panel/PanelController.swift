import AppKit
import NibbleCore
import SwiftUI

/// Shows, hides, sizes and animates the floating panel, and runs the light board.
///
/// Behaviour (see docs/ARCHITECTURE.md, "Panel behaviour"):
/// - The hotkey summons the panel when it is hidden, gives it focus back when it is visible but
///   unfocused, and puts it away when it has focus. Esc puts it away.
/// - An empty, untouched panel closes when the reader clicks elsewhere; once something is typed
///   or there is a conversation it stays until closed. There is no pin.
/// - The chat keeps one height whatever its content. It unfolds upward from the bar to that
///   height, the bar staying where it is, and folds back down on closing. The reader changes the
///   size by dragging any edge or corner (`PanelEdges`; the bar only sideways), the opposite side
///   staying put; the panel follows the pointer exactly and settles on whole cells (width
///   400–720 pt) when let go. Height and width are remembered. The board's cells stay put on
///   screen while the size changes: they keep to the side that does not move.
/// - The panel opens where the reader last left it (its bottom left corner, remembered across
///   launches), or with the whole chat centred on the screen under the pointer the first time.
///   A chat that would not fit above the bar moves down while it is open; the bar's place stays.
/// - The chat folds into a strip at its top right corner (the header's collapse key, ⌘M), easing in
///   and out, and unfolds from it (a click on it, its unfold key, the hotkey) at the pace the chat
///   unfolds from the bar; the top right corner stays put, so the collapse key becomes the unfold
///   key under the pointer. The strip shows what the reply is doing in the same
///   light, takes clicks but not the keyboard, and moves where it is dragged; the chat unfolds
///   where it was, moved as far as the strip has been (`PanelStrip`).
///
/// Every frame the controller works out the panel's state, tells the board its light (see
/// `LightLanguage`) and hands it the few lights tied to controls and the reader's text.
@MainActor
public final class PanelController {
    static let minWidth = 400.0
    static let maxWidth = 720.0
    static let minHeight = 240.0
    static let maxHeight = 800.0
    /// Where the panel's bottom left corner was last left, in screen coordinates.
    private static let placeKey = "NibblePanelPlace"
    /// The top left corner, kept by earlier versions (read once, then removed).
    private static let oldOriginKey = "NibblePanelOrigin"
    private static let openSeconds = 0.5
    private static let closeSeconds = 0.22
    private static let pageSeconds = 0.48
    /// The time constant every change of the panel's shape eases with: the bar unfolding into the
    /// chat and folding back, the chat unfolding from its strip.
    private static let shapeTau = 0.085
    /// Folding into the strip eases in and out over this long instead: a large chat closing in
    /// at full speed from the first frame read as a jump.
    private static let foldSeconds = 0.36

    let board: Board
    let model: PanelModel
    private let panel: FloatingPanel
    private let boardView: BoardView?
    private var light = LightLanguage()

    /// While true, losing focus never hides the panel (around Nibble's own windows and prompts).
    public var holdsOpen = false

    private var height = 70.0
    private var width = 480.0
    private var openness = 0.0
    /// +1 while opening, −1 while fading out.
    private var opening = 0
    /// The reader is dragging an edge or corner: which sides, and where the drag started.
    private var sizing: (sides: PanelEdges.Sides, mouse: NSPoint, frame: NSRect)?
    /// The frame the drag asked for since the last frame; the window takes it at the next one.
    private var pendingFrame: NSRect?
    private let edges = PanelEdges()
    /// The lit edge's cells, by side and place along it (`rim`), each easing to its own light;
    /// whether any is still on its way.
    private var rimCells: [Int: Double] = [:]
    private var rimEasing = false
    private var moveObserver: Any?
    private var inputSourceObserver: Any?
    private var snapNext = true
    private var lastFrame = 0.0
    private var lightNow: LightState?
    private var restNow: BackgroundMotion?
    /// The bar's bottom edge on screen: the chat grows up from it.
    private var bottom: CGFloat = 0
    /// Where on its screen the panel may go (`room(on:)`); the chat stays inside it, and so does a
    /// drag (the panel stops at its edges).
    private var area: NSRect = .zero {
        didSet { panel.room = area }
    }
    /// Set while the controller moves the panel itself, so only the reader's moves are kept.
    private var placing = false
    private var watchedReply: (id: Message.ID, status: Message.Status)?
    /// The chat folding into its strip or unfolding from it.
    private var fold: Fold?
    /// Where the chat was when it folded: its bar's place (bottom left corner) and its top right
    /// corner. It unfolds there again, moved as far as the strip has been.
    private var foldedFrom: (x: CGFloat, bottom: CGFloat, corner: NSPoint)?
    /// How far a failure's red has spread across the strip from its key (0–1).
    private var alertSpread = 0.0
    private var speedAt = 0.0
    private var scrollGlow = 0.0
    private var monitors: [Any] = []
    /// The answer's speed as the status line shows it, updated twice a second.
    private(set) var shownSpeed = 0.0
    /// The light states and moments the board went through lately (for the self-test).
    private(set) var lightTrail: [LightState] = []
    private(set) var momentTrail: [Moment] = []

    init(app: AppModel) {
        model = PanelModel(app: app)
        width = Self.clampWidth(app.settings.panelWidth)
        board = Board(width: width, maxHeight: Self.maxHeight + 10)
        board.still = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        panel = FloatingPanel(contentRect: NSRect(x: 0, y: 0, width: width, height: height))
        boardView = BoardView(board: board)
        model.controller = self

        let container = PanelContentView(frame: NSRect(x: 0, y: 0, width: width, height: height))
        container.wantsLayer = true
        container.layer?.masksToBounds = true
        if let boardView {
            // As large as the panel can get, plus a cell for the rows and columns kept put while
            // the size is between whole cells; the container clips it.
            boardView.frame = NSRect(x: 0, y: 0, width: Self.maxWidth + 10, height: Self.maxHeight + 10)
            container.addSubview(boardView)
            boardView.onFrame = { [weak self] in self?.frame() }
        }
        let root = PanelRootView()
            .environment(model)
            .environment(app)
            .environment(\.lightRegistry, model.registry)
            .environment(\.board, board)
        let hosting = NSHostingView(rootView: root)
        hosting.sizingOptions = []
        hosting.frame = container.bounds
        hosting.autoresizingMask = [.width, .height]
        container.addSubview(hosting)
        edges.frame = container.bounds
        edges.autoresizingMask = [.width, .height]
        edges.onBegin = { [weak self] sides, mouse in self?.beginResize(sides, at: mouse) }
        edges.onMove = { [weak self] mouse in self?.resize(to: mouse) }
        edges.onEnd = { [weak self] in self?.endResize() }
        container.addSubview(edges)
        panel.contentView = container
        container.accepts = { [weak self] in self?.model.mini == false }
        container.onHover = { [weak self] point in self?.model.registry.drop = point }
        container.onImages = { [weak self] items in
            for item in items { self?.model.attach(data: item.data, name: item.name) }
        }
        panel.isOpaque = true
        panel.onResignKey = { [weak self] in self?.focusLost() }
        panel.onCancel = { [weak self] in self?.cancel() }
        panel.onMiniaturize = { [weak self] in self?.collapse() }
        panel.canMiniaturize = { [weak self] in self?.canCollapse ?? false }
        applyColours()
        installMonitors()
        // The reader moved the panel: its bottom left corner is where it opens next time.
        moveObserver = NotificationCenter.default.addObserver(forName: NSWindow.didMoveNotification, object: panel, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.panelMoved() }
        }
    }

    public var isVisible: Bool { panel.isVisible }

    // MARK: - Summon and dismiss

    public func toggle() {
        if !panel.isVisible || opening < 0 || model.closing {
            summon()
        } else if model.mini {
            expand()
        } else if !panel.isKeyWindow {
            takeFocus()
        } else {
            dismiss()
        }
    }

    public func summon() {
        // Folded into its strip, the chat unfolds instead.
        if model.mini, panel.isVisible, opening >= 0 {
            expand()
            return
        }
        model.session.prepareForSummon()
        if model.session.conversation.isEmpty { model.view = .bar }
        if !model.session.conversation.isEmpty, !model.collapsing { model.view = .chat }
        model.closing = false
        if !panel.isVisible || opening < 0 {
            if !panel.isVisible {
                placeOnActiveScreen()
                // A chat unfolds from the bar again.
                height = cells(model.composerHeight)
                snapNext = model.view == .bar
                openness = 0
                applyFrame()
            }
            opening = 1
            if board.still { openness = 1 }
            panel.alphaValue = CGFloat(min(1, ease(openness) * 1.6))
            panel.orderFrontRegardless()
            boardView?.needsRedraw = true
            boardView?.running = true
        }
        takeFocus()
    }

    /// Puts `text` in the composer and sends it (the `-NibbleAsk` launch argument, for trying the
    /// panel and taking screenshots).
    public func ask(_ text: String) {
        summon()
        model.session.draft = text
        model.send()
    }

    /// Shows the conversation page (the `-NibblePage sheet` launch argument).
    public func openSheet() {
        summon()
        model.openSheet()
    }

    /// Folds the chat into its strip once it has opened (the `-NibblePage strip` launch argument,
    /// with a question asked so there is a chat).
    public func collapseWhenOpen() {
        Task { @MainActor in
            for _ in 0..<100 where !canCollapse { try? await Task.sleep(for: .milliseconds(50)) }
            collapse()
        }
    }

    /// Opens the header's source menu (the `-NibblePage source` launch argument, with a question
    /// asked so the chat and its header are showing).
    public func openSourceMenu() {
        summon()
        model.menuOpen = true
    }

    /// Shows `conversation` in the chat and summons the panel (history's "continue" key).
    func show(_ conversation: Conversation) {
        model.open(conversation)
        summon()
    }

    /// Closes the panel: a chat folds back into the bar first, then the bar fades out.
    public func dismiss() {
        guard panel.isVisible, !model.closing, opening >= 0 else { return }
        model.menuOpen = false
        // The strip fades out where it is (see `leaveStrip`).
        if model.mini {
            opening = -1
            return
        }
        if model.page == .sheet {
            model.page = .chat
            model.pageChange = nil
        }
        if model.view == .chat && !board.still {
            model.closing = true
        } else {
            opening = -1
        }
    }

    private func takeFocus() {
        panel.makeKey()
        model.focusRequest += 1
        // The input source badge, before the first key: switching sources shows it at the caret.
        panel.followInputMethod()
    }

    /// A click on the panel's empty space: the composer takes the keyboard.
    func focusComposer() {
        guard model.page == .chat, !model.closing else { return }
        takeFocus()
    }

    private func focusLost() {
        guard panel.isVisible, !holdsOpen, model.session.isEmpty, model.page == .chat else { return }
        dismiss()
    }

    /// Esc: closes the menu, leaves the conversation page, stops editing a question, or puts the
    /// panel away.
    private func cancel() {
        if model.menuOpen {
            model.menuOpen = false
        } else if model.page == .sheet {
            model.closeSheet()
        } else if model.session.editing != nil {
            model.cancelEditing()
        } else {
            dismiss()
        }
    }

    /// Puts the bar where the reader last left it, inside that screen; the first time, with the
    /// whole chat centred on the screen under the pointer.
    private func placeOnActiveScreen() {
        let defaults = UserDefaults.standard
        if defaults.array(forKey: Self.placeKey) == nil, let old = defaults.array(forKey: Self.oldOriginKey) as? [Double], old.count == 2 {
            // Earlier versions kept the top left corner of a 70 pt bar.
            defaults.set([old[0], old[1] - 70], forKey: Self.placeKey)
        }
        defaults.removeObject(forKey: Self.oldOriginKey)

        if let saved = defaults.array(forKey: Self.placeKey) as? [Double], saved.count == 2,
           let screen = NSScreen.screens.first(where: { Self.room(on: $0).insetBy(dx: -1, dy: -1).contains(NSPoint(x: saved[0] + 20, y: saved[1] + 10)) }) {
            area = Self.room(on: screen)
            let x = min(max(saved[0], Double(area.minX)), Double(area.maxX) - width)
            bottom = CGFloat(min(max(saved[1], Double(area.minY)), Double(area.maxY) - height))
            place(NSPoint(x: x.rounded(), y: bottom))
            return
        }
        let pointer = NSEvent.mouseLocation
        guard let screen = NSScreen.screens.first(where: { NSMouseInRect(pointer, $0.frame, false) }) ?? NSScreen.main else { return }
        area = Self.room(on: screen)
        // Centred in the part the Dock leaves free.
        let free = screen.visibleFrame
        let chat = min(Double(free.height), cells(model.settings.panelHeight))
        bottom = CGFloat(max(Double(free.minY) + 40, Double(free.midY) - chat / 2)).rounded()
        place(NSPoint(x: (free.midX - width / 2).rounded(), y: bottom))
    }

    /// Moves the panel without taking it for the reader's move.
    private func place(_ origin: NSPoint, height h: CGFloat? = nil) {
        if let h {
            place(NSRect(x: origin.x, y: origin.y, width: CGFloat(width), height: h))
            return
        }
        placing = true
        defer { placing = false }
        panel.setFrameOrigin(origin)
    }

    private func place(_ frame: NSRect) {
        placing = true
        defer { placing = false }
        panel.setFrame(frame, display: true)
    }

    /// Where the panel may go on `screen`: all of it but the menu bar. The Dock may be covered (the
    /// panel floats above it).
    private static func room(on screen: NSScreen) -> NSRect {
        var room = screen.frame
        room.size.height = screen.visibleFrame.maxY - room.minY
        return room
    }

    private func rememberPlace(x: CGFloat? = nil) {
        UserDefaults.standard.set([Double(x ?? panel.frame.minX), Double(bottom)], forKey: Self.placeKey)
    }

    /// The reader moved the panel: its bottom edge anchors later changes of height, and its bottom
    /// left corner is remembered. The strip's moves are read when the chat unfolds.
    private func panelMoved() {
        guard panel.isVisible, !placing else { return }
        if let screen = panel.screen { area = Self.room(on: screen) }
        guard !model.mini, fold == nil else { return }
        bottom = panel.frame.minY
        rememberPlace()
    }

    // MARK: - The strip

    /// The chat folding into its strip or unfolding from it: where the panel set off and where it
    /// is going on screen, how long it has been on its way and how far it has come (0–1). Every
    /// edge moves the same share of its way, so the corner they share stays put: the top right,
    /// unless the screen's edge is in the way.
    private struct Fold {
        let from: NSRect
        let to: NSRect
        let toStrip: Bool
        var elapsed = 0.0
        var progress = 0.0

        var frame: NSRect {
            func mix(_ a: CGFloat, _ b: CGFloat) -> CGFloat { (a + (b - a) * progress).rounded() }
            let x0 = mix(from.minX, to.minX), x1 = mix(from.maxX, to.maxX)
            let y0 = mix(from.minY, to.minY), y1 = mix(from.maxY, to.maxY)
            return NSRect(x: x0, y: y0, width: x1 - x0, height: y1 - y0)
        }
    }

    /// Folded into the strip, or on the way into it or out of it.
    private var folded: Bool { model.mini || fold != nil }

    /// The chat may fold while it is open and still: not while it opens, closes, folds or changes
    /// size.
    var canCollapse: Bool {
        panel.isVisible && opening == 0 && model.view == .chat && !model.mini && !model.closing && !model.collapsing
            && fold == nil && sizing == nil && abs(height - targetHeight()) < 0.5
    }

    /// Folds the chat into its strip at its top right corner; typing goes back to the app underneath.
    func collapse() {
        guard canCollapse else { return }
        model.menuOpen = false
        if model.page == .sheet {
            model.page = .chat
            model.pageChange = nil
        }
        let chat = panel.frame
        let size = PanelStrip.size(model.strings)
        foldedFrom = (chat.minX, bottom, NSPoint(x: chat.maxX, y: chat.maxY))
        model.chatSize = chat.size
        model.mini = true
        fold = Fold(from: chat, to: NSRect(x: chat.maxX - size.width, y: chat.maxY - size.height, width: size.width, height: size.height), toStrip: true)
        releaseKeyboard()
    }

    /// Unfolds the chat from its strip where it was, moved as far as the strip has been and kept on
    /// the strip's screen, and gives it the keyboard.
    func expand() {
        guard model.mini, let place = foldedFrom else { return }
        let strip = fold?.to ?? panel.frame
        let middle = NSPoint(x: strip.midX, y: strip.midY)
        if let screen = NSScreen.screens.first(where: { $0.frame.contains(middle) }) ?? panel.screen { area = Self.room(on: screen) }
        model.mini = false
        let w = CGFloat(Self.clampWidth(model.settings.panelWidth))
        let h = CGFloat(targetHeight())
        var x = place.x + strip.maxX - place.corner.x
        var bar = place.bottom + strip.maxY - place.corner.y
        if area.height > 0 {
            x = min(max(x, area.minX), area.maxX - w)
            bar = min(max(bar, area.minY), area.maxY - CGFloat(cells(model.composerHeight)))
        }
        let y = area.height > 0 ? max(area.minY, min(bar, area.maxY - h)) : bar
        bottom = bar
        foldedFrom = nil
        model.chatSize = CGSize(width: w, height: h)
        fold = Fold(from: fold?.frame ?? panel.frame, to: NSRect(x: x, y: y, width: w, height: h), toStrip: false)
        panel.takesKeyboard = true
        takeFocus()
    }

    /// Typing goes back to the app underneath. A panel keeps the keyboard until another window
    /// takes it, and that app, still the active one, will not take it back when asked to activate;
    /// so the panel steps out and back in front in the same moment, with the window's own fade
    /// turned off (with it the panel flickered).
    private func releaseKeyboard() {
        panel.takesKeyboard = false
        guard panel.isKeyWindow else { return }
        let behavior = panel.animationBehavior
        panel.animationBehavior = .none
        panel.orderOut(nil)
        panel.orderFrontRegardless()
        panel.animationBehavior = behavior
    }

    /// Every edge a step closer to where the fold is going; at its end the chat or the strip
    /// settles. Into the strip the edges ease in and out over `foldSeconds`, so the chat starts to
    /// close in gently and its pages fade as it goes; out of it they ease like the bar unfolding.
    private func layoutFold(_ dt: Double) {
        guard var f = fold else { return }
        f.elapsed += dt
        if board.still {
            f.progress = 1
        } else if f.toStrip {
            f.progress = smooth(0, Self.foldSeconds, f.elapsed)
        } else {
            f.progress += (1 - f.progress) * (1 - exp(-dt / Self.shapeTau))
            if 1 - f.progress < 0.002 { f.progress = 1 }
        }
        let r = f.frame
        width = Double(r.width)
        height = Double(r.height)
        sizeBoard()
        place(r)
        edges.allowed = []
        model.mininess = f.toStrip ? f.progress : 1 - f.progress
        fold = f.progress < 1 ? f : nil
        if fold == nil, !f.toStrip { rememberPlace() }
    }

    /// The strip at rest: as wide as its words need (they change with the text size and language),
    /// its top right corner where the reader left it.
    private func holdStrip() {
        let size = PanelStrip.size(model.strings)
        width = Double(size.width)
        height = Double(size.height)
        sizeBoard()
        edges.allowed = []
        let f = panel.frame
        if f.size != size { place(NSRect(x: f.maxX - size.width, y: f.maxY - size.height, width: size.width, height: size.height)) }
    }

    /// The strip has faded out: the chat is itself again, its bar's place moved as far as the strip
    /// was, ready to open there next time.
    private func leaveStrip() {
        if let place = foldedFrom {
            let strip = panel.frame
            bottom = place.bottom + strip.maxY - place.corner.y
            UserDefaults.standard.set([Double(place.x + strip.maxX - place.corner.x), Double(bottom)], forKey: Self.placeKey)
        }
        foldedFrom = nil
        fold = nil
        model.mini = false
        model.mininess = 0
        panel.takesKeyboard = true
        alertSpread = 0
    }

    private static func clampWidth(_ w: Double) -> Double {
        min(maxWidth, max(minWidth, w))
    }

    /// The middle of the panel on screen, for capturing the display it is on.
    var screenPoint: CGPoint { CGPoint(x: panel.frame.midX, y: panel.frame.midY) }

    // MARK: - What the views report

    func messageSent() {
        play(.rise)
    }

    /// Plays a moment on the board.
    func play(_ moment: Moment) {
        board.play(moment)
        momentTrail.append(moment)
        if momentTrail.count > 16 { momentTrail.removeFirst() }
    }

    // MARK: - For the self-test

    var windowHeight: Double { Double(panel.frame.height) }
    var windowFrame: NSRect { panel.frame }
    var isKey: Bool { panel.isKeyWindow }

    /// Moves the panel as a drag would.
    func move(to origin: NSPoint) { panel.setFrameOrigin(origin) }

    /// Forgets where the panel was left (after the self-test moved it).
    func forgetPlace() { UserDefaults.standard.removeObject(forKey: Self.placeKey) }

    /// Plays thinking as the tunnel from its first moment, skipping the stars (the demo's
    /// recording only; the panel itself starts with stars).
    func thinkAsTunnel() { light.think = light.deep }

    /// Sets where the bar's bottom left corner opens next (the demo's recording).
    func setPlace(_ origin: NSPoint) { UserDefaults.standard.set([Double(origin.x), Double(origin.y)], forKey: Self.placeKey) }

    func clearTrail() {
        lightTrail = []
        momentTrail = []
    }

    /// Clicking elsewhere, as the reader would, even while the self-test holds the panel open.
    func simulateFocusLost() {
        let held = holdsOpen
        holdsOpen = false
        focusLost()
        holdsOpen = held
    }

    /// What a press lands on, for the self-test.
    enum PressTarget: String {
        case edge, text, drag, other
    }

    /// What a press at `point` (points from the panel's top left) lands on.
    func pressTarget(at point: CGPoint) -> PressTarget {
        guard let content = panel.contentView, let frame = content.superview,
              let hit = frame.hitTest(content.convert(NSPoint(x: point.x, y: point.y), to: frame))
        else { return .other }
        if hit is PanelEdges { return .edge }
        if hit is DragSurfaceView { return .drag }
        if hit.isSelectableText { return .text }
        return .other
    }

    var composerTextView: ComposerTextView? {
        func find(_ view: NSView) -> ComposerTextView? {
            if let text = view as? ComposerTextView { return text }
            for sub in view.subviews { if let found = find(sub) { return found } }
            return nil
        }
        return panel.contentView.flatMap(find)
    }

    /// A character was typed at `point` (window coordinates): the board answers in the typing style.
    func typed(at point: NSPoint) {
        model.settleFailure()
        guard let kind = light.typing else { return }
        board.keyPress(kind, x: Double(point.x) + cellShift.x, y: height - Double(point.y) + cellShift.y)
    }

    // MARK: - Resizing

    /// The sides the reader may drag now: every edge of the chat, the bar's sides only, none while
    /// the panel opens, folds or closes.
    private var resizableSides: PanelEdges.Sides {
        guard panel.isVisible, opening == 0, !model.closing, !model.collapsing, !folded else { return [] }
        if model.view == .bar && model.page == .chat { return .across }
        return abs(height - targetHeight()) < 0.5 || sizing != nil ? .all : []
    }

    /// A drag on an edge or corner began, with the pointer at `mouse` (screen coordinates).
    func beginResize(_ sides: PanelEdges.Sides, at mouse: NSPoint) {
        if let screen = panel.screen { area = Self.room(on: screen) }
        sizing = (sides, mouse, panel.frame)
    }

    /// The pointer moved to `mouse` while dragging: the dragged sides follow it exactly, the
    /// opposite ones stay where they are; the size stays within its limits and the screen. The
    /// window takes the size at the next frame, with the board drawn for it (see `frame()`).
    func resize(to mouse: NSPoint) {
        guard let (sides, start, from) = sizing else { return }
        let dx = (mouse.x - start.x).rounded()
        let dy = (mouse.y - start.y).rounded()
        let room = area.width > 0 ? area : NSRect(x: -1e6, y: -1e6, width: 2e6, height: 2e6)
        var f = from
        if sides.contains(.right) {
            f.size.width = min(Self.clampWidth(from.width + dx), max(Self.minWidth, room.maxX - from.minX))
        }
        if sides.contains(.left) {
            f.size.width = min(Self.clampWidth(from.width - dx), max(Self.minWidth, from.maxX - room.minX))
            f.origin.x = from.maxX - f.width
        }
        if sides.contains(.top) {
            f.size.height = min(Self.clampHeight(from.height + dy), max(Self.minHeight, room.maxY - from.minY))
        }
        if sides.contains(.bottom) {
            f.size.height = min(Self.clampHeight(from.height - dy), max(Self.minHeight, from.maxY - room.minY))
            f.origin.y = from.maxY - f.height
        }
        width = Double(f.width)
        if model.view == .chat { height = Double(f.height) }
        bottom = f.minY
        pendingFrame = NSRect(x: f.minX, y: f.minY, width: f.width, height: CGFloat(height.rounded()))
    }

    /// Let go: the size settles on whole cells (the dragged sides moving, the others staying) and
    /// is kept, with the bar's place.
    func endResize() {
        guard let (sides, _, _) = sizing else { return }
        sizing = nil
        let P = board.look.pitch
        var f = pendingFrame ?? panel.frame
        let w = Self.clampWidth((Double(f.width) / P).rounded() * P)
        if sides.contains(.left) { f.origin.x = f.maxX - CGFloat(w) }
        f.size.width = CGFloat(w)
        width = w
        model.settings.panelWidth = w
        if model.view == .chat, !sides.isDisjoint(with: [.top, .bottom]) {
            let h = Self.clampHeight((Double(f.height) / P).rounded() * P)
            if sides.contains(.bottom) { f.origin.y = f.maxY - CGFloat(h) }
            f.size.height = CGFloat(h)
            height = h
            model.settings.panelHeight = h
        }
        bottom = f.minY
        pendingFrame = f
        rememberPlace(x: f.minX)
    }

    private static func clampHeight(_ h: Double) -> Double {
        min(maxHeight, max(minHeight, h))
    }

    // MARK: - A frame

    private func frame() -> BoardScene? {
        let now = ProcessInfo.processInfo.systemUptime
        let dt = lastFrame > 0 ? min(0.05, now - lastFrame) : 1.0 / 60
        lastFrame = now
        let date = Date()

        if opening != 0 {
            openness = min(1, max(0, openness + Double(opening) * dt / (opening > 0 ? Self.openSeconds : Self.closeSeconds)))
            if board.still { openness = opening > 0 ? 1 : 0 }
            if opening > 0, openness >= 1 { opening = 0 }
            if opening < 0, openness <= 0 {
                opening = 0
                panel.orderOut(nil)
                if folded { leaveStrip() }
                panel.alphaValue = 1
                boardView?.running = false
                lastFrame = 0
                return nil
            }
            panel.alphaValue = CGFloat(min(1, ease(openness) * 1.6))
        }

        // A drag always holds the button down: with none held, no image is on its way, whatever
        // the drop did or did not hear (a drag cancelled over the panel tells it nothing).
        if model.registry.drop != nil, NSEvent.pressedMouseButtons == 0 { model.registry.drop = nil }
        followSystem()
        updateLight(date)
        noticeFinishedReply()
        // The window changes size here rather than at each move of the pointer, so the window, its
        // controls and the board's cells for the new size reach the screen in one step.
        let shown = panel.frame
        if let f = pendingFrame {
            pendingFrame = nil
            place(f)
        }
        layout(dt)
        updatePage(date)

        let display = model.keyDisplay(at: date)
        if display != model.keyDisplay {
            model.keyDisplay = display
            model.keyDisplaySince = date
        }
        let dots = display.frame(date.timeIntervalSince(model.keyDisplaySince))
        if dots != model.keyDots { model.keyDots = dots }
        if now - speedAt > 0.5 {
            speedAt = now
            shownSpeed = model.session.tokensPerSecond(at: date)
        }
        let scene = scene(dt)
        boardView?.presentsWithWindow = panel.frame != shown
        // Slow light needs only half the frames; waves, moments, typing and the panel's own
        // movement get all of them.
        let busy = board.wantsFullRate || opening != 0 || sizing != nil || rimEasing || model.pageChange != nil || scrollGlow > 0.01
            || fold != nil || alertSpread > 0 && alertSpread < 1
            || abs(height - targetHeight()) > 0.5
            || model.registry.isEasing(lightTarget)
        boardView?.framesPerSecond = busy ? 60 : 30
        return scene
    }

    private func followSystem() {
        if board.palette != model.palette { applyColours() }
    }

    private func applyColours() {
        board.setPalette(model.palette)
        let ground = board.groundFill
        panel.backgroundColor = NSColor(srgbRed: CGFloat(ground.x) / 255, green: CGFloat(ground.y) / 255, blue: CGFloat(ground.z) / 255, alpha: 1)
        panel.appearance = NSAppearance(named: model.appearance == .dark ? .darkAqua : .aqua)
    }

    /// Tells the board the current state's light when the state changes. Every change releases an
    /// error's hold (or sets one); an error keeps whatever was playing and holds it.
    private func updateLight(_ date: Date) {
        let state = model.lightState(at: date)
        // At rest the panel plays the light chosen in settings; a new choice takes over at once.
        let rest = model.settings.background
        guard state != lightNow || (state == .idle && rest != restNow) else { return }
        restNow = rest
        if state != lightNow {
            lightNow = state
            lightTrail.append(state)
            if lightTrail.count > 32 { lightTrail.removeFirst() }
        }
        // On the strip a failure turns it red from its key instead of flashing (see `scene`).
        board.hold(state == .error ? light.error : nil, flash: !folded)
        guard state != .error else { return }
        if state == .idle {
            board.setMotion(rest.motion, gain: rest.panelGain)
            return
        }
        let (motion, gain) = light.motion(for: state)
        board.setMotion(motion, gain: gain)
    }

    /// An answer that has just finished blooms the board; any reply that ended is kept in the
    /// list of saved conversations.
    private func noticeFinishedReply() {
        guard let reply = model.session.lastReply else {
            watchedReply = nil
            return
        }
        if let watched = watchedReply, watched.id == reply.id, watched.status == .streaming, reply.status != .streaming {
            if reply.status == .complete, let done = light.done { play(done) }
            model.app.remember(model.session.conversation)
        }
        watchedReply = (reply.id, reply.status)
    }

    /// The height the panel wants: the bar fits the composer; the chat and settings keep the
    /// reader's height.
    private func targetHeight() -> Double {
        let bar = cells(model.composerHeight)
        // Folding to close, then fading out (opening < 0): the bar's height all the way, so the
        // chat never unfolds again on its way out.
        if model.closing || opening < 0 || model.collapsing || (model.view == .bar && model.page == .chat) { return bar }
        let P = board.look.pitch
        return min(max(cells(model.settings.panelHeight), bar), (Self.maxHeight / P).rounded(.down) * P)
    }

    private func layout(_ dt: Double) {
        if fold != nil {
            layoutFold(dt)
            return
        }
        if model.mini {
            holdStrip()
            return
        }
        let target = targetHeight()
        if snapNext || board.still {
            height = target
            snapNext = false
        } else if sizing != nil {
            // The drag sets the height itself.
        } else if height != target {
            height += (target - height) * (1 - exp(-dt / Self.shapeTau))
            if abs(height - target) < 0.5 { height = target }
        }
        applyFrame()
        edges.allowed = resizableSides
        if model.collapsing, height <= target + 0.5 { model.finishCollapse() }
        if model.closing, height <= target + 0.5 {
            model.closing = false
            opening = -1
        }
    }

    private func applyFrame() {
        let w = sizing != nil ? width : Self.clampWidth(model.settings.panelWidth)
        width = w
        sizeBoard()
        guard sizing == nil else { return }
        let h = CGFloat(height.rounded())
        if bottom == 0 { bottom = panel.frame.minY }
        // The bar stays at its place; a chat too tall to fit above it moves down while open.
        var y = bottom
        if area.height > 0 { y = max(area.minY, min(bottom, area.maxY - h)) }
        guard panel.frame.height != h || panel.frame.width != CGFloat(w) || panel.frame.minY != y else { return }
        place(NSPoint(x: panel.frame.minX, y: y), height: h)
    }

    /// The board covers the panel's cells and one more column, for the columns kept put.
    private func sizeBoard() {
        let columns = cells(width) + board.look.pitch
        if board.width != columns {
            board.setSize(width: columns, maxHeight: Self.maxHeight + board.look.pitch)
            boardView?.needsRedraw = true
        }
    }

    /// How far the board's rows sit above the panel's top (and its columns left of the panel's
    /// left edge) while the size is between whole cells: the cells keep to the sides that stay
    /// put, the bar's while the chat unfolds above it, the opposite side's while an edge is dragged,
    /// the top right corner while the chat folds into its strip and back.
    private var cellShift: (x: Double, y: Double) {
        if folded { return (cells(width) - width, 0) }
        let sides = sizing?.sides ?? []
        return (sides.contains(.left) ? cells(width) - width : 0, sides.contains(.bottom) ? 0 : cells(height) - height)
    }

    private func updatePage(_ date: Date) {
        guard var change = model.pageChange else { return }
        change.progress = board.still ? 1 : min(1, date.timeIntervalSince(change.start) / Self.pageSeconds)
        model.pageChange = change.progress >= 1 ? nil : change
    }

    /// A height rounded up to whole cells.
    private func cells(_ x: Double) -> Double {
        let P = board.look.pitch
        return (x / P - 1e-3).rounded(.up) * P
    }

    // MARK: - The scene

    private func scene(_ dt: Double) -> BoardScene {
        var s = BoardScene(width: width, height: height)
        s.open = openness
        s.warm = warmth()
        let registry = model.registry
        let chatAlpha = pageAlpha(.chat) * model.chatFade
        let sheetAlpha = pageAlpha(.sheet) * model.chatFade
        let stripAlpha = model.stripFade
        // Controls (soft light under hovered and pressed keys, the send key's halo) and plates
        // (the reader's own text on whole cells, an error on rose ones).
        registry.light(&s, dt: dt, alpha: { $0 == "sheet" ? sheetAlpha : $0 == "strip" ? stripAlpha : chatAlpha }, target: lightTarget)
        let log = registry.clips["log"].map(LightRegistry.rect)
        let step = min(dt, 0.05)

        // Scroll position: a soft column of light at the right edge while the reader scrolls.
        let scroll = registry.scroll
        let scrolling = scroll.touched.map { Date().timeIntervalSince($0) < 0.9 } ?? false
        scrollGlow += ((scrolling && scroll.content > scroll.container + 4 ? 1 : 0) - scrollGlow) * (1 - exp(-step / 0.15))
        if let log, scrollGlow > 0.01, scroll.content > 0 {
            let h = log.y1 - log.y0
            let y0 = log.y0 + scroll.offset / scroll.content * h
            let length = max(24, scroll.container / scroll.content * h)
            s.softs.append(BoardScene.Soft(rect: .init(x0: width - 5, y0: y0, x1: width - 3, y1: y0 + length), v: 0.3 * scrollGlow * chatAlpha, soft: 5, clip: log))
        }

        // Changing pages: a band of light leads the new page in.
        if let change = model.pageChange {
            let e = ease(change.progress)
            let x = change.direction > 0 ? width * (1.15 - 1.3 * e) : width * (-0.15 + 1.3 * e)
            s.sweep = BoardScene.Sweep(x: x, dir: change.direction, amp: 0.36 * sin(.pi * change.progress))
        }
        if let drop = registry.drop { s.drop = (Double(drop.x), Double(drop.y)) }

        // The strip: its own shapes of the motions once it is about its size, moments from its key,
        // the cursor after its text; a failure spreads red from the key over 0.7 s, and draws back
        // faster once the reader acts.
        alertSpread = clamp01(alertSpread + (folded && lightNow == .error ? step / 0.7 : -step / 0.35))
        if folded {
            s.strip = height < 2 * Double(PanelStrip.height)
            if let key = registry.anchors[PanelStrip.keyAnchor] { s.source = (key.midX, key.midY) }
            if let text = registry.anchors[PanelStrip.textAnchor] { s.caret = (text.maxX + PanelStrip.caretOffset, text.midY) }
            s.alert = smooth(0, 1, alertSpread)
        }
        // Everything above is in the panel's points; the board's rows start `cellShift` above.
        let shift = cellShift
        s.shift(dx: shift.x, dy: shift.y)
        boardView?.shift = CGPoint(x: shift.x, y: shift.y)
        rim(&s, dt: step, shift: shift)
        return s
    }

    /// The edge under the pointer lights its outer row of cells, brighter while dragged; a corner
    /// is brightest at the corner and fades along both of its sides. Each cell eases to its own
    /// light, so moving from an edge onto a corner or off the panel fades instead of jumping; the
    /// cells are kept by side and place along it, so a dragged edge's light moves with the edge.
    /// The light only adds to what the board shows there.
    private func rim(_ s: inout BoardScene, dt: Double, shift: (x: Double, y: Double)) {
        let P = board.look.pitch
        // The whole cells inside the panel, in board coordinates.
        let c0 = Int((shift.x / P).rounded()), c1 = Int(((shift.x + width) / P).rounded()) - 1
        let r0 = Int((shift.y / P).rounded()), r1 = Int(((shift.y + height) / P).rounded()) - 1
        guard c1 > c0, r1 > r0 else {
            rimCells = [:]
            rimEasing = false
            return
        }
        let cols = c1 - c0 + 1, rows = r1 - r0 + 1
        let sides = sizing?.sides ?? edges.lit
        let level = sizing != nil ? 0.42 : 0.3
        let corner = !sides.isDisjoint(with: [.top, .bottom]) && !sides.isDisjoint(with: .across)
        // Along a side of `n` cells: even for an edge; from the corner's end fading out for a corner.
        func fade(_ i: Int, _ n: Int, fromStart: Bool) -> Double {
            guard corner else { return 1 }
            let d = Double(fromStart ? i : n - 1 - i) / Double(max(1, n - 1))
            return pow(1 - d, 1.6)
        }
        // Each side's cells counted from its top or left end.
        let order: [(side: PanelEdges.Sides, n: Int)] = [(.top, 0), (.bottom, 1), (.left, 2), (.right, 3)]
        var goals: [Int: Double] = [:]
        for (side, n) in order where sides.contains(side) {
            let across = side == .top || side == .bottom
            let length = across ? cols : rows
            let fromStart = across ? sides.contains(.left) : sides.contains(.top)
            for i in 0..<length { goals[n * Self.rimSide + i] = level * fade(i, length, fromStart: fromStart) }
        }
        let k = 1 - exp(-dt / 0.08)
        rimEasing = false
        for key in Set(rimCells.keys).union(goals.keys) {
            let goal = goals[key] ?? 0
            var v = rimCells[key] ?? 0
            v += (goal - v) * k
            if abs(v - goal) < 0.003 { v = goal } else { rimEasing = true }
            rimCells[key] = v > 0.004 ? v : nil
        }
        for (key, v) in rimCells {
            let i = key % Self.rimSide
            let (c, r) = switch key / Self.rimSide {
            case 0: (c0 + i, r0)
            case 1: (c0 + i, r1)
            case 2: (c0, r0 + i)
            default: (c1, r0 + i)
            }
            // A side that has grown shorter since.
            guard c <= c1, r <= r1 else { continue }
            let rect = BoardScene.Rect(x0: Double(c) * P, y0: Double(r) * P, x1: Double(c + 1) * P, y1: Double(r + 1) * P)
            s.plates.append(BoardScene.Plate(rect: rect, clip: nil, rose: false, value: v, snap: true, adds: true))
        }
    }

    /// Room for each side's cells in `rimCells`' keys.
    private static let rimSide = 100_000

    /// The light a control should have: keys glow when hovered or down, the send key's halo is on
    /// while there is something to send, choices glow under the pointer, the edge while dragged.
    private func lightTarget(_ control: LightRegistry.Control) -> Double {
        switch control.kind {
        case .key: control.pressed ? 0.3 : control.hot ? 0.2 : 0
        case .send: model.sendLit ? (control.hot ? 0.42 : 0.3) : (control.hot ? 0.12 : 0)
        case .segment: control.hot && !control.pressed ? 0.08 : 0
        case .cells: control.pressed ? 0.5 : control.hot ? 0.36 : 0.14
        }
    }

    /// The board turns rose when a request fails, and pinker the faster an answer arrives.
    private func warmth() -> Double {
        switch lightNow {
        case .error: light.error == nil || folded ? 0 : LightLanguage.errorWarmth
        case .writing: LightLanguage.speedWarmth(shownSpeed)
        default: 0
        }
    }

    private func pageAlpha(_ page: PanelModel.Page) -> Double {
        guard let change = model.pageChange else { return model.page == page ? 1 : 0 }
        let e = ease(change.progress)
        return page == change.to ? e : page == change.from ? 1 - e : 0
    }

    private func ease(_ p: Double) -> Double { p * p * (3 - 2 * p) }

    // MARK: - Events

    private func installMonitors() {
        // Any click in the panel lets an error's light go.
        monitors.append(NSEvent.addLocalMonitorForEvents(matching: .leftMouseDown) { [weak self] event in
            if let self, event.window === self.panel { self.model.settleFailure() }
            return event
        } as Any)
        // A new input source shows its badge at the caret.
        inputSourceObserver = NotificationCenter.default.addObserver(
            forName: NSTextInputContext.keyboardSelectionDidChangeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.panel.isKeyWindow else { return }
                self.panel.followInputMethod()
            }
        }
    }
}

