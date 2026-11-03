import AppKit
import NibbleCore
import SwiftUI

/// The main window: home (how Nibble was used), history (every saved conversation) and settings,
/// on a light board of its own that fills the window.
///
/// It is an ordinary window: it activates Nibble, has the system's window buttons, can be resized
/// and goes into the Window menu. Its board plays its background motion (a setting), sweeps a band
/// of light across when the page changes, and lights the controls and plates the views report; it
/// draws nothing while the window is covered and stops when the window closes.
@MainActor
public final class MainWindowController: NSObject, NSWindowDelegate {
    static let defaultSize = CGSize(width: 920, height: 620)
    static let minSize = CGSize(width: 760, height: 520)
    private static let pageSeconds = 0.48
    private static let openSeconds = 0.6

    let model: MainModel
    let board: Board
    private let app: AppModel
    private var window: NSWindow?
    private var boardView: BoardView?
    private var lastFrame = 0.0
    private var opened = 0.0
    private var size = CGSize.zero

    init(app: AppModel) {
        self.app = app
        model = MainModel(app: app)
        board = Board(width: Self.defaultSize.width, maxHeight: Self.defaultSize.height)
        board.still = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        super.init()
    }

    public var isVisible: Bool { window?.isVisible ?? false }

    /// Shows the window on `page` and brings Nibble to the front.
    public func show(_ page: MainPage? = nil) {
        let window = self.window ?? makeWindow()
        if let page { model.go(to: page) }
        app.reloadHistory()
        if !window.isVisible {
            opened = 0
            boardView?.needsRedraw = true
        }
        boardView?.running = true
        NSApp.activate()
        window.makeKeyAndOrderFront(nil)
    }

    public func close() {
        window?.performClose(nil)
    }

