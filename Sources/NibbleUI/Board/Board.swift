import Foundation

/// The board's look: the grid and how the light is mixed. The defaults are the values the design
/// settled on.
struct BoardLook: Equatable, Sendable {
    /// Cell pitch in points; the lit square is `pitch - gap`.
    var pitch = 10.0
    var gap = 1.0
    /// How visible unlit cells are (0 hides the grid).
    var grid = 0.5
    /// Strength of the motions and moments.
    var field = 1.0
    /// How far the board is muted toward its haze colour (frosted glass).
    var veil = 0.5
    var saturation = Palette.defaultSaturation
    /// Tempo of every motion.
    var speed = 1.0
    /// The brightest light leans pink.
    var spectrum = true
    /// Warmth (a failed request, a fast answer) turns the light toward rose.
    var tint = true
}

/// What the panel hands the board every frame: its size, how open it is, and the few lights tied
/// to controls and to the reader's own text. All in points, origin at the panel's top left.
struct BoardScene {
    struct Rect {
        var x0, y0, x1, y1: Double
    }

    /// A round soft light under a key.
    struct Round {
        var x, y, r, v: Double
        var clip: Rect?
    }

    /// A feathered rectangle of light (`soft`: the feather in points).
    struct Soft {
        var rect: Rect
        var v: Double
        var soft: Double
        var clip: Rect?
    }

    /// A plate of whole cells under a block of text (rose under an error), or a few lit cells
    /// standing for a control (the settings' section ruler) at a brightness of their own.
    struct Plate {
        var rect: Rect
        var clip: Rect?
        var rose: Bool
        var value = 0.27
        /// Light the whole cells nearest the rectangle (as many as it is wide and tall, at least
        /// one), wherever it falls between cell middles: lamps and the ruler's bars.
        var snap = false
    }

    /// The band of light that leads a new page in.
    struct Sweep {
        var x, dir, amp: Double
    }

    var width: Double
    var height: Double
    /// 0 closed … 1 open: summoning blooms the light from the middle.
    var open = 1.0
    var lights: [Round] = []
    var softs: [Soft] = []
    var plates: [Plate] = []
    var sweep: Sweep?
    /// Where a dragged file is.
    var drop: (x: Double, y: Double)?
    /// How far the light should turn toward rose (the board eases toward it).
    var warm = 0.0
    /// The panel folded into its strip (see `BoardGeometry.strip`), with its key, where moments
    /// start, and the end of its text, where the cursor stands.
    var strip = false
    var source: (x: Double, y: Double)?
    var caret: (x: Double, y: Double)?
    /// How far a failure's red has spread from `source` (0 none … 1 the whole board): the lit cells
    /// it has reached show in the warning colour. Only with a source.
    var alert = 0.0

    /// Moves everything right by `dx` and down by `dy` points, for a board whose first column and
    /// row start that far left of and above the window (the panel while its size is between whole
    /// cells); the scene grows by as much.
    mutating func shift(dx: Double, dy: Double) {
        guard dx != 0 || dy != 0 else { return }
        width += dx
        height += dy
        func moved(_ r: Rect) -> Rect { Rect(x0: r.x0 + dx, y0: r.y0 + dy, x1: r.x1 + dx, y1: r.y1 + dy) }
        for i in lights.indices {
            lights[i].x += dx
            lights[i].y += dy
            lights[i].clip = lights[i].clip.map(moved)
        }
        for i in softs.indices {
            softs[i].rect = moved(softs[i].rect)
            softs[i].clip = softs[i].clip.map(moved)
        }
        for i in plates.indices {
            plates[i].rect = moved(plates[i].rect)
            plates[i].clip = plates[i].clip.map(moved)
        }
        if let sweep { self.sweep?.x = sweep.x + dx }
        if let point = drop { drop = (point.x + dx, point.y + dy) }
        if let point = source { source = (point.x + dx, point.y + dy) }
        if let point = caret { caret = (point.x + dx, point.y + dy) }
    }
}

/// How the board answers the reader's typing.
public enum TypingLight: String, CaseIterable, Sendable, Codable {
    /// A small light under each new character, fading.
    case trail
    /// A soft column of light through the caret, top to bottom, fading.
    case beam
    /// A light leaves the caret with each key and rises, spreading as it fades.
    case embers
}

