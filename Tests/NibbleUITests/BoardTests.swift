import CoreGraphics
import Foundation
import ImageIO
import Testing
import UniformTypeIdentifiers
@testable import NibbleUI

/// The board's light, checked numerically, and (with NIBBLE_BOARD_SHOTS set to a folder) written
/// out as pictures to compare by eye.
@MainActor
@Suite struct BoardTests {
    /// A board on a fake clock, stepped in 50 ms frames (20 fps).
    @MainActor final class Rig {
        let board = Board(width: 480, maxHeight: 800)
        var ms = 1000.0
        let height: Double

        init(height: Double = 560, appearance: Appearance = .dark) {
            self.height = height
            board.now = { [unowned self] in self.ms }
            board.setPalette(Palette(appearance))
        }

        func run(seconds: Double, scene: (inout BoardScene) -> Void = { _ in }) {
            let frames = Int(seconds * 20)
            for _ in 0..<frames {
                ms += 50
                var s = BoardScene(width: 480, height: height)
                scene(&s)
                board.render(s)
            }
        }
    }

    @Test func lampsLightWholeCellsWhereverTheyFall() {
        // A bar two cells by one, placed between cell middles (265.5–274.5 pt misses the middle of
        // every row): snapped, it still lights exactly two cells; a text plate there lights none.
        let rect = BoardScene.Rect(x0: 401, y0: 265.5, x1: 420, y1: 274.5)
        let rig = Rig()
        rig.board.setMotion(nil)
        rig.run(seconds: 0.2) { $0.plates = [BoardScene.Plate(rect: rect, clip: nil, rose: false, value: 0.5, snap: true)] }
        #expect(rig.board.litCount == 2)
        rig.run(seconds: 0.2) { $0.plates = [BoardScene.Plate(rect: rect, clip: nil, rose: false, value: 0.5)] }
        #expect(rig.board.litCount == 0)
        // Scrolled off the board, past either edge: nothing lit, nothing broken.
        let below = BoardScene.Rect(x0: 401, y0: 2000, x1: 420, y1: 2009)
        let left = BoardScene.Rect(x0: -300, y0: 100, x1: -281, y1: 109)
        rig.run(seconds: 0.2) { $0.plates = [below, left].map { BoardScene.Plate(rect: $0, clip: nil, rose: false, value: 0.5, snap: true) } }
        #expect(rig.board.litCount == 0)
    }

    @Test func aBoardWithNothingPlayingIsDark() {
        let rig = Rig()
        rig.run(seconds: 1)
        #expect(rig.board.litCount == 0)
        #expect(rig.board.rows == 56)
    }

    @Test(arguments: Motion.allCases)
    func everyMotionLightsTheBoard(_ motion: Motion) {
        let rig = Rig()
        rig.board.setMotion(motion)
        rig.run(seconds: 3)
        #expect(rig.board.litCount > 0, "\(motion) lit nothing")
        Self.shoot(rig.board, name: "motion-\(motion.rawValue)")
    }

    @Test func waitingLightRunsAlongTheEdges() {
        let rig = Rig()
        rig.board.setMotion(.circuit)
        for (i, seconds) in [0.4, 0.6, 0.8, 0.9].enumerated() {
            rig.run(seconds: seconds)
            Self.shoot(rig.board, name: "circuit-\(i)")
        }
        let frame = MotionFrame(.circuit, t: 1, c: BoardGeometry(W: 480, H: 560, P: 10), tape: TerminalTape())
        // A second in, the head is low on the right edge: lit there, dark in the middle.
        #expect(frame.value(475, 450) > 0.2)
        #expect(frame.value(240, 290) < 0.04)
    }