    private func makeWindow() -> NSWindow {
        let window = MainWindow(
            contentRect: NSRect(origin: .zero, size: Self.defaultSize),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.title = "Nibble"
        window.isReleasedWhenClosed = false
        window.contentMinSize = Self.minSize
        window.isMovableByWindowBackground = true
        window.delegate = self
        window.setFrameAutosaveName("Nibble.main")
        if !window.setFrameUsingName("Nibble.main") { window.center() }

        let container = NSView(frame: NSRect(origin: .zero, size: Self.defaultSize))
        container.wantsLayer = true
        if let boardView = BoardView(board: board) {
            boardView.frame = container.bounds
            boardView.autoresizingMask = [.width, .height]
            boardView.onFrame = { [weak self] in self?.frame() }
            container.addSubview(boardView)
            self.boardView = boardView
        }
        let root = MainRootView()
            .environment(model)
            .environment(app)
            .environment(\.lightRegistry, model.registry)
            .environment(\.board, board)
        let hosting = NSHostingView(rootView: root)
        hosting.sizingOptions = []
        // The content runs under the transparent title bar, so its coordinates are the board's.
        hosting.safeAreaRegions = []
        hosting.frame = container.bounds
        hosting.autoresizingMask = [.width, .height]
        container.addSubview(hosting)
        window.contentView = container
        self.window = window
        applyColours()
        return window
    }

    // MARK: - Window

    public func windowWillClose(_ notification: Notification) {
        boardView?.running = false
        app.recordingHotKey = false
        lastFrame = 0
    }

    public func windowDidChangeOcclusionState(_ notification: Notification) {
        boardView?.needsRedraw = true
    }

    // MARK: - A frame

    private func frame() -> BoardScene? {
        guard let window else { return nil }
        // Covered, on another Space or minimised: draw nothing, and look again a few times a
        // second. The loop itself keeps running, so the board comes back the moment the window
        // is seen, whatever order the system reports things in.
        guard window.occlusionState.contains(.visible) else {
            boardView?.framesPerSecond = 4
            boardView?.needsRedraw = true
            lastFrame = 0
            return nil
        }
        let now = ProcessInfo.processInfo.systemUptime
        let dt = lastFrame > 0 ? min(0.05, now - lastFrame) : 1.0 / 60
        lastFrame = now
        let bounds = window.contentView?.bounds.size ?? Self.defaultSize
        if bounds != size {
            size = bounds
            board.setSize(width: bounds.width, maxHeight: bounds.height)
            boardView?.needsRedraw = true
        }
        if board.palette != app.palette { applyColours() }
        opened = board.still ? 1 : min(1, opened + dt / Self.openSeconds)
        let rest = app.settings.background
        board.setMotion(rest.motion, gain: rest.windowGain)

        var scene = BoardScene(width: bounds.width, height: bounds.height)
        scene.open = opened
        let progress = updatePage()
        model.registry.light(&scene, dt: dt, alpha: { _ in 1 }, target: lightTarget)
        // Changing pages: a band of light sweeps across, as between the panel's pages.
        if model.pageChange != nil {
            let e = progress * progress * (3 - 2 * progress)
            scene.sweep = BoardScene.Sweep(x: bounds.width * (-0.15 + 1.3 * e), dir: 1, amp: 0.3 * sin(.pi * progress))
        }
        // Slow light needs 30 frames a second while the window is in front, 15 behind other windows.
        let busy = board.wantsFullRate || opened < 1 || model.pageChange != nil || model.registry.isEasing(lightTarget)
        boardView?.framesPerSecond = busy ? 60 : window.isKeyWindow ? 30 : 15
        return scene
    }

    private func updatePage() -> Double {
        guard var change = model.pageChange else { return 1 }
        change.progress = board.still ? 1 : min(1, Date().timeIntervalSince(change.start) / Self.pageSeconds)
        model.pageChange = change.progress >= 1 ? nil : change
        return change.progress
    }

    /// Keys glow when hovered or down; rows and choices glow softly under the pointer.
    private func lightTarget(_ control: LightRegistry.Control) -> Double {
        switch control.kind {
        case .key: control.pressed ? 0.3 : control.hot ? 0.2 : 0
        case .send: control.hot ? 0.3 : 0.12
        case .segment: control.hot && !control.pressed ? 0.08 : 0
        case .cells: control.pressed ? 0.5 : control.hot ? 0.36 : 0.14
        }
    }

    private func applyColours() {
        board.setPalette(app.palette)
        let ground = board.groundFill
        window?.backgroundColor = NSColor(srgbRed: CGFloat(ground.x) / 255, green: CGFloat(ground.y) / 255, blue: CGFloat(ground.z) / 255, alpha: 1)
        window?.appearance = NSAppearance(named: app.appearance == .dark ? .darkAqua : .aqua)
    }

    // MARK: - For the self-test

    var page: MainPage { model.page }
    var windowFrame: NSRect { window?.frame ?? .zero }

    /// Puts the window in front of every other app's, even when Nibble could not be activated
    /// (the self-test runs while the reader works in other windows).
    func bringToFront() { window?.orderFrontRegardless() }

    /// Whether a click at `point` (points from the content's top left) lands on selectable text,
    /// which then takes the mouse instead of the window moving (for the self-test).
    func isSelectableText(at point: CGPoint) -> Bool {
        guard let frame = window?.contentView?.superview, let content = window?.contentView else { return false }
        let p = content.convert(NSPoint(x: point.x, y: content.bounds.height - point.y), to: frame)
        return frame.hitTest(p)?.isSelectableText ?? false
    }
    var windowNumber: Int { window?.windowNumber ?? 0 }
}

/// The main window's state as its views see it.
@MainActor
@Observable
final class MainModel {
    struct PageChange {
        var start: Date
        var progress = 0.0
    }

    let app: AppModel
    @ObservationIgnored let registry = LightRegistry()
    var page: MainPage = .home
    var pageChange: PageChange?
    /// The conversation open in history.
    var selected: Conversation.ID?
    var search = ""
    /// What the home page's chart counts.
    var chartTokens = false
    /// The source menu is open above the sidebar's foot.
    var sourceOpen = false
    /// Where the sidebar's source key is, for placing its menu.
    var sourceAnchor: CGRect = .zero

    init(app: AppModel) {
        self.app = app
    }

    /// Deletes a saved conversation; if it was the one open, the next one in `list` opens (or the
    /// one before, at the end).
    func delete(_ conversation: Conversation, in list: [Conversation]) {
        selected = Self.selection(afterDeleting: conversation.id, in: list.map(\.id), selected: selected)
        app.delete(conversation)
    }

    /// Which conversation is picked after `id` is deleted from `list`. Nothing picked means the
    /// first is open. The open one gives way to the next (or the one before, at the end); any
    /// other choice stays.
    static func selection(afterDeleting id: Conversation.ID, in list: [Conversation.ID], selected: Conversation.ID?) -> Conversation.ID? {
        guard let index = list.firstIndex(of: id), selected == nil ? index == 0 : selected == id else { return selected }
        return list.indices.contains(index + 1) ? list[index + 1] : (index > 0 ? list[index - 1] : nil)
    }

    func go(to next: MainPage) {
        sourceOpen = false
        guard next != page else { return }
        page = next
        pageChange = PageChange(start: Date())
    }
}
