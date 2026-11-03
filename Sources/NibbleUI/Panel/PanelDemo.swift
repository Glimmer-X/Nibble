import AppKit
import NibbleCore

/// Plays the panel through its moments at a pace meant to be watched, for a recording
/// (`scripts/demo.sh`), under a minute. Three questions: the first waits, thinks (straight into
/// the tunnel, played faster than usual so it gathers pace in the few seconds shown), searches,
/// reads and answers; the second asks to run a command,
/// is allowed and runs it (the terminal light); the third fails to connect and works on retry. Then the conversation's page, and
/// closing. Run with `-NibbleDemo <folder>`; the app hands it the scripted backends by name.
/// Development only; nothing calls it otherwise.
///
/// It talks to the recorder through files in the folder: it writes `backdrop` (the colour behind
/// the panel: sRGB, 0–255 each) and `region` (the screen area to record: x, y from the top left of
/// the main screen, width, height, in points), waits for `recording`, and writes `done` when the
/// panel has gone. Meanwhile `marks` gets a line per moment, its name and the seconds since the
/// recording began, for cutting the recording into clips (scripts/hero.sh).
@MainActor
struct PanelDemo {
    let interface: Interface
    let folder: URL
    /// The scripted backends: `answer`, `tool`, `fail`, `retry`.
    let backends: [String: any ChatBackend]

    /// Room around the panel in the recording.
    private static let margin = 64.0

    /// When the recording began, and the moments written so far.
    private let clock = Clock()

    final class Clock {
        var start = Date()
        var marks = ""
    }

    private var controller: PanelController { interface.panel }
    private var model: PanelModel { controller.model }

    func run() async {
        guard let screen = NSScreen.screens.first else { return }
        model.session.startNewConversation()
        controller.thinkAsTunnel()
        // The whole chat in the middle of the main screen.
        let area = screen.visibleFrame
        let w = model.settings.panelWidth
        let h = model.settings.panelHeight
        let origin = NSPoint(x: (area.midX - w / 2).rounded(), y: (area.midY - h / 2).rounded())
        controller.setPlace(origin)
        let m = Self.margin
        let region = NSRect(x: origin.x - m, y: origin.y - m, width: w + 2 * m, height: h + 2 * m)
        // A deep grey in the theme's hue behind the panel, a little lighter than its board so
        // its edge shows. Written before the region, so the recorder finds it when it starts.
        let backdrop = OKLab.lch(0.215, 0.018, model.palette.theme.hues.hue).rgb8
        write("backdrop", "\(backdrop.x) \(backdrop.y) \(backdrop.z)")
        write("region", "\(Int(region.minX)) \(Int(screen.frame.maxY - region.maxY)) \(Int(region.width)) \(Int(region.height))")
        await waitFor("recording", seconds: 20)
        clock.start = Date()
        await wait(0.4)

        // Summoned: the bar blooms in, the idle light plays.
        mark("summon")
        controller.summon()
        await wait(0.8)

        // A question: the chat unfolds upward; waiting, thinking into the tunnel, searching,
        // reading, writing, done.
        await ask("How long should I boil an egg for a jammy yolk?", with: "answer", mark: "ask")
        // The tunnel played faster than usual, so it gathers pace within the few seconds shown.
        await waitUntil(10) { [.think, .deep].contains(controller.lightTrail.last) }
        mark("think")
        tempo(2.2)
        await waitUntil(20) { controller.lightTrail.last == .search }
        mark("search")
        tempo(1)
        await waitUntil(60) { !model.session.isResponding }
        mark("answered")
        await wait(1.4)

        // A command to run: the model asks first, is allowed, runs it in the terminal.
        await ask("Install requests for my script.", with: "tool", mark: "ask-tool")
        await waitUntil(10) { if case .attention = model.session.phase { true } else { false } }
        mark("approval")
        await wait(1.6)
        model.answer(.allow)
        mark("allowed")
        await waitUntil(20) { !model.session.isResponding }
        mark("ran")
        await wait(1.2)

        // A request that cannot get through: the light stalls and flashes; retry, and it works.
        await ask("Turn these notes into a short email: standup moves to 10, demo on Friday.", with: "fail", mark: "ask-fail")
        await waitUntil(15) { !model.session.isResponding }
        mark("failed")
        await wait(2.2)
        model.session.backend = backends["retry"] ?? model.session.backend
        model.retry()
        mark("retry")
        await waitUntil(20) { !model.session.isResponding }
        mark("retried")
        await wait(1.4)

        // The conversation's page and back.
        mark("sheet")
        model.openSheet()
        await wait(1.8)
        model.closeSheet()
        await wait(0.9)

        // Closed: the chat folds into the bar and fades.
        mark("close")
        controller.dismiss()
        await waitUntil(5) { !controller.isVisible }
        await wait(0.6)
        mark("end")
        write("done", "")
    }

    /// Types `question` at a hand's pace (the board answers each key under the caret) and sends it
    /// to the backend named `backend`, marking when typing starts (`mark`) and when it is sent
    /// (`mark-sent`).
    private func ask(_ question: String, with backend: String, mark name: String) async {
        if let next = backends[backend] { model.session.backend = next }
        mark(name)
        if let field = controller.composerTextView {
            field.window?.makeFirstResponder(field)
            for (i, character) in question.enumerated() {
                field.insertText(String(character), replacementRange: field.selectedRange())
                await wait(character == " " ? 0.035 : 0.017 + 0.014 * Double((i * 7) % 5) / 4)
            }
        }
        await wait(0.35)
        model.send()
        mark("\(name)-sent")
    }

    /// Notes a moment in `marks`: its name and the seconds since the recording began.
    private func mark(_ name: String) {
        clock.marks += "\(name) \(String(format: "%.3f", Date().timeIntervalSince(clock.start)))\n"
        write("marks", clock.marks)
    }

    /// Plays every motion `speed` times as fast (1 is the usual tempo).
    private func tempo(_ speed: Double) {
        var look = controller.board.look
        look.speed = speed
        controller.board.setLook(look)
    }

    // MARK: - Helpers

    private func write(_ name: String, _ text: String) {
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: folder.appending(path: name).path, contents: Data(text.utf8))
    }

    private func waitFor(_ name: String, seconds: Double) async {
        let path = folder.appending(path: name).path
        await waitUntil(seconds) { FileManager.default.fileExists(atPath: path) }
    }

    private func wait(_ seconds: Double) async {
        try? await Task.sleep(for: .seconds(seconds))
    }

    private func waitUntil(_ limit: Double, _ condition: () -> Bool) async {
        let end = Date().addingTimeInterval(limit)
        while !condition(), Date() < end { await wait(0.05) }
    }
}

extension Interface {
    /// Plays the demo for a recording with the scripted `backends` (`answer`, `tool`, `fail`,
    /// `retry`), then quits.
    public func runDemo(signals folder: String, backends: [String: any ChatBackend]) {
        Task {
            await PanelDemo(interface: self, folder: URL(filePath: folder), backends: backends).run()
            NSApp.terminate(nil)
        }
    }
}
