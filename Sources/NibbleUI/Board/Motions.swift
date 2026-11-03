import Foundation

// The light board's vocabulary: whole-board motions (one per state of the panel) and one-off
// moments. The numbers were tuned by eye, state by state; BoardTests renders them to pictures
// (NIBBLE_BOARD_SHOTS) for comparing a change against the old look.

let tau = Double.pi * 2

@inline(__always) func clamp01(_ x: Double) -> Double { x < 0 ? 0 : x > 1 ? 1 : x }

@inline(__always) func smooth(_ a: Double, _ b: Double, _ x: Double) -> Double {
    let t = clamp01((x - a) / (b - a))
    return t * t * (3 - 2 * t)
}

/// A stable pseudo-random number in 0..<1 for `n`.
@inline(__always) func hash(_ n: Double) -> Double {
    let s = sin(n * 12.9898 + 78.233) * 43758.5453
    return s - floor(s)
}

/// The board's size and middle, in points, and its cell pitch.
struct BoardGeometry {
    let W: Double
    let H: Double
    let P: Double
    /// The panel folded into its strip, four cells tall: the motions that need room take a shape of
    /// their own there (see each motion).
    var strip = false
    /// Where moments start, when the board names a place: the strip's key.
    var source: (x: Double, y: Double)?
    /// Where the cursor stands, when the board names a place: just after the strip's text.
    var caret: (x: Double, y: Double)?
    var cx: Double { W / 2 }
    var cy: Double { H * 0.52 }
}

/// How a motion enters: behind a wave from the middle outward, inward, or along a direction.
enum MotionFront {
    case outward
    case inward
    case along(Double, Double)
}

/// A whole-board motion: the light of one state of the panel.
public enum Motion: String, CaseIterable, Sendable, Codable {
    /// The whole board swells from the middle outward and settles, every 3.2 s.
    case breath
    /// Wide, faint rings leave the middle, a few at a time.
    case rings
    /// Wide, faint rings close in on the middle.
    case converge
    /// A broad surge rolls across the board, every 2.4 s.
    case across
    /// A page: lines of whole cells, like lines of text, light up slowly, then a band of light
    /// sweeps down the board and wipes them out, and a new page lights up (every 3.8 s). The band
    /// leads with a short fade and trails a long one.
    case page
    /// A broad surge rises up the board.
    case rise
    /// A broad beam turns around the middle, once every 2.6 s, with a fading wake.
    case orbit
    /// A light runs round the board along its edges, starting at the top, once every 3 s with a
    /// fading wake: brightest at the edge, reaching in wider and fainter, the middle left dark. On
    /// the strip three lights run round a third of the way apart.
    case circuit
    /// A pool of light drifts around the board, pulsing as it goes.
    case wander
    /// Soft pools of light fade in and out here and there.
    case glimmer
    /// Crossing waves sharpen into a slowly shifting net of light.
    case caustics
    /// A lava lamp: bodies of light drift up, come and go by fading, merge and part.
    case lava
    /// Points of light near and far, twinkling where they are.
    case stars
    /// The same stars start toward the viewer: a slow drift first, then streaks gathering pace
    /// over about 40 s.
    case warp
    /// The tunnel at a slow, steady pace: stars coming toward the viewer in short streaks.
    case tunnel
    /// Cells light one by one until the board is pale, then go out one by one (every 5.2 s).
    case fill
    /// An abstract terminal: soft lines typed one after another, scrolling up as they fill.
    case terminal
    /// A wide soft light at the bottom edge rises and falls slowly.
    case hold
    /// One soft block of light in the middle blinks slowly (on the strip, just after its text).
    case cursor
    /// A current of light rises, its direction and shape wandering.
    case flow

    var front: MotionFront? {
        switch self {
        case .rings: .outward
        case .converge: .inward
        case .across: .along(0.94, 0.34)
        case .page: .along(0, 1)
        case .rise: .along(0, -1)
        default: nil
        }
    }

    /// Motions that draw sparse lights (stars) straight onto the cells instead of a value per cell.
    var paints: Bool { self == .stars || self == .warp || self == .tunnel }
}

/// A one-off moment of the whole board.
public enum Moment: String, CaseIterable, Sendable, Codable {
    /// A message leaves: a band of light rises from the bottom edge to the top.
    case rise
    /// An answer is done: one ripple blooms from low on the left and crosses the whole board (on
    /// the strip, from its key, narrower).
    case bloom
    /// The screen is captured: a broad band of light runs down the board.
    case scan