    @Test func readingLightsAPageThenSweepsItAway() {
        let rig = Rig()
        rig.board.setMotion(.page)
        var at = 0.0
        for (name, seconds) in [("appearing", 0.7), ("page", 1.8), ("sweep", 2.9), ("swept", 3.75), ("next", 4.6)] {
            rig.run(seconds: seconds - at)
            at = seconds
            Self.shoot(rig.board, name: "page-\(name)")
        }
        let c = BoardGeometry(W: 480, H: 560, P: 10)
        // The page held: the first line's first word lit, the row under it dark.
        let page = MotionFrame(.page, t: 1.8, c: c, tape: TerminalTape())
        #expect(page.value(25, 25) > 0.12)
        #expect(page.value(25, 35) < 0.03)
        // Half way through the sweep (crest near 361 pt): lines above are gone, lines below stay,
        // and the band fades faster ahead of its crest than behind it.
        let sweep = MotionFrame(.page, t: 2.9, c: c, tape: TerminalTape())
        #expect(sweep.value(25, 25) < 0.06)
        #expect([475.0, 505, 535].map { sweep.value(25, $0) }.max()! > 0.12)
        #expect(sweep.value(240, 401) < 0.5 * sweep.value(240, 321))
    }

    @Test func theTerminalTypesQuicklyInBurstsWithLinesOfEveryLengthAndDepth() {
        let c = BoardGeometry(W: 480, H: 560, P: 10)
        let tape = TerminalTape()
        var seen: [Int: TerminalTape.Line] = [:]
        var offsets: [Double] = []
        var t = 0.0
        while t < 20 {
            let frame = tape.frame(t, c)
            for line in frame.lines { seen[line.k] = line }
            offsets.append(frame.offset)
            t += 1.0 / 120
        }
        let lines = seen.values.sorted { $0.k < $1.k }
        // About five lines a second (it was about two).
        #expect(lines.count >= 80, "\(lines.count) lines in 20 s")
        // Bursts and pauses: some lines right after the one before, some after a wait.
        let intervals = zip(lines, lines.dropFirst()).map { $1.at - $0.at }
        #expect(intervals.contains { $0 < 0.06 } && intervals.contains { $0 > 0.3 })
        // Commands typed at paces of their own.
        let commands = lines.filter(\.command)
        #expect(Set(commands.map { Int($0.len / $0.dur / 50) }).count >= 4)
        // Output steps in and out over several depths; lengths run from a word to nearly the width.
        #expect(Set(lines.map(\.level)).count >= 4)
        let usable = c.W - 2 * TerminalTape.margin
        #expect(lines.contains { $0.len < 0.15 * usable } && lines.contains { $0.len > 0.75 * usable })
        // Every line stays on the board.
        #expect(lines.allSatisfy { $0.indent >= TerminalTape.margin && $0.indent + $0.len <= c.W - TerminalTape.margin + 1e-6 })
        // The tape scrolls smoothly: never back, and under half a line a frame even in a burst.
        let steps = zip(offsets, offsets.dropFirst()).map { $1 - $0 }
        #expect(steps.allSatisfy { $0 > -1e-9 }, "scrolled back")
        #expect(steps.max()! < 0.5 * 2 * c.P, "largest step \(steps.max()!)")
    }

    @Test func aStallReinsTheClockInAndReleaseLetsItGo() {
        let rig = Rig()
        rig.board.setMotion(.lava)
        rig.run(seconds: 1)
        rig.board.hold(.stall)
        rig.run(seconds: 1.5)
        #expect(rig.board.clockRate < 0.15)
        rig.board.hold(nil)
        rig.run(seconds: 2)
        #expect(rig.board.clockRate > 0.85)
    }

    @Test func platesAreWholeCellsAtOneLevel() {
        let rig = Rig()
        rig.run(seconds: 0.2) { s in
            s.plates = [BoardScene.Plate(rect: .init(x0: 100, y0: 100, x1: 300, y1: 140), clip: nil, rose: false)]
        }
        // Cells whose middles are inside: x 105…295 (20 cells), y 105…135 (4 rows).
        #expect(rig.board.litCount == 80)
    }

