import AppKit
import NibbleCore

/// Drives the real panel and main window on screen and writes what it saw as JSON: only what code
/// alone cannot see (window heights and places, what a press lands on, the light through a reply,
/// folding, closing, clicking away). Logic is checked by the unit tests instead. Run with
/// `-NibbleSelfTest <file>`, `-NibbleScript sample` and, to run only some of it,
/// `-NibbleSelfTestParts panel,edges` (see scripts/check.sh). Development only.
///
/// Parts, each on its own: `panel` (the bar, typing, a reply, an error, new chat, closing, the
/// conversation's page), `edges` (resizing and where the panel opens), `strip` (folding the chat
/// into its strip and back), `main` (history and settings in the main window), `menu` (the menu
/// bar panel).
@MainActor
struct PanelSelfTest {
    enum Part: String, CaseIterable {
        case panel, edges, strip, main, menu
    }

    let interface: Interface
    /// A backend whose replies fail, for the error check.
    let failing: any ChatBackend
    let parts: [Part]
    private var results: [[String: Any]] = []

    init(interface: Interface, failing: any ChatBackend, parts: [Part]) {
        self.interface = interface
        self.failing = failing
        self.parts = parts
    }

    private var controller: PanelController { interface.panel }
    private var main: MainWindowController { interface.main }

    private var model: PanelModel { controller.model }
    private var board: Board { controller.board }

    mutating func run() async -> [[String: Any]] {
        model.session.startNewConversation()
        controller.forgetPlace()
        // The reader may be using the Mac meanwhile: clicking elsewhere must not put the panel
        // away mid-test (only the check that clicks away on purpose lets it go).
        let held = controller.holdsOpen
        controller.holdsOpen = true
        defer { controller.holdsOpen = held }
        for part in parts {
            switch part {
            case .panel: await panel()
            case .edges: await edges()
            case .strip: await strip()
            case .main: await mainWindow()
            case .menu: await menu()
            }
        }
        controller.forgetPlace()
        return results
    }

    // MARK: - The panel