/// What a failed request does to the board.
public enum ErrorHold: String, CaseIterable, Sendable, Codable {
    /// Reins in whatever is playing to a crawl and flashes the light toward red once.
    case stall
    /// Only the flash.
    case flash
}

/// The light board: the panel's whole surface is a grid of square cells, each a light of its own.
///
/// It shows a feeling, never a display: one continuous field of light whose motion changes with
/// the panel's state. Every frame it computes one value per cell, quantises it to 24 levels and 12
/// hue steps, and writes each cell's colour; `BoardView` draws them. With nothing playing every cell
/// is at its darkest. Light comes from the current motion (entering behind an erasing wave, or
/// crossfading), one-off moments, the reader's typing, lights under controls and plates under the
/// reader's text. A failed request stalls the board (its clock reined in to 10 %) and flashes it
/// toward red once.
@MainActor
final class Board {
    static let levels = 24
    static let gamma = 1.5
    static let hues = 12
    /// The row of fills after the hue steps: warnings and errors.
    static let alertTone = hues
    private static let fadeMs = 1000.0
    private static let frontMs = 1000.0
    private static let frontW = 80.0
    private static let knee = 0.5
    private static let cap = 0.72
    private static let veilAmount = 0.42
    private static let stallRate = 0.1
    private static let flashSeconds = 1.2

    private(set) var look = BoardLook()
    private(set) var palette = Palette(.dark)
    /// Reduced motion: no moments, no typing light, motions held still.
    var still = false

    private(set) var width: Double
    private(set) var maxHeight: Double
    private(set) var cols = 0
    private(set) var maxRows = 0
    /// Rows drawn in the last frame.
    private(set) var rows = 0
    /// Cells lit in the last frame (a measure for tests).
    private(set) var litCount = 0

    /// The colour of each cell in the last frame, row by row (RGBA, alpha 255).
    private(set) var cellColors: [UInt32] = []
    /// Whether the last frame differs from the one before (a still frame needs no drawing).
    private(set) var changed = true
    private var previous: [UInt32] = []
    private var previousRows = -1
    /// One colour per (hue, level): index 0 is the unlit cell; hue h, level l is 1 + h·23 + l − 1.
    /// After the 12 hue steps comes one row in the warning colour (`alertTone`).
    private(set) var fills: [SIMD3<UInt8>] = []
    /// The colour between the cells.
    private(set) var groundFill = SIMD3<UInt8>(0, 0, 0)

    private var v: [Double] = []
    private var tone: [Int8] = []
    private var drift: [Double] = []

    private var clock = 0.0
    private var rate = 1.0
    private var stalled = false
    private var holding: ErrorHold?
    private var flashAt = -Double.infinity
    private var flash = 0.0
    private var last = 0.0
    private(set) var warm = 0.0

    private struct ActiveMotion {
        var motion: Motion?
        var c0: Double
        var gain: Double
        var front: MotionFront?
    }

    private var motionNow = ActiveMotion(motion: nil, c0: 0, gain: 1, front: nil)
    private var motionBefore = ActiveMotion(motion: nil, c0: 0, gain: 1, front: nil)
    private var motionAt = -Double.infinity
    private var moments: [(moment: Moment, gain: Double, t0: Double)] = []
    private var marks: [(kind: TypingLight, x: Double, y: Double, t0: Double)] = []
    private let tapes = (before: TerminalTape(), after: TerminalTape())

    /// Milliseconds on a monotonic clock. Tests replace it.
    var now: () -> Double = { ProcessInfo.processInfo.systemUptime * 1000 }

    init(width: Double, maxHeight: Double) {
        self.width = width
        self.maxHeight = maxHeight
        allocate()
        paint()
    }

    // MARK: - Setup

    func setSize(width: Double, maxHeight: Double) {
        guard width != self.width || maxHeight != self.maxHeight else { return }
        self.width = width
        self.maxHeight = maxHeight
        allocate()
    }

    func setLook(_ next: BoardLook) {
        let pitch = look.pitch
        look = next
        if look.pitch != pitch { allocate() }
        paint()
    }