    @Test(arguments: Moment.allCases)
    func momentsComeAndGo(_ moment: Moment) {
        let rig = Rig()
        rig.board.play(moment)
        rig.run(seconds: moment.duration / 2000)
        #expect(rig.board.litCount > 0)
        Self.shoot(rig.board, name: "moment-\(moment.rawValue)")
        rig.run(seconds: moment.duration / 1000)
        #expect(rig.board.litCount == 0)
    }

    // MARK: - The strip

    /// The panel folded into its strip on a fake clock: 310 × 40 pt, its key's middle at (20, 20),
    /// its text ending where the cursor stands, at 110 pt.
    @MainActor final class StripRig {
        static let size = (W: 310.0, H: 40.0)
        let board = Board(width: StripRig.size.W, maxHeight: StripRig.size.H)
        var ms = 1000.0
        var alert = 0.0

        init() {
            board.now = { [unowned self] in self.ms }
            board.setPalette(Palette(.dark))
        }

        static var geometry: BoardGeometry {
            BoardGeometry(W: size.W, H: size.H, P: 10, strip: true, source: (20, 20), caret: (110, 20))
        }

        func run(seconds: Double) {
            for _ in 0..<Int(seconds * 20) {
                ms += 50
                var s = BoardScene(width: Self.size.W, height: Self.size.H)
                s.strip = true
                s.source = (20, 20)
                s.caret = (110, 20)
                s.alert = alert
                board.render(s)
            }
        }

        /// The light of row `r`, cell by cell (0 unlit, else its level of 1–23).
        func row(_ r: Int) -> [Bool] {
            let unlit = Board.pack(board.fill(0))
            return (0..<board.cols).map { board.cellColors[r * board.cols + $0] != unlit }
        }
    }

    @Test(arguments: Motion.allCases)
    func everyMotionLightsTheStrip(_ motion: Motion) {
        let rig = StripRig()
        rig.board.setMotion(motion)
        var frames: [[UInt32]] = []
        var lit = 0
        for _ in 0..<8 {
            rig.run(seconds: 0.4)
            lit = max(lit, rig.board.litCount)
            frames.append(Array(rig.board.cellColors.prefix(rig.board.rows * rig.board.cols)))
        }
        #expect(lit > 0, "\(motion) lit nothing on the strip")
        Self.film(frames, cols: rig.board.cols, rows: rig.board.rows, board: rig.board, name: "strip-\(motion.rawValue)")
    }

    @Test func theStripsLightOverTime() {
        // Pictures only: thinking long into the tunnel, and the answer's ripple from the key.
        let rig = StripRig()
        rig.board.setMotion(.warp)
        rig.run(seconds: 12)
        var frames: [[UInt32]] = []
        for _ in 0..<6 {
            rig.run(seconds: 0.3)
            frames.append(Array(rig.board.cellColors.prefix(rig.board.rows * rig.board.cols)))
        }
        Self.film(frames, cols: rig.board.cols, rows: rig.board.rows, board: rig.board, name: "strip-warp-later")
        let bloom = StripRig()
        bloom.board.setMotion(.glimmer, gain: 0.6)
        bloom.run(seconds: 1)
        bloom.board.play(.bloom)
        frames = []
        for _ in 0..<7 {
            bloom.run(seconds: 0.15)
            frames.append(Array(bloom.board.cellColors.prefix(bloom.board.rows * bloom.board.cols)))
        }
        #expect(bloom.board.litCount > 0)
        Self.film(frames, cols: bloom.board.cols, rows: bloom.board.rows, board: bloom.board, name: "strip-bloom")
    }