    private mutating func panel() async {
        let normal = model.session.backend
        controller.summon()
        await wait(0.8)
        let bar = controller.windowHeight
        check("the bar is whole cells tall", bar.truncatingRemainder(dividingBy: board.look.pitch) == 0 && bar <= 80, "\(bar)")

        // A long draft grows the field; clearing it, however it happens, brings the bar back.
        if let field = controller.composerTextView {
            let long = String(repeating: "这是一段很长的话，", count: 40)
            var trail: [String] = []
            let panel = model
            let clears: [(String, () -> Void)] = [
                ("delete", { field.selectAll(nil); field.deleteBackward(nil) }),
                ("draft", { panel.session.draft = "" }),
                ("new chat", { panel.newChat() }),
            ]
            for (name, clear) in clears {
                field.window?.makeFirstResponder(field)
                field.insertText(long, replacementRange: field.selectedRange())
                await wait(0.6)
                let grown = controller.windowHeight
                clear()
                await waitUntil(2) { controller.windowHeight == bar }
                trail.append("\(name): \(Int(grown))→\(Int(controller.windowHeight))")
            }
            check("a cleared long draft brings the bar back", !trail.contains { !$0.hasSuffix("→\(Int(bar))") }, trail.joined(separator: ", "))
        }

        // The empty field moves the panel; typing lights the board, each key an input method
        // composes included; typed text selects and the rest of the field still moves the panel.
        if let field = controller.composerTextView {
            let emptyMoves = !field.isOverText(NSPoint(x: field.bounds.midX, y: field.bounds.midY))
                && controller.pressTarget(at: CGPoint(x: 14, y: bar / 2)) == .drag
            field.window?.makeFirstResponder(field)
            let before = board.typingMarks
            for pinyin in ["n", "ni", "nih", "niha", "nihao"] {
                field.setMarkedText(pinyin, selectedRange: NSRange(location: pinyin.utf16.count, length: 0), replacementRange: NSRange(location: NSNotFound, length: 0))
            }
            let composing = board.typingMarks - before
            field.insertText("你好", replacementRange: NSRange(location: NSNotFound, length: 0))
            let textSelects = field.isOverText(NSPoint(x: field.textContainerOrigin.x + 6, y: field.bounds.midY))
                && !field.isOverText(NSPoint(x: field.bounds.maxX - 10, y: field.bounds.midY))
            check("the field: empty moves the panel, typing lights the board, text selects",
                  emptyMoves && composing == 5 && model.session.draft == "你好" && textSelects,
                  "moves \(emptyMoves), \(composing) marks, draft \(model.session.draft), selects \(textSelects)")
        }

        // Clicking away from a panel with text keeps it open.
        controller.simulateFocusLost()
        await wait(0.4)
        let keptOpen = controller.isVisible && !model.closing

        // A reply: the chat unfolds, the light follows the reply's states, done blooms, the
        // conversation follows the answer to its end.
        controller.clearTrail()
        model.send()
        await wait(1.0)
        let chat = controller.windowHeight
        let unfolded = chat == model.settings.panelHeight
        await waitUntil(20) { !model.session.isResponding }
        await wait(0.3)
        let trail = controller.lightTrail.map(\.rawValue)
        let scroll = model.registry.scroll
        check("a reply unfolds the chat, plays its lights, ends on the tick, followed to its end",
              unfolded && controller.momentTrail.contains(.rise) && Self.contains(trail, ["waiting", "think", "search", "read", "writing", "idle"])
                  && controller.momentTrail.contains(.bloom) && model.keyDisplay == .done && model.session.lastReply?.status == .complete
                  && scroll.offset + scroll.container >= scroll.content - 30,
              "\(Int(chat)) pt; \(trail.joined(separator: " → ")); scroll \(Int(scroll.offset + scroll.container))/\(Int(scroll.content))")
        presses(chat: chat)

        // An error stalls and warms the board; the next key lets it go.
        model.session.backend = failing
        model.session.draft = "再来"
        model.send()
        await waitUntil(10) { !model.session.isResponding }
        await wait(1.0)
        let stalled = board.isStalled && board.clockRate < 0.2 && board.warm > 0.2 && model.keyDisplay == .error
        type("x")
        await wait(1.2)
        check("an error stalls the board, the next key lets it go", stalled && !board.isStalled && board.clockRate > 0.8, "rate \(board.clockRate)")
        model.session.draft = ""
        model.session.backend = normal

        // New chat folds into the bar and empties it; an empty panel closes on a click away.
        model.newChat()
        // The fold runs on frame time, which lags when the machine is busy.
        await waitUntil(3) { model.view == .bar && controller.windowHeight == bar }
        let folded = model.view == .bar && controller.windowHeight == bar && model.session.conversation.isEmpty
        controller.simulateFocusLost()
        await wait(0.8)
        check("new chat folds into the bar; a click away closes only an empty panel", keptOpen && folded && !controller.isVisible)

        // Closing a chat folds it into the bar, then fades out; summoning continues it.
        controller.summon()
        model.session.draft = "第二个问题"
        model.send()
        await waitUntil(20) { !model.session.isResponding }
        controller.dismiss()
        await wait(0.15)
        let folding = controller.windowHeight
        await wait(1.0)
        let hidden = !controller.isVisible
        controller.summon()
        await wait(1.0)
        check("closing folds then hides; summoning continues the chat", folding < chat && hidden && model.view == .chat && controller.windowHeight == chat,
              "\(folding) → \(controller.windowHeight)")

        // The menu key opens the conversation's page, which opens a recent chat in the panel.
        model.toggleSheet()
        await wait(0.8)
        let sheet = model.page == .sheet && model.pageChange == nil
        if let older = model.app.history.first(where: { $0.id != model.session.conversation.id }) {
            model.open(older)
            await wait(0.8)
            check("the conversation's page opens a recent chat in the panel", sheet && model.session.conversation.id == older.id && model.page == .chat)
        } else {
            check("the conversation's page opens a recent chat in the panel", false, "no recent chat")
        }
        controller.dismiss()
        await wait(1.0)
    }