    func setPalette(_ next: Palette) {
        guard next != palette else { return }
        palette = next
        paint()
    }

    private func allocate() {
        let P = look.pitch
        cols = Int((width / P).rounded(.up))
        maxRows = Int((maxHeight / P).rounded(.up))
        let n = cols * maxRows
        v = Array(repeating: 0, count: n)
        tone = Array(repeating: -1, count: n)
        cellColors = Array(repeating: 0, count: n)
        previous = cellColors
        previousRows = -1
        // A fixed hue drift per cell, so the pink of bright light is not uniform.
        drift = (0..<n).map { i in
            let x = (Double(i % cols) + 0.5) * P
            let y = (Double(i / cols) + 0.5) * P
            return 0.5 + 0.5 * sin((x * 0.55 + y * 0.83) / 230)
        }
    }

    /// One fill per (hue, level). Hue steps run from the accent through its pink to the rose. Every
    /// fill, and the ground between cells, is muted toward the veil colour by the same amount.
    private func paint() {
        let pal = palette
        let veil = { (c: OKLab) in c.mixed(with: pal.veil, self.look.veil * Self.veilAmount).rgb8 }
        let unlit = pal.ground.mixed(with: pal.t[4], (pal.appearance == .light ? 0.06 : 0.08) * look.grid)
        // Dark: colour comes in early (deep violet light). Light: closer to even, so it stays airy.
        let bloom = pal.appearance == .dark ? 0.6 : 0.85
        var result = [veil(unlit)]
        for h in 0..<Self.hues {
            let ink = pal.accent.rotated(Double(h) / Double(Self.hues - 1) * pal.roseTurn)
            for l in 1..<Self.levels {
                result.append(veil(OKLab.glow(unlit, ink, pow(Double(l) / Double(Self.levels - 1), Self.gamma), bloom: bloom)))
            }
        }
        // One more row after the hue steps: the warning colour, for rose plates and lamps.
        for l in 1..<Self.levels {
            result.append(veil(OKLab.glow(unlit, pal.alert, pow(Double(l) / Double(Self.levels - 1), Self.gamma), bloom: bloom)))
        }
        fills = result
        groundFill = veil(pal.ground)
        previousRows = -1
    }

    @inline(__always) private static func level(_ v: Double) -> Int {
        Int((Double(levels - 1) * pow(clamp01(v), 1 / gamma)).rounded())
    }

    /// The colour a cell shows at value `v` and hue step `h` (also for surfaces drawn by views).
    func fill(_ value: Double, hue: Int = 0) -> SIMD3<UInt8> {
        let l = Self.level(value)
        return l == 0 ? fills[0] : fills[1 + min(hue, Self.hues - 1) * (Self.levels - 1) + l - 1]
    }

    // MARK: - What the panel triggers

    /// Sets the board's motion (nil for a dark board); `gain` scales it.
    func setMotion(_ motion: Motion?, gain: Double = 1) {
        let m = motionNow
        if motion == m.motion && gain == m.gain { return }
        motionBefore = m
        motionNow = ActiveMotion(
            motion: motion,
            c0: motion == m.motion ? m.c0 : clock,
            gain: gain,
            front: motion != m.motion ? motion?.front : nil
        )
        motionAt = now()
    }

    var currentMotion: Motion? { motionNow.motion }

    /// A one-off moment of the whole board, its light scaled by `gain`.
    func play(_ moment: Moment, gain: Double = 1) {
        guard !still else { return }
        moments.append((moment, gain, now()))
        if moments.count > 6 { moments.removeFirst() }
    }

    /// Holds the board after a failed request (see `ErrorHold`); nil releases it, and the board
    /// picks up speed again. Without `flash` it only holds (the strip turns red instead).
    func hold(_ kind: ErrorHold?, flash: Bool = true) {
        if let kind, kind != holding, !still, flash { flashAt = now() }
        holding = kind
        stalled = kind == .stall
    }

    var isStalled: Bool { stalled }
    /// Lights from the reader's typing still fading (for the self-test).
    var typingMarks: Int { marks.count }
    /// Moments playing now (for the self-test).
    var playingMoments: [Moment] { moments.map(\.moment) }
    var clockRate: Double { rate }