    /// How long the moment lasts, in milliseconds.
    var duration: Double {
        switch self {
        case .rise: 900
        case .bloom: 1300
        case .scan: 880
        }
    }

    /// The light the moment adds at (x, y), `p` (0–1) of the way through.
    func value(_ x: Double, _ y: Double, _ p: Double, _ c: BoardGeometry) -> Double {
        switch self {
        case .rise:
            let sigma = 64.0
            let yb = c.H + 2 * sigma - p * (c.H + 4 * sigma)
            let d = (y - yb) / sigma
            return pow(1 - p, 0.7) * (0.36 * exp(-0.5 * d * d) + (d > 0 ? 0.12 * exp(-d / 2.5) : 0))
        case .bloom:
            let ox = c.source?.x ?? c.W * 0.12
            let oy = c.source?.y ?? c.H * 0.8
            // On the strip the ring is narrower, brighter and its glow shorter: a ripple along it.
            let (ring, beyond, glow, strength) = c.strip ? (28.0, 40.0, 40.0, 0.42) : (120.0, 150.0, 110.0, 0.28)
            let d = hypot(x - ox, y - oy)
            let R = p.squareRoot() * (hypot(c.W - ox, oy) + beyond)
            let q = (d - R) / ring
            let rise = min(1, p / 0.1)
            return rise * pow(1 - p, 1.4) * (strength * exp(-0.5 * q * q) + 0.5 * strength * (1 - p) * exp(-d / glow))
        case .scan:
            let sigma = 40.0
            let yb = p * (c.H + 6 * sigma) - 3 * sigma
            let d = (y - yb) / sigma
            return 0.42 * exp(-0.5 * d * d) + (d < 0 ? 0.12 * exp(d / 2.5) : 0)
        }
    }
}

// MARK: - Shared shapes

/// A broad band of light rolling along `p` (points), once every `period` s, with a fading wake.
@inline(__always) private func rolling(_ p: Double, _ t: Double, _ period: Double, _ length: Double, _ sigma: Double) -> Double {
    let span = length + 6 * sigma
    let centre = (t / period).truncatingRemainder(dividingBy: 1) * span - 3 * sigma
    let d = (p - centre) / sigma
    return 0.02 + 0.28 * exp(-0.5 * d * d) + (d < 0 ? 0.07 * exp(d / 3) : 0)
}

/// Wide, faint rings around the middle, few at a time, moving out (dir 1) or in (dir −1).
@inline(__always) private func rings(_ x: Double, _ y: Double, _ t: Double, _ c: BoardGeometry, _ dir: Double) -> Double {
    let d = hypot(x - c.cx, y - c.cy)
    let w = 0.5 + 0.5 * cos(tau * (d / 280 - dir * t / 2))
    return 0.17 * w * w * w * (0.35 + 0.65 * exp(-d / 380))
}

// MARK: - A motion prepared for one frame

/// What a motion works out once per frame before it is evaluated at every cell.
enum MotionPrep {
    struct Pool { var x, y, v: Double }
    struct Blob { var x, y, R2, a, sx: Double }

    case none
    case wander(fx: Double, fy: Double, v: Double)
    case glimmer([Pool])
    case lava(near: [Blob], far: [Blob])
    case fill(lap: Double, on: Double, off: Double)
    case terminal(TerminalFrame)
    case page(PageFrame)
    case flow(ax: Double, ay: Double, bx: Double, by: Double, amp: Double)
}

/// A motion at `t` seconds of its own time, ready to give its light at any cell.
struct MotionFrame {
    let motion: Motion
    let t: Double
    let c: BoardGeometry
    let prep: MotionPrep

    init(_ motion: Motion, t: Double, c: BoardGeometry, tape: TerminalTape) {
        self.motion = motion
        self.t = t
        self.c = c
        prep = Self.prepare(motion, t, c, tape)
    }

