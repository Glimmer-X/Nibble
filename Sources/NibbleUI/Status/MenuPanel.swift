import AppKit
import NibbleCore
import SwiftUI

/// The panel the menu bar item opens, in Nibble's own look: a small light board under the item
/// with who answers (a menu to change the service and persona), the day's figures and the week as
/// a dot chart, the latest three conversations, and four keys on plates of lit cells: new chat,
/// the quick chat, the main window, and quitting on warning cells. It blooms open from the middle
/// like the panel and closes when the reader clicks elsewhere, presses Esc, or clicks the item
/// again. While a newer version waits, its notice sits under the header and the panel is that
/// much taller, growing and shrinking downward from the menu bar.
@MainActor
final class MenuPanelController {
    static let width = 340.0
    static let height = 460.0
    /// What the notice of a newer version adds to the height.
    static var noticeRoom: Double { Double(UpdateNotice.height) + 10 }
    private static let openSeconds = 0.32
    private static let closeSeconds = 0.16

    let registry = LightRegistry()
    let board: Board
    private let app: AppModel
    private let panel: FloatingPanel
    private var boardView: BoardView?
    /// The panel's height now.
    private var height = MenuPanelController.height
    private var openness = 0.0
    /// +1 while opening, −1 while closing.
    private var opening = 0
    private var lastFrame = 0.0

    init(app: AppModel, actions: MenuActions) {
        self.app = app
        let size = CGSize(width: Self.width, height: Self.height)
        // Rows for the notice too, so the board never reallocates.
        board = Board(width: Self.width, maxHeight: Self.height + 64)
        board.still = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        panel = FloatingPanel(contentRect: NSRect(origin: .zero, size: size))
        panel.level = .popUpMenu
        panel.isMovableByWindowBackground = false
        panel.isOpaque = true

        let container = NSView(frame: NSRect(origin: .zero, size: size))
        container.wantsLayer = true
        if let boardView = BoardView(board: board) {
            boardView.frame = container.bounds
            boardView.autoresizingMask = [.width, .height]
            boardView.onFrame = { [weak self] in self?.frame() }
            container.addSubview(boardView)
            self.boardView = boardView
        }
        var actions = actions
        actions.done = { [weak self] in self?.close() ?? () }
        let root = MenuRootView(actions: actions)
            .environment(app)
            .environment(\.lightRegistry, registry)
            .environment(\.board, board)
        let hosting = NSHostingView(rootView: root)
        hosting.sizingOptions = []
        hosting.frame = container.bounds
        hosting.autoresizingMask = [.width, .height]
        container.addSubview(hosting)
        panel.contentView = container
        panel.onResignKey = { [weak self] in self?.close() }
        panel.onCancel = { [weak self] in self?.close() }
    }

    var isOpen: Bool { panel.isVisible && opening >= 0 }

    /// Opens under the menu bar item (its rectangle on screen), or closes if open.
    func toggle(under item: NSRect) {
        if isOpen { close() } else { open(under: item) }
    }

    private func open(under rect: NSRect) {
        app.reloadHistory()
        app.refreshBackendState()
        // Until the menu bar has placed the item, its rectangle is somewhere else (at the screen's
        // bottom left): then open under the menu bar's right end of the main screen.
        var item = rect
        var screen = NSScreen.screens.first { $0.frame.contains(NSPoint(x: item.midX, y: item.midY)) }
        if let found = screen, item.width >= 1, item.minY >= found.visibleFrame.maxY - 4 {
            screen = found
        } else {
            screen = NSScreen.main
            let top = screen?.visibleFrame ?? .zero
            item = NSRect(x: top.maxX - 160, y: top.maxY, width: 24, height: 0)
        }
        let area = screen?.visibleFrame ?? .zero
        let x = min(max(item.midX - Self.width / 2, area.minX + 8), area.maxX - Self.width - 8)
        height = wantedHeight
        panel.setFrame(NSRect(x: x.rounded(), y: (item.minY - 6 - height).rounded(), width: Self.width, height: height), display: false)
        applyColours()
        openness = board.still ? 1 : 0
        opening = 1
        panel.alphaValue = board.still ? 1 : 0
        boardView?.needsRedraw = true
        boardView?.running = true
        panel.orderFrontRegardless()
        panel.makeKey()
    }

    func close() {
        guard panel.isVisible, opening >= 0 else { return }
        opening = -1
    }

    // MARK: - A frame