    // MARK: - Edges and places

    private mutating func edges() async {
        await openChat()
        let chat = controller.windowHeight
        let screen = NSScreen.screens.first { $0.frame.contains(NSPoint(x: controller.windowFrame.midX, y: controller.windowFrame.midY)) } ?? NSScreen.main
        let area = screen?.visibleFrame ?? .zero

        // Edges and corners follow the pointer exactly, the opposite sides staying put, and settle
        // on whole cells when let go.
        let width = model.settings.panelWidth
        let height = model.settings.panelHeight
        controller.move(to: NSPoint(x: (area.midX - width / 2).rounded(), y: (area.midY - height / 2).rounded()))
        await wait(0.3)
        await resize(.top, by: CGSize(width: 0, height: 37), live: CGSize(width: 0, height: 37), settled: CGSize(width: 0, height: 40), name: "the top edge")
        await resize([.bottom, .left], by: CGSize(width: -23, height: -31), live: CGSize(width: 23, height: 31), settled: CGSize(width: 20, height: 30), name: "a corner")
        model.settings.panelWidth = width
        model.settings.panelHeight = height
        await wait(0.4)

        // The panel opens where it was left; a bar left low reopens low with the chat above it.
        controller.move(to: NSPoint(x: area.minX + 137, y: area.minY + 77))
        await wait(0.3)
        let left = controller.windowFrame.minX
        let bottom = controller.windowFrame.minY
        controller.dismiss()
        await wait(1.0)
        controller.summon()
        await wait(1.0)
        let reopened = abs(controller.windowFrame.minX - left) < 1 && abs(controller.windowFrame.minY - bottom) < 1
        let low = area.minY + 30
        controller.move(to: NSPoint(x: left, y: low))
        await wait(0.4)
        controller.dismiss()
        await wait(1.0)
        controller.summon()
        await wait(1.0)
        check("the panel opens where it was left, a low bar with the chat above",
              reopened && abs(controller.windowFrame.minY - low) < 1 && controller.windowHeight == chat,
              "\(controller.windowFrame.minX),\(controller.windowFrame.minY) vs \(left),\(low)")
        controller.dismiss()
        await wait(1.0)
    }

    // MARK: - The strip