    @Test func theStripsWaitingLightsGoRoundTogether() {
        // Three lights a third of the way round: at any moment the top and the bottom row are both lit
        // somewhere, each with its own short run of light, and the middle stays darker than the edges.
        let c = StripRig.geometry
        for t in stride(from: 0.0, through: 3, by: 0.25) {
            let frame = MotionFrame(.circuit, t: t, c: c, tape: TerminalTape())
            let top = stride(from: 5.0, to: c.W, by: 10).map { frame.value($0, 5) }
            let bottom = stride(from: 5.0, to: c.W, by: 10).map { frame.value($0, 35) }
            #expect(top.max()! > 0.3 && bottom.max()! > 0.3, "t \(t)")
            // Lights with dimmer stretches between them, not a bar along a whole side.
            #expect(top.max()! > 3 * top.min()! && bottom.max()! > 3 * bottom.min()!, "t \(t)")
        }
    }

    @Test func theTerminalPrintsARowALineOnTheStrip() {
        let rig = StripRig()
        rig.board.setMotion(.terminal)
        var rowsLit = Set<Int>()
        for _ in 0..<30 {
            rig.run(seconds: 0.1)
            for r in 0..<4 where rig.row(r).contains(true) { rowsLit.insert(r) }
        }
        #expect(rowsLit == [0, 1, 2, 3])
    }

    @Test func theStripsCursorStandsAfterItsText() {
        let frame = MotionFrame(.cursor, t: 0, c: StripRig.geometry, tape: TerminalTape())
        #expect(frame.value(110, 20) > 0.25)
        #expect(frame.value(155, 20) < 0.02)
    }

    @Test func theStripsRippleStartsAtItsKey() {
        let c = StripRig.geometry
        let early = (x: Moment.bloom.value(30, 20, 0.08, c), far: Moment.bloom.value(290, 20, 0.08, c))
        #expect(early.x > 3 * early.far)
        // It crosses the whole strip.
        #expect(Moment.bloom.value(290, 20, 0.5, c) > 0.04)
    }

    @Test func aFailureTurnsTheStripRedFromItsKeyWithoutAFlash() {
        // Holding without a flash leaves a dark board dark; the panel's own hold flashes it.
        let quiet = StripRig()
        quiet.board.setMotion(nil)
        quiet.run(seconds: 0.2)
        quiet.board.hold(.stall, flash: false)
        quiet.run(seconds: 0.2)
        #expect(quiet.board.litCount == 0)
        let flashed = StripRig()
        flashed.board.setMotion(nil)
        flashed.run(seconds: 0.2)
        flashed.board.hold(.stall)
        flashed.run(seconds: 0.2)
        #expect(flashed.board.litCount > 0)

        // Half way: lit cells near the key are in the warning colour, those at the far end are not.
        let rig = StripRig()
        rig.board.setMotion(.glimmer, gain: 3)
        rig.run(seconds: 1)
        rig.board.hold(.stall, flash: false)
        rig.alert = 0.4
        rig.run(seconds: 0.1)
        let alert = Set((1..<Board.levels).map { Board.pack(rig.board.fills[1 + Board.alertTone * (Board.levels - 1) + $0 - 1]) })
        let cols = rig.board.cols
        let colors = rig.board.cellColors
        let near = (0..<4).flatMap { r in (0..<6).map { colors[r * cols + $0] } }.filter { $0 != Board.pack(rig.board.fill(0)) }
        let far = (0..<4).flatMap { r in (cols - 6..<cols).map { colors[r * cols + $0] } }.filter { $0 != Board.pack(rig.board.fill(0)) }
        #expect(!near.isEmpty && near.allSatisfy(alert.contains))
        #expect(!far.isEmpty && far.allSatisfy { !alert.contains($0) })
        rig.alert = 1
        rig.run(seconds: 0.1)
        let all = rig.board.cellColors.prefix(rig.board.rows * cols).filter { $0 != Board.pack(rig.board.fill(0)) }
        #expect(all.allSatisfy(alert.contains))
        Self.film([Array(colors.prefix(rig.board.rows * cols)), Array(rig.board.cellColors.prefix(rig.board.rows * cols))],
                  cols: cols, rows: rig.board.rows, board: rig.board, name: "strip-error")
    }

