import SwiftUI

/// Icons: dot-matrix pictures, like the board itself in miniature ('#' is a lit dot).
///
/// Keys carry large dots: 3 pt on a 4 pt pitch, the same dots as the send key's display. The
/// composer's capture key and the menu bar panel's keys are 5 × 5 pictures; the panel's header
/// keys (new chat, this chat, collapse, close, back) and the strip's are 3 × 3, so they stay light. Small marks inside
/// lines of text (a chevron, a tick, a cross on a chip) are 2 pt dots on a 3 pt pitch.
enum DotIcon: String, CaseIterable {
    // Large dots: keys.
    case capture, plus, bubble, window, power
    // Large dots, 3 × 3: the panel's header and its strip.
    case add, menu, close, back, collapse, expand
    // Small: marks in text.
    case check, cross, chevron, search, next, previous

    var rows: [String] {
        switch self {
        case .capture: ["##.##", "#...#", ".....", "#...#", "##.##"]
        case .plus: ["..#..", "..#..", "#####", "..#..", "..#.."]
        case .add: [".#.", "###", ".#."]
        case .menu: ["###", "...", "###"]
        case .close: ["#.#", ".#.", "#.#"]
        case .back: [".#", "#.", ".#"]
        // A block gone into the corner, and back out of it.
        case .collapse: ["#..", ".##", ".##"]
        case .expand: ["##.", "##.", "..#"]
        case .bubble: ["#####", "#...#", "#...#", "#####", "#...."]
        case .window: ["#####", "#####", "#...#", "#...#", "#####"]
        case .power: ["..#..", "#.#.#", "#...#", "#...#", ".###."]
        case .check: ["......#", ".....#.", "#...#..", ".#.#...", "..#...."]
        case .cross: ["#...#", ".#.#.", "..#..", ".#.#.", "#...#"]
        case .chevron: ["#...#", ".#.#.", "..#.."]
        case .search: ["###..", "#.#..", "###..", "...#.", "....#"]
        case .next: ["#..", ".#.", "..#", ".#.", "#.."]
        case .previous: ["..#", ".#.", "#..", ".#.", "..#"]
        }
    }

    var isLarge: Bool {
        switch self {
        case .capture, .plus, .bubble, .window, .power, .add, .menu, .close, .back, .collapse, .expand: true
        case .check, .cross, .chevron, .search, .next, .previous: false
        }
    }

    var pitch: CGFloat { isLarge ? 4 : 3 }
    var dot: CGFloat { isLarge ? 3 : 2 }

    var size: CGSize {
        let r = rows
        return CGSize(
            width: CGFloat(r[0].count) * pitch - (pitch - dot),
            height: CGFloat(r.count) * pitch - (pitch - dot)
        )
    }

    var path: Path {
        var path = Path()
        for (y, row) in rows.enumerated() {
            for (x, ch) in row.enumerated() where ch == "#" {
                path.addRect(CGRect(x: CGFloat(x) * pitch, y: CGFloat(y) * pitch, width: dot, height: dot))
            }
        }
        return path
    }
}

/// A dot-matrix icon in the current foreground colour.
struct DotIconView: View {
    let icon: DotIcon

    var body: some View {
        let size = icon.size
        Canvas { context, _ in
            context.fill(icon.path, with: .foreground)
        }
        .frame(width: size.width, height: size.height)
        .accessibilityHidden(true)
    }
}

// MARK: - Nibble's mark

/// Nibble's mark, the app icon in miniature: a round spot of light high on the right and a small
/// one low on the left, close together ('#' a dot, '+' a half-lit dot). It sits in the menu bar
/// and at the top of the main window's sidebar; the app icon (App/AppIcon.icon) is the same picture.
struct NibbleMark: View {
    var pitch: CGFloat = 3
    var dot: CGFloat = 2

    static let rows = ["..+##+", "..####", "..####", "..+##+", "##....", "##...."]
    static let halfLit = 0.45

    /// Every dot's rectangle and how lit it is (1 or `halfLit`).
    static func dots(pitch: CGFloat, dot: CGFloat, origin: CGPoint = .zero) -> [(rect: CGRect, alpha: Double)] {
        var dots: [(CGRect, Double)] = []
        for (y, row) in rows.enumerated() {
            for (x, ch) in row.enumerated() where ch != "." {
                let rect = CGRect(x: origin.x + CGFloat(x) * pitch, y: origin.y + CGFloat(y) * pitch, width: dot, height: dot)
                dots.append((rect, ch == "#" ? 1 : halfLit))
            }
        }
        return dots
    }

    static func side(pitch: CGFloat, dot: CGFloat) -> CGFloat {
        CGFloat(rows.count) * pitch - (pitch - dot)
    }

    var body: some View {
        let side = Self.side(pitch: pitch, dot: dot)
        Canvas { context, _ in
            for (rect, alpha) in Self.dots(pitch: pitch, dot: dot) {
                context.opacity = alpha
                context.fill(Path(rect), with: .foreground)
            }
        }
        .frame(width: side, height: side)
        .accessibilityHidden(true)
    }
}

// MARK: - The send key's display

/// The send key is a small 5 × 5 dot display. With something to send it shows the arrow; while the
/// model works on an empty composer it shows what is happening, each state a picture or a short
/// loop; afterwards a tick, or an exclamation mark if the request failed. Each dot is on (1),
/// half-lit (0.5) or dark (it stays faintly visible, like the board's unlit cells).
enum KeyDisplay: Equatable {
    case send, stop, waiting, think, deep, search, read, look, tool, attention, writing, done, error