    private static func prepare(_ motion: Motion, _ t: Double, _ c: BoardGeometry, _ tape: TerminalTape) -> MotionPrep {
        switch motion {
        case .wander:
            return .wander(
                fx: c.W * (0.5 + 0.32 * sin(t * 0.73)),
                fy: c.H * (0.5 + 0.28 * sin(t * 0.52 + 1.1)),
                v: 0.22 + 0.06 * sin(tau * t / 1.1)
            )
        case .glimmer:
            return .glimmer((0..<5).map { k in
                let k = Double(k)
                let ph = t / (1.6 + 0.3 * k) + k * 0.21
                let n = floor(ph)
                return MotionPrep.Pool(
                    x: c.W * (0.1 + 0.8 * hash(n * 7 + k * 13)),
                    y: c.H * (0.1 + 0.8 * hash(n * 11 + k * 5 + 3)),
                    v: pow(sin(Double.pi * (ph - n)), 2)
                )
            })
        case .lava:
            // On the strip the bodies take their size from its length too, or they would be specks.
            let m = c.strip ? max(min(c.W, c.H), 0.25 * c.W) : min(c.W, c.H)
            func layer(_ count: Int, _ rMin: Double, _ rMax: Double, _ pace: Double, _ seed: Double) -> [MotionPrep.Blob] {
                (0..<count).map { k in
                    let k = Double(k)
                    let life = (16 + 8 * hash(k * 3.3 + seed)) / pace
                    let ph = t / life + hash(k * 1.9 + seed)
                    let n = floor(ph)
                    let f = ph - n
                    func h(_ i: Double) -> Double { hash(n * 7.1 + k * 13.7 + seed + i * 3.3) }
                    let ang = -Double.pi / 2 + (h(1) - 0.5) * 1.4 + (h(2) - 0.5) * 0.8 * f
                    let dist = (0.15 + 0.25 * h(3)) * c.H
                    let r = m * (rMin + (rMax - rMin) * (0.5 + 0.5 * sin(t * 0.21 * pace + k * 1.7 + n)))
                    return MotionPrep.Blob(
                        x: c.W * (0.12 + 0.76 * h(5)) + cos(ang) * dist * f,
                        y: c.H * (0.35 + 0.6 * h(6)) + sin(ang) * dist * f,
                        R2: pow(1.9 * r, 2),
                        a: smooth(0, 0.25, f) * (1 - smooth(0.75, 1, f)),
                        sx: 1 + 0.18 * sin(t * 0.3 * pace + k * 2.1 + n)
                    )
                }
            }
            return .lava(near: layer(5, 0.1, 0.15, 1, 0), far: layer(2, 0.2, 0.26, 0.6, 50))
        case .fill:
            let period = 5.2
            let lap = floor(t / period)
            let p = t / period - lap
            return .fill(lap: lap, on: smooth(0, 0.4, p), off: smooth(0.5, 0.88, p))
        case .terminal:
            return .terminal(tape.frame(t, c))
        case .page:
            return .page(PageFrame(t, c))
        case .flow:
            let a = -Double.pi / 2 + 0.45 * sin(t * 0.21) + 0.25 * sin(t * 0.53 + 1)
            let b = a + 0.7 + 0.3 * sin(t * 0.17 + 2)
            return .flow(ax: cos(a), ay: sin(a), bx: cos(b), by: sin(b), amp: 0.85 + 0.15 * sin(t * 0.37))
        default:
            return .none
        }
    }