    /// The board answers a key while the reader types, at the caret (points).
    func keyPress(_ kind: TypingLight, x: Double, y: Double) {
        guard !still else { return }
        marks.append((kind, x, y, now()))
        if marks.count > 40 { marks.removeFirst() }
    }

    /// True while something on the board changes from frame to frame.
    var isAnimating: Bool {
        motionNow.motion != nil || !moments.isEmpty || !marks.isEmpty || now() - motionAt < Self.fadeMs
            || flash > 0 || abs(rate - (stalled ? Self.stallRate : 1)) > 0.001
    }

    // MARK: - A frame

    func render(_ s: BoardScene) {
        renderCells(s)
        let n = rows * cols
        changed = rows != previousRows || !cellColors.prefix(n).elementsEqual(previous.prefix(n))
        if changed {
            previous.replaceSubrange(0..<n, with: cellColors.prefix(n))
            previousRows = rows
        }
    }

    /// True while something on the board moves fast enough to want 60 frames a second: a wave or
    /// crossfade between motions, a moment, the typing light, a failure's flash, a stall easing.
    var wantsFullRate: Bool {
        !moments.isEmpty || !marks.isEmpty || now() - motionAt < Self.frontMs + 100 || flash > 0
            || abs(rate - (stalled ? Self.stallRate : 1)) > 0.01 || motionNow.motion == .warp
    }

    private func renderCells(_ s: BoardScene) {
        let t = now()
        let dt = last > 0 ? min(0.05, (t - last) / 1000) : 0
        last = t
        let P = look.pitch
        // A stall reins the clock in quickly; release lets it pick up a little more gently.
        let goal = stalled ? Self.stallRate : 1
        rate += (goal - rate) * (1 - exp(-dt / (goal < rate ? 0.18 : 0.45)))
        clock += dt * (still ? 0 : look.speed) * rate
        // Warmth turns toward its target gradually and cools back more slowly still; a failure's
        // flash rises at once and settles over about a second.
        let age = (t - flashAt) / 1000
        flash = age < Self.flashSeconds ? smooth(0, 0.08, age) * exp(-age / 0.45) : 0
        let target = look.tint ? s.warm : 0
        warm += (target - warm) * (1 - exp(-dt / (target > warm ? 1.4 : 4)))

        litCount = 0
        rows = min(maxRows, Int((s.height / P - 0.001).rounded(.up)))
        guard rows > 0, s.open > 0, !fills.isEmpty else {
            rows = max(0, rows)
            for i in 0..<(rows * cols) { cellColors[i] = Self.pack(groundFill) }
            return
        }
        for i in 0..<(rows * cols) { tone[i] = -1 }
        let painted = field(t, s)
        for part in painted where part.weight > 0.002 {
            starfield(part.frame, weight: part.weight * look.field)
        }
        for light in s.lights { round(light) }
        for q in s.softs { soft(q) }
        typingLight(t)
        extras(s)
        for q in s.plates { plate(q) }
        settle(s)
        draw(s)
    }