    @Test func aFrameIsCheap() {
        let rig = Rig(height: 800)
        rig.board.setMotion(.lava)
        rig.run(seconds: 1)
        let start = ContinuousClock.now
        rig.run(seconds: 5) // 100 frames
        let perFrame = (ContinuousClock.now - start) / 100
        #expect(perFrame < .milliseconds(4), "a frame took \(perFrame)")
    }

    // MARK: - Pictures

    /// Writes the board's last frame as a PNG at 2× when NIBBLE_BOARD_SHOTS names a folder.
    static func shoot(_ board: Board, name: String) {
        guard let folder = ProcessInfo.processInfo.environment["NIBBLE_BOARD_SHOTS"] else { return }
        let scale = 2.0
        let P = board.look.pitch
        let width = Int(board.width * scale)
        let height = Int(Double(board.rows) * P * scale)
        guard let context = CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return }
        context.translateBy(x: 0, y: CGFloat(height))
        context.scaleBy(x: scale, y: -scale)
        func set(_ c: SIMD3<UInt8>) {
            context.setFillColor(red: CGFloat(c.x) / 255, green: CGFloat(c.y) / 255, blue: CGFloat(c.z) / 255, alpha: 1)
        }
        set(board.groundFill)
        context.fill(CGRect(x: 0, y: 0, width: board.width, height: Double(board.rows) * P))
        let square = P - board.look.gap
        for (i, packed) in board.cellColors.prefix(board.rows * board.cols).enumerated() {
            set(SIMD3(UInt8(packed & 0xFF), UInt8(packed >> 8 & 0xFF), UInt8(packed >> 16 & 0xFF)))
            context.fill(CGRect(x: Double(i % board.cols) * P, y: Double(i / board.cols) * P, width: square, height: square))
        }
        write(context, to: folder, name: name)
    }

    /// Writes frames of a board one under the other, with a gap, as a PNG at 2× when
    /// NIBBLE_BOARD_SHOTS names a folder: a strip's light seen over time.
    static func film(_ frames: [[UInt32]], cols: Int, rows: Int, board: Board, name: String) {
        guard let folder = ProcessInfo.processInfo.environment["NIBBLE_BOARD_SHOTS"], !frames.isEmpty else { return }
        let scale = 2.0
        let P = board.look.pitch
        let gap = 12.0
        let w = Double(cols) * P
        let h = Double(rows) * P
        let total = Double(frames.count) * (h + gap) - gap
        guard let context = CGContext(
            data: nil, width: Int(w * scale), height: Int(total * scale), bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return }
        context.translateBy(x: 0, y: CGFloat(total * scale))
        context.scaleBy(x: scale, y: -scale)
        context.setFillColor(red: 0.5, green: 0.5, blue: 0.5, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: w, height: total))
        let square = P - board.look.gap
        for (k, cells) in frames.enumerated() {
            let y0 = Double(k) * (h + gap)
            let g = board.groundFill
            context.setFillColor(red: CGFloat(g.x) / 255, green: CGFloat(g.y) / 255, blue: CGFloat(g.z) / 255, alpha: 1)
            context.fill(CGRect(x: 0, y: y0, width: w, height: h))
            for (i, packed) in cells.enumerated() {
                context.setFillColor(red: CGFloat(packed & 0xFF) / 255, green: CGFloat(packed >> 8 & 0xFF) / 255, blue: CGFloat(packed >> 16 & 0xFF) / 255, alpha: 1)
                context.fill(CGRect(x: Double(i % cols) * P, y: y0 + Double(i / cols) * P, width: square, height: square))
            }
        }
        write(context, to: folder, name: name)
    }

    private static func write(_ context: CGContext, to folder: String, name: String) {
        guard let image = context.makeImage() else { return }
        let url = URL(filePath: folder).appending(path: "\(name).png")
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        guard let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil) else { return }
        CGImageDestinationAddImage(destination, image, nil)
        CGImageDestinationFinalize(destination)
    }
}