    /// The light the motion adds at (x, y).
    @inline(__always) func value(_ x: Double, _ y: Double) -> Double {
        switch prep {
        case .none:
            switch motion {
            case .breath:
                let d = hypot(x - c.cx, y - c.cy)
                let b = 0.5 - 0.5 * cos(tau * (t - d / 520) / 3.2)
                return b * (0.08 + 0.2 * exp(-(d * d) / (2 * 240 * 240)))
            case .rings:
                return rings(x, y, t, c, 1)
            case .converge:
                return rings(x, y, t, c, -1)
            case .across:
                // The strip is narrow: a narrower surge, so it is seen to roll along.
                return rolling(x * 0.94 + y * 0.34, t, 2.4, c.W * 0.94 + c.H * 0.34, c.strip ? 36 : 96)
            case .rise:
                return rolling(c.H - y, t, 2.6, c.H, 80)
            case .circuit:
                return circuit(x, y)
            case .orbit:
                let dx = x - c.cx
                let dy = y - c.cy
                let d = (dx * dx + dy * dy).squareRoot()
                let a = atan2(dy, dx) - tau * t / 2.6
                let off = ((a + .pi).truncatingRemainder(dividingBy: tau) + tau).truncatingRemainder(dividingBy: tau) - .pi
                let beam = exp(-pow(off / 0.38, 2)) + (off < 0 ? 0.45 * exp(off / 0.9) : 0)
                return 0.02 + 0.26 * beam * smooth(16, 110, d) * (0.6 + 0.4 * exp(-d / 500))
            case .caustics:
                let a = sin(x * 0.021 + y * 0.012 + t * 1.1) + sin(-x * 0.015 + y * 0.019 - t * 0.85)
                    + sin(x * 0.006 - y * 0.024 + t * 0.66 + 1.7)
                return 0.28 * smooth(0.8, 2.6, a)
            case .hold:
                let b = 0.5 - 0.5 * cos(tau * t / 4.2)
                return (0.06 + 0.2 * b) * exp(-(c.H - y) / 110) * (0.7 + 0.3 * exp(-pow((x - c.cx) / 260, 2)))
            case .cursor:
                let b = 0.5 + 0.5 * cos(tau * t / 2.2)
                let half = c.strip ? c.H / 2 - c.P : 16
                let dx = max(abs(x - (c.caret?.x ?? c.cx)) - 4, 0) / 6
                let dy = max(abs(y - (c.caret?.y ?? c.cy)) - half, 0) / 6
                return 0.32 * b * b * exp(-(dx * dx + dy * dy))
            default:
                return 0
            }
        case let .wander(fx, fy, v):
            return 0.03 + v * exp(-(pow(x - fx, 2) + pow(y - fy, 2)) / (2 * 84 * 84))
        case let .glimmer(pools):
            var v = 0.0
            for g in pools { v += g.v * exp(-(pow(x - g.x, 2) + pow(y - g.y, 2)) / (2 * 72 * 72)) }
            return 0.25 * v
        case let .lava(nearBlobs, farBlobs):
            // A bounded kernel: a body's light peaks at its middle at its own strength, so a fading
            // body dims instead of collapsing to a bright point; overlapping bodies add up and merge.
            func field(_ blobs: [MotionPrep.Blob]) -> Double {
                var f = 0.0
                for b in blobs {
                    let dx = (x - b.x) / b.sx
                    let dy = (y - b.y) * b.sx
                    let q = (dx * dx + dy * dy) / b.R2
                    if q < 1 { f += b.a * (1 - q) * (1 - q) }
                }
                return f
            }
            let near = field(nearBlobs)
            let far = field(farBlobs)
            return 0.28 * smooth(0.25, 1, near) + 0.06 * smooth(0.05, 0.35, near) + 0.08 * smooth(0.1, 0.6, far)
        case let .fill(lap, on, off):
            let n = x * 0.731 + y * 1.379
            let lit = clamp01((on * 1.08 - hash(n + lap * 3.17)) / 0.08)
            let out = clamp01((off * 1.08 - hash(n * 1.7 + lap * 5.31 + 9.1)) / 0.08)
            return 0.02 + 0.26 * lit * (1 - out)
        case let .terminal(st):
            return st.value(x, y, t, c)
        case let .page(page):
            return page.value(x, y)
        case let .flow(ax, ay, bx, by, amp):
            let p = -(x * ax + y * ay)
            let q = -(x * bx + y * by)
            let w1 = 0.5 + 0.5 * sin((p + 40 * sin(x / 150 + t * 0.5)) / 95 + t * 1.6)
            let w2 = 0.5 + 0.5 * sin(q / 70 + t * 1.15 + 0.8 * sin(y / 130 - t * 0.4))
            return 0.03 + amp * (0.15 * w1 * w1 + 0.08 * w2 * w2 * w2)
        }
    }
}