    /// The chat folds into its strip at its top right corner and back: the corner stays put, the
    /// keyboard goes to the app underneath and comes back, the strip moves and the chat unfolds
    /// where it was moved, and closing the strip opens the chat there next time.
    private mutating func strip() async {
        await openChat()
        await wait(0.3)
        let chat = controller.windowFrame
        // ⌘M, as the Window menu sends it.
        NSApp.sendAction(#selector(NSWindow.performMiniaturize(_:)), to: nil, from: nil)
        await waitUntil(2) { model.mininess == 1 }
        await wait(0.2)
        let strip = controller.windowFrame
        check("⌘M folds the chat into its strip at its top right corner, the keyboard to the app underneath",
              model.mini && strip.size == PanelStrip.size(model.strings) && strip.maxX == chat.maxX && strip.maxY == chat.maxY && !controller.isKey,
              "\(chat) → \(strip), key \(controller.isKey)")

        controller.move(to: NSPoint(x: strip.minX - 60, y: strip.minY - 40))
        await wait(0.2)
        model.expand()
        await waitUntil(2) { model.mininess == 0 && controller.windowFrame.size == chat.size }
        await wait(0.3)
        let back = controller.windowFrame
        check("the chat unfolds where the strip was moved, with the keyboard",
              back.size == chat.size && back.maxX == chat.maxX - 60 && back.maxY == chat.maxY - 40 && controller.isKey && !model.mini,
              "\(back), key \(controller.isKey)")

        model.collapse()
        await waitUntil(2) { model.mininess == 1 }
        controller.dismiss()
        await waitUntil(2) { !controller.isVisible }
        controller.summon()
        await waitUntil(3) { controller.windowFrame.height == chat.height }
        await wait(0.3)
        let reopened = controller.windowFrame
        check("closed from the strip, the chat opens where it was", reopened == back && !model.mini, "\(reopened)")
    }

    /// A chat with a reply in it, open in the panel.
    private func openChat() async {
        controller.summon()
        if model.session.conversation.isEmpty {
            model.session.draft = "你好"
            model.send()
            await waitUntil(20) { !model.session.isResponding }
        }
        await waitUntil(2) { controller.windowHeight == model.settings.panelHeight }
    }

    // MARK: - The main window

    private mutating func mainWindow() async {
        await seedHistory()
        main.show(.history)
        main.bringToFront()
        await wait(1.2)
        var selectable = false
        if let clip = main.model.registry.clips["transcript"] {
            let points = stride(from: clip.minY + 20, to: clip.maxY, by: 12).map { CGPoint(x: clip.minX + 40, y: $0) }
            selectable = points.contains { main.isSelectableText(at: $0) }
        }
        check("history shows the chats on a lit board, the transcript's text selectable",
              main.isVisible && main.board.rows > 0 && model.app.history.count >= 2 && selectable,
              "\(main.board.rows) rows, \(model.app.history.count) chats")

        main.model.go(to: .settings)
        await wait(0.9)
        let bars = main.model.registry.controls.filter { $0.key.hasPrefix("ruler-") }
        let frame = main.windowFrame
        let inside = bars.values.allSatisfy { $0.rect.minX > 0 && $0.rect.maxX < frame.width && $0.rect.minY > 0 && $0.rect.maxY < frame.height }
        check("settings' ruler has a bar per section, in the window", main.page == .settings && bars.count == 5 && inside,
              bars.values.map { "\(Int($0.rect.minX)),\(Int($0.rect.minY))" }.sorted().joined(separator: " "))

        if let first = model.app.history.first {
            model.app.continueInPanel(first)
            await wait(1.0)
            check("a saved chat continues in the panel", controller.isVisible && model.session.conversation.id == first.id)
            controller.dismiss()
            await wait(1.0)
        }
        main.close()
        await wait(0.6)
    }

    /// At least two saved conversations, written straight to the store.
    private func seedHistory() async {
        model.app.reloadHistory()
        await waitUntil(3) { model.app.historyLoaded }
        guard model.app.history.count < 2 else { return }
        for (question, answer) in [("第一个问题", "第一个回答。"), ("第二个问题", "第二个回答。")] {
            let conversation = Conversation(messages: [Message(role: .user, text: question), Message(role: .assistant, text: answer)])
            try? await model.app.repository.save(conversation)
        }
        model.app.reloadHistory()
        await waitUntil(3) { model.app.history.count >= 2 }
    }

    // MARK: - The menu bar panel

    private mutating func menu() async {
        interface.toggleMenu()
        await wait(0.6)
        let opened = interface.menuIsOpen
        interface.toggleMenu()
        await wait(0.5)
        check("the menu bar item opens its panel and a second click closes it", opened && !interface.menuIsOpen)
    }

    // MARK: - Presses and edges

    /// What presses land on in the chat: edges resize, empty space moves the panel, text selects,
    /// and a reply's block holds together (its gaps never move the panel).
    private mutating func presses(chat: Double) {
        let frame = controller.windowFrame
        let w = Double(frame.width)
        let middle = chat / 2
        let edges = [CGPoint(x: 2, y: middle), CGPoint(x: w - 2, y: middle), CGPoint(x: w / 2, y: 2), CGPoint(x: 3, y: 3), CGPoint(x: w - 12, y: chat - 3)]
            .allSatisfy { controller.pressTarget(at: $0) == .edge }
        let empty = controller.pressTarget(at: CGPoint(x: 14, y: middle)) == .drag && controller.pressTarget(at: CGPoint(x: w * 0.6, y: 24)) == .drag
        check("edges resize, empty space moves the panel", edges && empty)
        let log = model.registry.clips["log"] ?? CGRect(x: 0, y: 60, width: w, height: chat - 130)
        let column = stride(from: Double(log.minY) + 8, to: Double(log.maxY) - 8, by: 4).map { controller.pressTarget(at: CGPoint(x: 40, y: $0)) }
        if let first = column.firstIndex(of: .text), let last = column.lastIndex(of: .text) {
            let between = column[first...last]
            check("reply text selects; its gaps never move the panel", !between.contains(.drag),
                  between.map { String($0.rawValue.prefix(1)) }.joined())
        } else {
            check("reply text selects; its gaps never move the panel", false, "no text found")
        }
    }

    /// Drags `sides` by `delta` (screen points) and checks the panel follows exactly, then settles.
    private mutating func resize(_ sides: PanelEdges.Sides, by delta: CGSize, live: CGSize, settled: CGSize, name: String) async {
        let start = controller.windowFrame
        let mouse = NSPoint(x: start.midX, y: start.midY)
        controller.beginResize(sides, at: mouse)
        controller.resize(to: NSPoint(x: mouse.x + delta.width, y: mouse.y + delta.height))
        await wait(0.2)
        let during = controller.windowFrame
        controller.endResize()
        await wait(0.4)
        let after = controller.windowFrame
        func kept(_ f: NSRect) -> Bool {
            (sides.contains(.left) ? f.maxX == start.maxX : f.minX == start.minX)
                && (sides.contains(.bottom) ? f.maxY == start.maxY : f.minY == start.minY)
        }
        let follows = during.width - start.width == live.width && during.height - start.height == live.height && kept(during)
        let settles = after.width - start.width == settled.width && after.height - start.height == settled.height && kept(after)
        check("\(name) follows the pointer, then settles on whole cells", follows && settles, "\(start) → \(during) → \(after)")
    }

    // MARK: - Helpers

    private mutating func check(_ name: String, _ ok: Bool, _ detail: String = "") {
        results.append(["check": name, "ok": ok, "detail": detail])
    }

    private func type(_ text: String) {
        guard let view = controller.composerTextView else { return }
        view.window?.makeFirstResponder(view)
        for character in text { view.insertText(String(character), replacementRange: view.selectedRange()) }
    }

    private func wait(_ seconds: Double) async {
        try? await Task.sleep(for: .seconds(seconds))
    }

    private func waitUntil(_ limit: Double, _ condition: () -> Bool) async {
        let end = Date().addingTimeInterval(limit)
        while !condition(), Date() < end { await wait(0.1) }
    }

    /// Whether `trail` passes through `steps` in order.
    static func contains(_ trail: [String], _ steps: [String]) -> Bool {
        var i = 0
        for state in trail where i < steps.count && state == steps[i] { i += 1 }
        return i == steps.count
    }
}

extension Interface {
    /// Runs the self-test (`parts`, comma separated: panel, edges, main, menu; all if nil) and
    /// writes its results to `path` as JSON.
    public func runSelfTest(writingTo path: String, failing: any ChatBackend, parts: String? = nil) {
        let chosen = parts.map { $0.split(separator: ",").compactMap { PanelSelfTest.Part(rawValue: $0.trimmingCharacters(in: .whitespaces)) } }
        Task {
            var test = PanelSelfTest(interface: self, failing: failing, parts: chosen?.isEmpty == false ? chosen! : PanelSelfTest.Part.allCases)
            let results = await test.run()
            let passed = results.allSatisfy { $0["ok"] as? Bool == true }
            let report: [String: Any] = ["passed": passed, "checks": results]
            if let data = try? JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]) {
                FileManager.default.createFile(atPath: path, contents: data)
            }
            NSApp.terminate(nil)
        }
    }
}