    /// The motions (crossfading, or one entering behind an erasing wave) and the moments, over a
    /// board that is otherwise at its darkest. Returns the painted motions (stars) and their weights.
    private func field(_ now: Double, _ s: BoardScene) -> [(frame: MotionFrame, weight: Double)] {
        let W = s.width
        let H = s.height
        let c = BoardGeometry(W: W, H: H, P: look.pitch, strip: s.strip, source: s.source, caret: s.caret)
        let mb = motionBefore
        let ma = motionNow
        let tb = clock - mb.c0
        let ta = clock - ma.c0
        let before = mb.motion.map { MotionFrame($0, t: tb, c: c, tape: tapes.before) }
        let after = ma.motion.map { MotionFrame($0, t: ta, c: c, tape: tapes.after) }
        let front = still ? nil : ma.front
        let progress = still ? 1 : clamp01((now - motionAt) / (front != nil ? Self.frontMs : Self.fadeMs))
        let cross = smooth(0, 1, progress)

        var painted: [(MotionFrame, Double)] = []
        if let before, before.motion.paints, cross < 1 { painted.append((before, (1 - cross) * mb.gain)) }
        if let after, after.motion.paints, cross > 0 { painted.append((after, cross * ma.gain)) }

        // A wave sweeps the new motion in along `proj`; its crest erases the old one.
        var proj: ((Double, Double) -> Double)?
        var span = 0.0
        if let front, progress < 1 {
            let R = hypot(W, H) / 2 + 20
            switch front {
            case .outward:
                proj = { x, y in hypot(x - c.cx, y - c.cy) }
                span = R
            case .inward:
                proj = { x, y in R - hypot(x - c.cx, y - c.cy) }
                span = R
            case let .along(fx, fy):
                let o = min(0, fx * W) + min(0, fy * H)
                proj = { x, y in x * fx + y * fy - o }
                span = abs(fx) * W + abs(fy) * H
            }
        }
        let crest = progress * (span + 2 * Self.frontW) - Self.frontW

        moments.removeAll { now - $0.t0 >= $0.moment.duration }
        let live = moments.map { (moment: $0.moment, p: (now - $0.t0) / $0.moment.duration, gain: $0.gain) }
        let valueBefore = (before?.motion.paints == false && cross < 1) ? before : nil
        let valueAfter = (after?.motion.paints == false && cross > 0) ? after : nil
        let P = look.pitch
        let fieldGain = look.field

        for r in 0..<rows {
            let y = (Double(r) + 0.5) * P
            let i0 = r * cols
            for col in 0..<cols {
                let x = (Double(col) + 0.5) * P
                var val = 0.0
                var wa = cross
                if let proj {
                    let p = proj(x, y)
                    wa = 1 - smooth(crest - Self.frontW, crest, p)
                    val += 0.12 * exp(-pow((p - crest) / (Self.frontW * 0.5), 2)) * (1 - cross) // the crest
                }
                if let valueBefore, wa < 1 { val += (1 - wa) * mb.gain * valueBefore.value(x, y) }
                if let valueAfter, wa > 0 { val += wa * ma.gain * valueAfter.value(x, y) }
                for m in live { val += m.gain * m.moment.value(x, y, m.p, c) }
                v[i0 + col] = fieldGain * val
            }
        }
        return painted
    }

    /// A field of stars seen from inside, moving toward the viewer (warp) or twinkling still. Each
    /// star comes from far (z = 1) to near (z = 0.08), then starts again elsewhere. In the tunnel
    /// and warp each star keeps a pace of its own (0.6–1.8 times the field's, most of them slow),
    /// and draws a tail as long as its pace: at the tunnel's slow speed only the fast ones show one.
    /// On the strip the field is pressed flat to the strip's shape, with fewer stars, so they stay
    /// on it and the tunnel opens out along it.
    private func starfield(_ f: MotionFrame, weight w: Double) {
        let warp = f.motion == .warp || f.motion == .tunnel
        let steady = f.motion == .tunnel
        let c = f.c
        let t = f.t
        // The tunnel keeps one slow speed; warp drifts at that pace first, then gathers pace.
        let k = steady ? 0.3 : warp ? warpDensity(t) : 0
        let travel = steady ? tunnelSpeed * t : warp ? warpTravel(t) : 0
        let speed = steady ? tunnelSpeed : warp ? warpSpeed(t) : 0
        let count = (warp ? 80 + 60 * k : 80) * (c.strip ? 0.4 : 1)
        let flat = c.strip ? min(1, 1.6 * c.H / c.W) : 1
        let R = hypot(c.W, c.H) / 2
        let span = 0.92
        let tw = 1 - smooth(0.03, 0.15, speed) // twinkling fades out as the stars get going
        // Slow, the tails are drawn longer for their speed, so a slow tunnel still reads as one.
        let tailFor = 0.14 + 0.4 * (1 - smooth(0.1, 0.4, speed))
        let P = look.pitch
        for j in 0..<Int(count.rounded(.up)) {
            let jd = Double(j)
            let fadeIn = clamp01(count - jd)
            let h = hash(jd * 5.71 + 2.3)
            let pace = warp ? 0.6 + 1.2 * h * h : 1
            let zz = 0.08 + span * hash(jd * 1.37 + 0.5) - travel * pace
            let lap = floor((zz - 0.08) / span)
            let z = 0.08 + ((zz - 0.08).truncatingRemainder(dividingBy: span) + span).truncatingRemainder(dividingBy: span)
            let a = tau * hash(jd * 7.13 + lap * 3.71)
            let q = 0.07 + 0.3 * hash(jd * 2.91 + lap * 5.17) // never at the middle: the tunnel's end stays clear
            let r = R * q / z
            let hx = c.cx + cos(a) * r
            let hy = c.cy + sin(a) * r * flat
            if hx < -20 || hx > c.W + 20 || hy < -20 || hy > c.H + 20 { continue }
            let rt = R * q / min(1, z + speed * pace * tailFor)
            let near = 1 - (z - 0.08) / span
            // Faster stars a little brighter, so the eye follows them in.
            var b = (0.1 + 0.34 * pow(near, 1.5)) * w * fadeIn * (0.85 + 0.25 * (pace - 0.6))
            if tw > 0.01 {
                b *= 1 - tw * (0.45 - 0.45 * sin(t * (1 + 2 * hash(jd * 4.1)) + tau * hash(jd * 9.7)))
            }
            segment(c.cx + cos(a) * rt, c.cy + sin(a) * rt * flat, hx, hy, sigma: (0.32 + 0.28 * near) * P, v: b)
        }
        if warp {
            round(BoardScene.Round(x: c.cx, y: c.cy, r: 70, v: 0.1 * k * w)) // the far end of the tunnel
        }
    }