extension MotionFrame {
    /// The light running round the edges. Its head moves along the edge at a steady pace (top
    /// left to right, then down the right, and so on). Each edge lights the cells inside it by how
    /// far they are from the head along the edge and how deep in they are: deeper, the light
    /// spreads wider and fades. The brightest edge wins at each cell, so corners join smoothly.
    ///
    /// On the strip one light would read as a bar sliding to and fro along its long sides; three
    /// run round a third of the way apart, shorter and reaching a row deeper, so they are seen
    /// going round.
    @inline(__always) fileprivate func circuit(_ x: Double, _ y: Double) -> Double {
        let W = c.W
        let H = c.H
        let round = 2 * (W + H)
        let lap = c.strip ? round / 3 : round
        let head = (W / 2 + round * t / 3).truncatingRemainder(dividingBy: round)
        let sigma0 = (c.strip ? 0.035 : 0.05) * round
        let depth = c.strip ? 0.5 * H : 0.12 * min(W, H)
        let spread = c.strip ? 0.5 : 1.2
        let strength = c.strip ? 0.6 : 0.44
        let wake = 0.25 * lap
        /// One edge's light at depth `d` and `s` along the way round.
        func edge(_ d: Double, _ s: Double) -> Double {
            var off = (s - head).truncatingRemainder(dividingBy: lap)
            if off > lap / 2 { off -= lap } else if off < -lap / 2 { off += lap }
            let sigma = sigma0 + spread * d
            let along = exp(-0.5 * (off / sigma) * (off / sigma)) + (off < 0 ? 0.55 * exp(off / wake) : 0)
            return along * (sigma0 / sigma) * exp(-d / depth)
        }
        let light = max(
            max(edge(y, x), edge(W - x, W + y)),
            max(edge(H - y, W + H + (W - x)), edge(x, 2 * W + H + (H - y)))
        )
        let rim = min(x, W - x, y, H - y)
        return 0.02 + strength * light + 0.05 * exp(-rim / 20)
    }
}

// MARK: - The terminal

/// The terminal's lines, as a shell session prints them: a command typed at a pace of its own, a
/// moment while it runs, then its output in bursts (most lines right after the one before, now and
/// then a pause), indented like code that steps in and out, short lines and long ones. Each line
/// starts when the one before is done, so the tape keeps what it has written and only adds lines
/// as time goes on; every line follows from its number.
final class TerminalTape {
    struct Line {
        let k: Int
        /// When it starts, and how long it takes to appear: a command is typed, output shows at once.
        let at: Double
        let dur: Double
        /// The pause after it, before the next line starts.
        let gap: Double
        /// Indent steps (output only), then the indent and the length in points.
        let level: Int
        let indent: Double
        let len: Double
        let command: Bool

        var end: Double { at + dur + gap }
    }

    /// The space at either side of the board, and one indent step.
    static let margin = 24.0
    static let step = 20.0
    static let maxLevel = 4
    /// How long a new line takes to scroll the tape up by one.
    static let scrollTime = 0.12

    private var lines: [Line] = []
    private var width = -1.0
    private var lastT = 0.0

    func frame(_ t: Double, _ c: BoardGeometry) -> TerminalFrame {
        if c.W != width || t < lastT {
            lines = []
            width = c.W
        }
        lastT = t
        while lines.isEmpty || lines[lines.count - 1].end <= t {
            lines.append(Self.line(after: lines.last, width: c.W))
            if lines.count > 64 { lines.removeFirst(lines.count - 64) }
        }
        // On the strip every row is a line, with no margin above or below.
        let lineH = c.strip ? c.P : 2 * c.P
        let top = c.strip ? c.P / 2 : max(64, c.P * 2.5)
        let visible = c.strip ? max(1, floor(c.H / lineH)) : max(3, floor((c.H - 2 * top) / lineH))
        // Each line scrolls the tape up by one over `scrollTime` from its start, so lines that come
        // quickly scroll it smoothly together. Lines before the kept ones have long finished.
        let scrolled = Double(lines[0].k) + lines.reduce(0) { $0 + smooth(0, Self.scrollTime, t - $1.at) }
        return TerminalFrame(lines: lines, lineH: lineH, top: top, offset: max(0, scrolled - visible) * lineH, strip: c.strip)
    }