    private func frame() -> BoardScene? {
        let now = ProcessInfo.processInfo.systemUptime
        let dt = lastFrame > 0 ? min(0.05, now - lastFrame) : 1.0 / 60
        lastFrame = now
        if opening != 0 {
            openness = min(1, max(0, openness + Double(opening) * dt / (opening > 0 ? Self.openSeconds : Self.closeSeconds)))
            if board.still { openness = opening > 0 ? 1 : 0 }
            if opening > 0, openness >= 1 { opening = 0 }
            if opening < 0, openness <= 0 {
                opening = 0
                panel.orderOut(nil)
                boardView?.running = false
                lastFrame = 0
                return nil
            }
            panel.alphaValue = CGFloat(min(1, openness * 1.6))
        }
        if board.palette != app.palette { applyColours() }
        if wantedHeight != height { resize() }
        let rest = app.settings.background
        board.setMotion(rest.motion, gain: rest.windowGain)
        var scene = BoardScene(width: Self.width, height: height)
        scene.open = openness
        registry.light(&scene, dt: dt, alpha: { _ in 1 }, target: { control in
            switch control.kind {
            case .key: control.pressed ? 0.3 : control.hot ? 0.2 : 0
            case .segment: control.hot && !control.pressed ? 0.1 : 0
            case .cells: control.pressed ? 0.5 : control.hot ? 0.36 : 0.14
            case .send: control.hot ? 0.2 : 0
            }
        })
        boardView?.framesPerSecond = board.wantsFullRate || opening != 0 ? 60 : 30
        return scene
    }

    /// Taller by the notice's room while a newer version waits.
    private var wantedHeight: Double {
        Self.height + (app.updates.notice != nil ? Self.noticeRoom : 0)
    }

    /// Takes the wanted height, keeping the top under the menu bar.
    private func resize() {
        height = wantedHeight
        let top = panel.frame.maxY
        panel.setFrame(NSRect(x: panel.frame.minX, y: top - height, width: Self.width, height: height), display: true)
        boardView?.needsRedraw = true
    }

    private func applyColours() {
        board.setPalette(app.palette)
        let ground = board.groundFill
        panel.backgroundColor = NSColor(srgbRed: CGFloat(ground.x) / 255, green: CGFloat(ground.y) / 255, blue: CGFloat(ground.z) / 255, alpha: 1)
        panel.appearance = NSAppearance(named: app.appearance == .dark ? .darkAqua : .aqua)
    }
}

/// What the menu panel's keys do. `done` closes the panel; each action calls it first.
struct MenuActions {
    var newChat: () -> Void
    var showPanel: () -> Void
    /// The main window, on the page it was last on.
    var openMain: () -> Void
    var openPage: (MainPage) -> Void
    var open: (Conversation) -> Void
    var quit: () -> Void
    var done: () -> Void = {}
}

/// The menu panel's content.
private struct MenuRootView: View {
    @Environment(AppModel.self) private var app
    let actions: MenuActions
    @State private var sourceOpen = false

    var body: some View {
        let s = app.strings
        let colors = app.colors
        let report = UsageReport(app.history, dayCount: 7)
        ZStack(alignment: .topTrailing) {
            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: 10) {
                    NibbleMark().foregroundStyle(colors.accent)
                    Text("Nibble").pixelText()
                    Spacer(minLength: 8)
                    SourceKey(open: sourceOpen) { sourceOpen.toggle() }
                        .padding(.trailing, -8)
                }
                .frame(height: 36)

                if let release = app.updates.notice {
                    UpdateNotice(release: release, id: "menu-update", place: .main)
                        .padding(.top, 10)
                        .padding(.horizontal, -8)
                }

                HStack(alignment: .bottom, spacing: 16) {
                    VStack(alignment: .leading, spacing: 12) {
                        Figure(label: s.askedToday, value: DotFace.compact(report.today.questions))
                        Figure(label: s.tokensWeek, value: DotFace.compact(report.week.tokens))
                    }
                    Spacer(minLength: 0)
                    VStack(alignment: .trailing, spacing: 8) {
                        Text(s.lastWeek).pixelText().foregroundStyle(colors.ink2)
                        DotBars(values: report.days.map { Double($0.questions) }, marked: [report.days.count - 1],
                                rows: 12, barWidth: 4, gap: 2, pitch: 3, dot: 2, colors: colors)
                    }
                }
                .padding(.top, 14)

                HStack {
                    Text(s.recentChats).pixelText().foregroundStyle(colors.ink2)
                    Spacer(minLength: 8)
                    if app.history.count > 3 {
                        TextKey(id: "menu-more", title: s.more, place: .main) {
                            actions.done()
                            actions.openPage(.history)
                        }
                        .padding(.trailing, -8)
                    }
                }
                .frame(height: Typeface.keyHeight)
                .padding(.top, 18)
                .padding(.bottom, 2)
                if app.historyLoaded, app.history.isEmpty {
                    Text(s.noChats).pixelText().foregroundStyle(colors.ink3).frame(height: 32)
                }
                ForEach(app.history.prefix(3)) { conversation in
                    ConversationRow(conversation: conversation, place: .main, compact: true) {
                        actions.done()
                        actions.open(conversation)
                    }
                    .padding(.horizontal, -12)
                }

                Spacer(minLength: 20)

                // Keys 140 × 40 pt with 20 pt between: each lights 14 × 4 whole cells, with two dark
                // cells between keys either way.
                Grid(horizontalSpacing: 20, verticalSpacing: 20) {
                    GridRow {
                        Tile(id: "menu-new", icon: .plus, title: s.newChat, done: actions.done) { actions.newChat() }
                        Tile(id: "menu-panel", icon: .bubble, title: s.quickChatTile,
                             hint: HotKeyName.describe(app.settings.hotKey).replacingOccurrences(of: " ", with: ""),
                             done: actions.done) { actions.showPanel() }
                    }
                    GridRow {
                        Tile(id: "menu-main", icon: .window, title: s.openNibble, done: actions.done) { actions.openMain() }
                        Tile(id: "menu-quit", icon: .power, title: s.quit, warning: true, done: actions.done) { actions.quit() }
                    }
                }
            }
            .padding(.horizontal, 20)
            .padding(.top, 12)
            .padding(.bottom, 20)
            .frame(width: MenuPanelController.width, alignment: .topLeading)
            .frame(maxHeight: .infinity, alignment: .topLeading)