    // MARK: - Shapes

    private struct CellRange {
        var c0, c1, r0, r1: Int
    }

    /// Cells covering [x0, x1] × [y0, y1], limited to the board and an optional clip.
    private func cells(_ x0: Double, _ x1: Double, _ y0: Double, _ y1: Double, clip: BoardScene.Rect?) -> CellRange {
        var (a0, a1, b0, b1) = (x0, x1, y0, y1)
        if let clip {
            a0 = max(a0, clip.x0)
            a1 = min(a1, clip.x1)
            b0 = max(b0, clip.y0)
            b1 = min(b1, clip.y1)
        }
        let P = look.pitch
        return CellRange(
            c0: max(0, Int(floor(a0 / P))),
            c1: min(cols, Int((a1 / P).rounded(.up))),
            r0: max(0, Int(floor(b0 / P))),
            r1: min(rows, Int((b1 / P).rounded(.up)))
        )
    }

    @inline(__always) private func inside(_ clip: BoardScene.Rect?, _ x: Double, _ y: Double) -> Bool {
        guard let clip else { return true }
        return x >= clip.x0 && x < clip.x1 && y >= clip.y0 && y < clip.y1
    }

    private func round(_ L: BoardScene.Round) {
        guard L.v >= 0.004 else { return }
        let reach = L.r * 2.6
        let g = cells(L.x - reach, L.x + reach, L.y - reach, L.y + reach, clip: L.clip)
        guard g.r0 < g.r1, g.c0 < g.c1 else { return }
        let k = 1 / (2 * L.r * L.r)
        let P = look.pitch
        for r in g.r0..<g.r1 {
            let y = (Double(r) + 0.5) * P
            let dy = y - L.y
            for c in g.c0..<g.c1 {
                let x = (Double(c) + 0.5) * P
                guard inside(L.clip, x, y) else { continue }
                let dx = x - L.x
                v[r * cols + c] += L.v * exp(-(dx * dx + dy * dy) * k)
            }
        }
    }

    /// A streak of light from (x0, y0) to its head (x1, y1), `sigma` wide, brightest at the head;
    /// a point when the two ends meet.
    private func segment(_ x0: Double, _ y0: Double, _ x1: Double, _ y1: Double, sigma: Double, v value: Double) {
        guard value >= 0.004 else { return }
        let reach = 2.6 * sigma
        let g = cells(min(x0, x1) - reach, max(x0, x1) + reach, min(y0, y1) - reach, max(y0, y1) + reach, clip: nil)
        guard g.r0 < g.r1, g.c0 < g.c1 else { return }
        let ex = x1 - x0
        let ey = y1 - y0
        let len2 = ex * ex + ey * ey
        let k = 1 / (2 * sigma * sigma)
        let P = look.pitch
        for r in g.r0..<g.r1 {
            let y = (Double(r) + 0.5) * P
            for c in g.c0..<g.c1 {
                let x = (Double(c) + 0.5) * P
                let u = len2 > 1 ? clamp01(((x - x0) * ex + (y - y0) * ey) / len2) : 1
                let dx = x - (x0 + ex * u)
                let dy = y - (y0 + ey * u)
                v[r * cols + c] += value * (0.2 + 0.8 * u * u) * exp(-(dx * dx + dy * dy) * k)
            }
        }
    }