    /// The line after `previous` on a board `W` points wide.
    static func line(after previous: Line?, width W: Double) -> Line {
        let k = (previous?.k ?? -1) + 1
        let at = previous?.end ?? 0
        // Independent draws for this line.
        let r = { (i: Double) in hash(Double(k) * 7.13 + i * 3.71) }
        let usable = W - 2 * margin
        let command = k == 0 || r(0) < (previous?.command == true ? 0.08 : 0.14)
        if command {
            let len = (0.12 + 0.4 * r(1)) * usable
            // Typed at 420–1120 points a second, then it runs a moment before its output.
            return Line(k: k, at: at, dur: len / (420 + 700 * r(2)), gap: 0.08 + 0.3 * r(3),
                        level: 0, indent: margin, len: len, command: true)
        }
        // Output steps in and out like code that nests: after a command at the margin or a step or
        // two in, then the same depth, a step in (a little likelier) or out, now and then back to
        // the margin.
        let walk = r(4)
        let level: Int
        if let previous, !previous.command {
            let depth = walk < 0.04 ? 0 : walk < 0.4 ? previous.level + 1 : walk < 0.6 ? previous.level - 1 : previous.level
            level = min(maxLevel, max(0, depth))
        } else {
            level = walk < 0.5 ? 0 : walk < 0.8 ? 1 : 2
        }
        let indent = margin + step * Double(level)
        let room = W - margin - indent
        let size = r(5)
        let share = size < 0.12 ? 0.04 + 0.1 * r(6) : size < 0.82 ? 0.2 + 0.55 * r(6) : 0.75 + 0.2 * r(6)
        // Mostly right after the line before; sometimes a short wait, rarely a longer one.
        let wait = r(8)
        let gap = wait < 0.75 ? 0.01 + 0.04 * r(9) : wait < 0.95 ? 0.08 + 0.12 * r(9) : 0.3 + 0.3 * r(9)
        return Line(k: k, at: at, dur: 0.02 + 0.06 * r(7), gap: gap,
                    level: level, indent: indent, len: max(10, share * room), command: false)
    }
}

struct TerminalFrame {
    let lines: [TerminalTape.Line]
    let lineH: Double
    let top: Double
    let offset: Double
    /// A row a line: lines one cell tall, nothing faded at the top and bottom.
    let strip: Bool

    @inline(__always) func value(_ x: Double, _ y: Double, _ t: Double, _ c: BoardGeometry) -> Double {
        let row = (y - top + offset) / lineH
        let k = Int(row.rounded())
        var v = 0.02
        guard let first = lines.first, k >= first.k, k - first.k < lines.count else { return v }
        let line = lines[k - first.k]
        // Soft lines: a core one cell tall with light spilling to the rows beside it, ends that fade.
        let dy = (row - Double(k)) * lineH
        let vert = strip
            ? exp(-(dy * dy) / (2 * pow(0.35 * c.P, 2)))
            : exp(-(dy * dy) / (2 * pow(0.5 * c.P, 2))) + 0.25 * exp(-(dy * dy) / (2 * pow(1.2 * c.P, 2)))
        let typed = min(line.len, (t - line.at) / line.dur * line.len)
        let x1 = line.indent + typed
        let horiz = smooth(line.indent - 14, line.indent + 14, x) * (1 - smooth(x1 - 18, x1 + 10, x))
        let edge = strip ? 1 : smooth(top - lineH, top + lineH, y) * (1 - smooth(c.H - top - lineH, c.H - top + lineH, y))
        v += vert * edge * horiz * (line.command ? 0.24 : 0.14)
        if line.k == lines[lines.count - 1].k, line.command {
            let blink = 0.5 + 0.5 * cos(tau * t * 1.6)
            v += vert * edge * 0.26 * blink * exp(-pow((x - x1 - 8) / 9, 2))
        }
        return v
    }
}

// MARK: - The page

/// The page motion at one moment: which cells of this page's lines are lit, how far each line has
/// lit up, and where the sweeping band is.
///
/// A page is a column of lines three cells apart, each line words of 2–6 cells with a cell between
/// them, starting two cells in; most lines run most of the way across, a paragraph ends on a
/// shorter line and an empty one. Each page is laid out afresh from its number. On the strip the
/// page is its two middle rows, one line each.
struct PageFrame {
    static let period = 3.8
    /// The lines light up over this long, the top line first.
    private static let appear = 1.4
    /// Then the page holds, then the band sweeps it away.
    private static let sweepAt = 2.0
    private static let sweepTime = 1.8
    private static let lineEvery = 3
    private static let lead = 26.0
    private static let trail = 80.0

    private let P: Double
    private let columns: Int
    private let top: Int
    private let lines: Int
    private let every: Int
    /// Lit cells, line by line (`lines` × `columns`).
    private let lit: [Bool]
    /// How far each line has lit up (0–1).
    private let shown: [Double]
    /// The band's crest (y), while it sweeps.
    private let crest: Double?