            if sourceOpen {
                Color.clear.contentShape(Rectangle()).onTapGesture { sourceOpen = false }
                SourceMenu(done: { sourceOpen = false }) {
                    actions.done()
                    actions.openPage(.settings)
                }
                .padding(.top, 46)
                .padding(.trailing, 12)
            }
        }
        .frame(width: MenuPanelController.width, alignment: .topLeading)
        .frame(maxHeight: .infinity, alignment: .topLeading)
        .coordinateSpace(.named(BoardSpace.name))
        .foregroundStyle(colors.ink)
        .overlay { Rectangle().strokeBorder(colors.rim, lineWidth: 1).allowsHitTesting(false) }
        .environment(\.colorScheme, app.appearance == .dark ? .dark : .light)
    }
}

/// Who answers, at the top right: a lamp for the connection, the service and persona, and a
/// chevron; it opens the source menu.
private struct SourceKey: View {
    @Environment(AppModel.self) private var app
    let open: Bool
    let action: () -> Void

    var body: some View {
        let colors = app.colors
        Button(action: action) {
            HStack(spacing: 8) {
                Rectangle()
                    .fill(app.connection == .connected ? colors.accent : colors.rose.opacity(app.connection == nil ? 0 : 1))
                    .frame(width: 6, height: 6)
                Text(app.personaLabel).pixelText().lineLimit(1).truncationMode(.middle)
                DotIconView(icon: .chevron).foregroundStyle(colors.ink2)
            }
            .padding(.horizontal, 8)
            .frame(height: Typeface.keyHeight + 4)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(colors.ink2)
        .frame(maxWidth: 220, alignment: .trailing)
        .boardLight("menu-source", .segment, in: .main, pressed: open)
    }
}

/// A figure: a pixel label over a small dot-display number.
private struct Figure: View {
    @Environment(AppModel.self) private var app
    let label: String
    let value: String

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(label).pixelText().foregroundStyle(app.colors.ink2)
            DotFigure(text: value, pitch: 3, dot: 2)
        }
    }
}

/// One of the panel's four keys: an icon and a name (and the shortcut, for the quick chat, when it
/// fits) on a plate of whole lit cells (the same number wherever the key falls on the grid) that
/// brightens under the pointer; quitting is on warning cells.
private struct Tile: View {
    @Environment(AppModel.self) private var app
    let id: String
    let icon: DotIcon
    let title: String
    var hint: String?
    var warning = false
    /// Closes the panel before the action.
    let done: () -> Void
    let action: () -> Void
    @State private var hot = false

    var body: some View {
        let colors = app.colors
        Button {
            done()
            action()
        } label: {
            HStack(spacing: 10) {
                DotIconView(icon: icon)
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 4) {
                        Text(title).pixelText().lineLimit(1)
                        Spacer(minLength: 4)
                        if let hint { Text(hint).pixelText().foregroundStyle(colors.ink3).lineLimit(1) }
                    }
                    Text(title).pixelText().lineLimit(1).frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .padding(.horizontal, 12)
            .frame(maxWidth: .infinity)
            .frame(height: 40)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(warning ? colors.rose : (hot ? colors.ink : colors.ink.opacity(0.85)))
        .onHover { hot = $0 }
        .boardLamp(id, value: hot ? 0.24 : 0.13, rose: warning, clip: nil)
    }
}