    private func soft(_ q: BoardScene.Soft) {
        guard q.v >= 0.004 else { return }
        let f = q.soft
        let R = q.rect
        let g = cells(R.x0 - 2.5 * f, R.x1 + 2.5 * f, R.y0 - 2.5 * f, R.y1 + 2.5 * f, clip: q.clip)
        guard g.r0 < g.r1, g.c0 < g.c1 else { return }
        let P = look.pitch
        for r in g.r0..<g.r1 {
            let y = (Double(r) + 0.5) * P
            let dy = max(R.y0 - y, 0, y - R.y1) / f
            for c in g.c0..<g.c1 {
                let x = (Double(c) + 0.5) * P
                guard inside(q.clip, x, y) else { continue }
                let dx = max(R.x0 - x, 0, x - R.x1) / f
                v[r * cols + c] += q.v * exp(-(dx * dx + dy * dy))
            }
        }
    }

    /// Every cell whose middle lies inside takes one steady value, so the plate reads as a box of
    /// whole cells; it jumps from row to row as the text scrolls freely past.
    private func plate(_ q: BoardScene.Plate) {
        let tone: Int8 = q.rose ? Int8(Self.alertTone) : -1
        let R = q.rect
        if q.snap {
            let P = look.pitch
            let c0 = Int((R.x0 / P).rounded())
            let r0 = Int((R.y0 / P).rounded())
            let across = max(1, Int(((R.x1 - R.x0) / P).rounded()))
            let down = max(1, Int(((R.y1 - R.y0) / P).rounded()))
            // A lamp scrolled off the board lights nothing.
            let rows = max(0, r0)..<max(max(0, r0), min(self.rows, r0 + down))
            let columns = max(0, c0)..<max(max(0, c0), min(cols, c0 + across))
            for r in rows {
                for c in columns {
                    guard inside(q.clip, (Double(c) + 0.5) * P, (Double(r) + 0.5) * P) else { continue }
                    v[r * cols + c] = q.value
                    self.tone[r * cols + c] = tone
                }
            }
            return
        }
        let g = cells(R.x0, R.x1, R.y0, R.y1, clip: q.clip)
        guard g.r0 < g.r1, g.c0 < g.c1 else { return }
        let P = look.pitch
        for r in g.r0..<g.r1 {
            let y = (Double(r) + 0.5) * P
            if y < R.y0 || y > R.y1 { continue }
            for c in g.c0..<g.c1 {
                let x = (Double(c) + 0.5) * P
                if x < R.x0 || x > R.x1 || !inside(q.clip, x, y) { continue }
                v[r * cols + c] = q.value
                self.tone[r * cols + c] = tone
            }
        }
    }

    private func typingLight(_ now: Double) {
        func life(_ kind: TypingLight) -> Double {
            switch kind {
            case .trail: 1100
            case .beam: 800
            case .embers: 1600
            }
        }
        marks.removeAll { now - $0.t0 >= life($0.kind) }
        let P = look.pitch
        for m in marks {
            let p = (now - m.t0) / life(m.kind)
            switch m.kind {
            case .trail:
                round(BoardScene.Round(x: m.x, y: m.y, r: 15, v: 0.4 * pow(1 - p, 2)))
            case .embers:
                round(BoardScene.Round(x: m.x, y: m.y - 170 * p, r: 10 + 34 * p, v: 0.3 * pow(1 - p, 1.5)))
            case .beam:
                let fade = 0.3 * pow(1 - p, 2)
                let k = 1 / (2 * 10.0 * 10.0)
                for col in 0..<cols {
                    let dx = (Double(col) + 0.5) * P - m.x
                    let val = fade * exp(-dx * dx * k)
                    if val > 0.004 { for r in 0..<rows { v[r * cols + col] += val } }
                }
            }
        }
    }