    private static let pics: [String: [String]] = [
        "send": ["..#..", ".###.", "#.#.#", "..#..", "..#.."],
        "stop": [".....", ".###.", ".###.", ".###.", "....."],
        "ask": [".###.", "#...#", "..##.", ".....", "..#.."],
        "bang": ["..#..", "..#..", "..#..", ".....", "..#.."],
        "glass": ["###.", "#.#.", "###.", "...#"],
        "book": ["##.##", "##.##", "##.##"],
        "picture": ["#####", "#...#", "#..##", "#.###", "#####"],
    ]
    /// The tick's dots in the order a pen would draw them.
    private static let tick = [(0, 3), (1, 4), (2, 3), (3, 2), (4, 1)]
    /// The display's outer ring (16 dots, clockwise from the top left) and its inner one (8 dots).
    private static let outer: [(Int, Int)] = (0...4).map { ($0, 0) } + (1...4).map { (4, $0) } + [3, 2, 1, 0].map { ($0, 4) } + [3, 2, 1].map { (0, $0) }
    private static let inner = [(1, 1), (2, 1), (3, 1), (3, 2), (3, 3), (2, 3), (1, 3), (1, 2)]

    private static func lineHash(_ n: Double) -> Double {
        let v = sin(n * 91.3 + 7.1) * 43758.5453
        return v - floor(v)
    }

    /// The 25 dots (row by row) `t` seconds after this picture began.
    func frame(_ t: Double) -> [Double] {
        var dots = [Double](repeating: 0, count: 25)
        func put(_ x: Int, _ y: Int, _ v: Double = 1) {
            guard (0..<5).contains(x), (0..<5).contains(y) else { return }
            dots[y * 5 + x] = max(dots[y * 5 + x], v)
        }
        func draw(_ name: String, _ ox: Int = 0, _ oy: Int = 0, _ v: Double = 1) {
            for (y, row) in (Self.pics[name] ?? []).enumerated() {
                for (x, ch) in row.enumerated() where ch == "#" { put(x + ox, y + oy, v) }
            }
        }
        func step(_ period: Double) -> Int { Int(floor(t / period)) }

        switch self {
        case .waiting:
            // A short bar slides left and right along the middle row.
            let x = [0, 1, 2, 3, 2, 1][step(0.13) % 6]
            put(x, 2)
            put(x + 1, 2)
        case .think:
            // One light runs round the edge.
            let i = step(0.07) % 16
            put(Self.outer[i].0, Self.outer[i].1)
            put(Self.outer[(i + 15) % 16].0, Self.outer[(i + 15) % 16].1, 0.5)
        case .deep:
            // Two lights: one round the edge, one the other way round the inner ring.
            let i = step(0.06) % 16
            let j = step(0.09) % 8
            put(Self.outer[i].0, Self.outer[i].1)
            put(Self.outer[(i + 15) % 16].0, Self.outer[(i + 15) % 16].1, 0.5)
            put(Self.inner[(8 - j) % 8].0, Self.inner[(8 - j) % 8].1)
            put(Self.inner[(9 - j) % 8].0, Self.inner[(9 - j) % 8].1, 0.5)
        case .search:
            // A magnifier circling a little, as if looking about.
            let offsets = [(0, 0), (1, 0), (1, 1), (0, 1)]
            let o = offsets[step(0.22) % 4]
            draw("glass", o.0, o.1)
        case .read:
            // An open book bobbing gently.
            draw("book", 0, step(0.45) % 2 == 1 ? 2 : 1)
        case .look:
            // A picture, scanned by a row of its dots going out, top to bottom.
            draw("picture")
            let r = step(0.14) % 7
            if r < 5 { for x in 0..<5 { dots[r * 5 + x] = 0 } }
        case .tool:
            // Lines of code of different lengths and indents, scrolling up.
            let s0 = step(0.28)
            for y in 0..<5 {
                let k = Double(s0 + y)
                let indent = Self.lineHash(k) < 0.3 ? 1 : 0
                let len = min(5 - indent, 2 + Int(floor(Self.lineHash(k * 1.7) * 3)))
                for x in 0..<len { put(indent + x, y, y == 4 ? 0.5 : 1) }
            }
        case .attention:
            draw("ask", 0, 0, t.truncatingRemainder(dividingBy: 2.2) < 1.5 ? 1 : 0.5)
        case .writing:
            // Layers of light rising, one after another.
            let s0 = step(0.12)
            for y in 0..<5 {
                let k = (y + s0) % 3
                for x in 0..<5 where k < 2 { put(x, y, k == 0 ? 1 : 0.5) }
            }
        case .done:
            // The tick draws itself.
            for (i, p) in Self.tick.enumerated() where t > Double(i) * 0.06 { put(p.0, p.1) }
        case .error:
            draw("bang")
        case .stop:
            draw("stop")
        case .send:
            draw("send")
        }
        return dots
    }
}

/// The 5 × 5 display: 3 pt dots on a 4 pt pitch, dark dots faintly visible. The panel's frame
/// loop works out the dots, so the key redraws only when one of them changes.
struct KeyDisplayView: View {
    /// 25 values, row by row: 1 on, 0.5 half-lit, 0 dark.
    let dots: [Double]

    var body: some View {
        Canvas { context, _ in
            for i in 0..<min(25, dots.count) {
                context.opacity = dots[i] >= 1 ? 1 : dots[i] > 0 ? 0.6 : 0.22
                context.fill(Path(CGRect(x: CGFloat(i % 5) * 4, y: CGFloat(i / 5) * 4, width: 3, height: 3)), with: .foreground)
            }
        }
        .frame(width: 19, height: 19)
        .accessibilityHidden(true)
    }
}