    init(_ t: Double, _ c: BoardGeometry) {
        P = c.P
        columns = max(1, Int(c.W / c.P))
        let rows = Int(c.H / c.P)
        if c.strip {
            top = 1
            every = 1
            lines = max(1, rows - 2)
        } else {
            top = 2
            every = Self.lineEvery
            lines = max(0, (rows - top - 2 + every - 1) / every)
        }
        let page = floor(t / Self.period)
        let p = t - page * Self.period

        var lit = Array(repeating: false, count: lines * columns)
        let margin = 2
        let room = max(4, columns - 2 * margin)
        var blank = false
        for i in 0..<lines {
            let n = page * 97.3 + Double(i) * 7.9
            // A paragraph's last line is followed by an empty one.
            if blank {
                blank = false
                continue
            }
            let ends = hash(n + 0.5) < 0.2 && i > 0
            let length = Int(Double(room) * (ends ? 0.25 + 0.35 * hash(n + 1.7) : 0.72 + 0.28 * hash(n + 2.9)))
            blank = ends
            var col = margin
            var w = 0.0
            while col < margin + length {
                let word = 2 + Int(5 * hash(n + 11.3 + w * 3.1))
                for k in col..<min(col + word, margin + length) { lit[i * columns + k] = true }
                col += word + 1
                w += 1
            }
        }
        self.lit = lit
        // A short fade for each line, one after the other down the page.
        let stagger = lines > 1 ? (Self.appear - 0.7) / Double(lines - 1) : 0
        shown = (0..<lines).map { i in smooth(Double(i) * stagger, Double(i) * stagger + 0.7, p) }
        if p >= Self.sweepAt {
            let q = min(1, (p - Self.sweepAt) / Self.sweepTime)
            let from = -3 * Self.lead
            let to = c.H + 3 * Self.trail
            crest = from + (to - from) * q
        } else {
            crest = nil
        }
    }

    @inline(__always) func value(_ x: Double, _ y: Double) -> Double {
        var v = 0.02
        var erased = 1.0
        if let crest {
            let d = y - crest
            // Ahead of the crest the band fades quickly; behind it, slowly, with a faint wake.
            let band = d > 0
                ? exp(-0.5 * (d / Self.lead) * (d / Self.lead))
                : exp(-0.5 * (d / Self.trail) * (d / Self.trail)) + 0.25 * exp(d / (3 * Self.trail))
            v += 0.27 * band
            // Lines go out as the crest passes over them.
            erased = smooth(crest - 18, crest + 4, y)
        }
        let row = Int(y / P) - top
        guard row >= 0, row % every == 0 else { return v }
        let i = row / every
        let col = Int(x / P)
        guard i < lines, col >= 0, col < columns, lit[i * columns + col] else { return v }
        return v + 0.13 * shown[i] * erased
    }
}

// MARK: - The starfield

/// The tunnel's speed (z per second) t seconds after thinking turned deep (2.5 s into thinking):
/// the stars get going over a second to the slow tunnel's pace, keep it until 5 s into thinking,
/// then gather pace over 40 s.
private let warpS1 = 0.85
/// When the tunnel starts gathering pace, in seconds after it began.
private let warpPick = 2.5
private let warpGather = 40.0

/// The slow tunnel's steady speed (z per second), also the pace thinking drifts at first.
let tunnelSpeed = 0.07

func warpSpeed(_ t: Double) -> Double {
    tunnelSpeed * smooth(0, 1, t) + (warpS1 - tunnelSpeed) * smooth(warpPick, warpPick + warpGather, t)
}

/// How far the stars have travelled (z) by t: the integral of `warpSpeed`.
func warpTravel(_ t: Double) -> Double {
    /// ∫ smooth(a, a + w, u) du from a to t.
    func rise(_ t: Double, from a: Double, over w: Double) -> Double {
        let x = min(max((t - a) / w, 0), 1)
        return w * (x * x * x - x * x * x * x / 2) + max(0, t - a - w)
    }
    return tunnelSpeed * rise(t, from: 0, over: 1) + (warpS1 - tunnelSpeed) * rise(t, from: warpPick, over: warpGather)
}

/// How many more stars the tunnel has gathered (0–1) by t.
func warpDensity(_ t: Double) -> Double { smooth(warpPick, warpPick + warpGather, t) }