    /// The page sweep and a dragged file.
    private func extras(_ s: BoardScene) {
        let P = look.pitch
        if let sweep = s.sweep {
            let sigma = 52.0
            for c in 0..<cols {
                let d = ((Double(c) + 0.5) * P - sweep.x) * sweep.dir / sigma
                let val = sweep.amp * (exp(-0.5 * d * d) + (d > 0 ? 0.3 * exp(-d / 2) : 0))
                if val > 0.01 { for r in 0..<rows { v[r * cols + c] += val } }
            }
        }
        if let drop = s.drop {
            round(BoardScene.Round(x: drop.x, y: drop.y, r: 60, v: 0.34))
            for r in 0..<rows {
                let y = (Double(r) + 0.5) * P
                for c in 0..<cols {
                    let x = (Double(c) + 0.5) * P
                    v[r * cols + c] += 0.24 * exp(-max(0, min(x, s.width - x, y, s.height - y)) / 10)
                }
            }
        }
    }

    /// Caps the brightest light, adds a failure's flash, and blooms the board on summoning.
    private func settle(_ s: BoardScene) {
        let n = rows * cols
        let lift = 0.1 * flash
        let knee = Self.knee
        let cap = Self.cap
        for i in 0..<n {
            var val = v[i] + lift
            if val > knee { val = knee + (cap - knee) * (1 - exp(-(val - knee) / (cap - knee))) }
            v[i] = val
        }
        if s.open < 1 {
            let soft = 140.0
            let R = s.open * (hypot(s.width, s.height) / 2 + soft)
            let P = look.pitch
            for r in 0..<rows {
                let y = (Double(r) + 0.5) * P - s.height / 2
                for c in 0..<cols {
                    let x = (Double(c) + 0.5) * P - s.width / 2
                    v[r * cols + c] *= 1 - smooth(R - soft, R, (x * x + y * y).squareRoot())
                }
            }
        }
    }

    /// Quantises each cell and gives it its colour. Hue: by default only the brightest light leans
    /// pink (half way along the axis); warmth, and a failure's flash, turn lit cells further toward
    /// the rose, the dim ones least. A failure on the strip turns the lit cells to the warning
    /// colour as its red spreads out from the key, cell by cell, never back and forth.
    private func draw(_ s: BoardScene) {
        let L1 = Self.levels - 1
        let grid = look.grid > 0.001
        let warmth = min(1, warm + (look.tint ? flash : 0))
        let unlit = Self.pack(grid ? fills[0] : groundFill)
        let P = look.pitch
        var red: (x: Double, y: Double, reach: Double)?
        if s.alert > 0, let o = s.source {
            let far = max(hypot(o.x, o.y), hypot(s.width - o.x, o.y), hypot(o.x, s.height - o.y), hypot(s.width - o.x, s.height - o.y))
            red = (o.x, o.y, s.alert * (far + P))
        }
        var lit = 0
        for i in 0..<(rows * cols) {
            let l = Self.level(v[i])
            guard l > 0 else {
                cellColors[i] = unlit
                continue
            }
            let val = v[i]
            if let red, hypot((Double(i % cols) + 0.5) * P - red.x, (Double(i / cols) + 0.5) * P - red.y) <= red.reach {
                cellColors[i] = Self.pack(fills[1 + Self.alertTone * L1 + (l - 1)])
                lit += 1
                continue
            }
            let base = look.spectrum ? 0.5 * clamp01(0.15 * drift[i] + 0.85 * smooth(0.3, 0.75, val)) : 0
            let turn = warmth * (0.3 + 0.7 * smooth(0.06, 0.4, val))
            let h = tone[i] >= 0 ? Int(tone[i]) : Int((clamp01(base + turn * (1 - base * 0.5)) * Double(Self.hues - 1)).rounded())
            cellColors[i] = Self.pack(fills[1 + h * L1 + (l - 1)])
            lit += 1
        }
        litCount = lit
    }

    @inline(__always) static func pack(_ c: SIMD3<UInt8>) -> UInt32 {
        UInt32(c.x) | UInt32(c.y) << 8 | UInt32(c.z) << 16 | 0xFF00_0000
    }
}
