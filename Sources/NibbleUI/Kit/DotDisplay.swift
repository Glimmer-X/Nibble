import SwiftUI

/// Numbers and small charts as dot displays: the same square dots as the send key's 5 × 5
/// display, each glyph or column a block of dots whose unlit ones stay faintly visible.

/// A 5 × 7 dot face for figures: digits, a point, a comma, k and m for thousands and millions.
enum DotFace {
    static let height = 7

    private static let glyphs: [Character: [String]] = [
        "0": [".###.", "#...#", "#...#", "#...#", "#...#", "#...#", ".###."],
        "1": ["..#..", ".##..", "..#..", "..#..", "..#..", "..#..", ".###."],
        "2": [".###.", "#...#", "....#", "...#.", "..#..", ".#...", "#####"],
        "3": [".###.", "#...#", "....#", "..##.", "....#", "#...#", ".###."],
        "4": ["...#.", "..##.", ".#.#.", "#..#.", "#####", "...#.", "...#."],
        "5": ["#####", "#....", "####.", "....#", "....#", "#...#", ".###."],
        "6": ["..##.", ".#...", "#....", "####.", "#...#", "#...#", ".###."],
        "7": ["#####", "....#", "...#.", "..#..", ".#...", ".#...", ".#..."],
        "8": [".###.", "#...#", "#...#", ".###.", "#...#", "#...#", ".###."],
        "9": [".###.", "#...#", "#...#", ".####", "....#", "...#.", ".##.."],
        ".": [".", ".", ".", ".", ".", ".", "#"],
        ",": [".", ".", ".", ".", ".", "#", "#"],
        ":": [".", ".", "#", ".", "#", ".", "."],
        "-": ["....", "....", "....", "####", "....", "....", "...."],
        "k": ["#...", "#...", "#..#", "#.#.", "##..", "#.#.", "#..#"],
        "m": [".....", ".....", "##.#.", "#.#.#", "#.#.#", "#.#.#", "#.#.#"],
        " ": ["..", "..", "..", "..", "..", "..", ".."],
    ]

    static func glyph(_ c: Character) -> [String] { glyphs[c] ?? glyphs["-"]! }

    /// Lit dots of `text` laid out in columns, with one dark column between glyphs: (column, row)
    /// pairs, the total width in columns, and every dot of each glyph's box (lit or not).
    static func layout(_ text: String) -> (lit: [(Int, Int)], all: [(Int, Int)], columns: Int) {
        var lit: [(Int, Int)] = []
        var all: [(Int, Int)] = []
        var x = 0
        for (i, c) in text.enumerated() {
            if i > 0 { x += 1 }
            let rows = glyph(c)
            let width = rows[0].count
            for (y, row) in rows.enumerated() {
                for (dx, ch) in row.enumerated() {
                    all.append((x + dx, y))
                    if ch == "#" { lit.append((x + dx, y)) }
                }
            }
            x += width
        }
        return (lit, all, x)
    }

    /// A count as a figure of a few glyphs: 842, 18.4k, 1.2m.
    static func compact(_ n: Int) -> String {
        switch n {
        case ..<1_000: "\(n)"
        case ..<10_000: String(format: "%.1fk", Double(n) / 1_000).replacingOccurrences(of: ".0k", with: "k")
        case ..<1_000_000: "\(Int((Double(n) / 1_000).rounded()))k"
        default: String(format: "%.1fm", Double(n) / 1_000_000).replacingOccurrences(of: ".0m", with: "m")
        }
    }

    /// A measurement with one decimal below ten and none above: 3.2, 46.
    static func measure(_ x: Double?) -> String {
        guard let x, x.isFinite else { return "-" }
        return x < 10 ? String(format: "%.1f", x) : "\(Int(x.rounded()))"
    }
}

/// A figure drawn in dots (see `DotFace`), in the current foreground colour.
struct DotFigure: View {
    let text: String
    var pitch: CGFloat = 4
    var dot: CGFloat = 3
    /// How visible the unlit dots of each glyph are.
    var ghost: Double = 0.1

    var body: some View {
        let layout = DotFace.layout(text)
        let width = CGFloat(layout.columns) * pitch - (pitch - dot)
        let height = CGFloat(DotFace.height) * pitch - (pitch - dot)
        Canvas { context, _ in
            if ghost > 0 {
                var faint = Path()
                for (x, y) in layout.all { faint.addRect(CGRect(x: CGFloat(x) * pitch, y: CGFloat(y) * pitch, width: dot, height: dot)) }
                context.opacity = ghost
                context.fill(faint, with: .foreground)
                context.opacity = 1
            }
            var path = Path()
            for (x, y) in layout.lit { path.addRect(CGRect(x: CGFloat(x) * pitch, y: CGFloat(y) * pitch, width: dot, height: dot)) }
            context.fill(path, with: .foreground)
        }
        .frame(width: max(0, width), height: height)
        .accessibilityLabel(text)
    }
}

/// A bar chart as a dot display: one column of dots per value, lit from the bottom in proportion
/// to the largest value; the unlit dots stay faint so the display keeps its shape when empty.
struct DotBars: View {
    let values: [Double]
    /// Columns drawn in the stronger colour (today, say), by index.
    var marked: Set<Int> = []
    /// Columns that stand for a failure: one rose dot at the bottom.
    var failed: Set<Int> = []
    var rows = 10
    /// Dots across each bar, and dark dots between bars.
    var barWidth = 3
    var gap = 1
    var pitch: CGFloat = 4
    var dot: CGFloat = 3
    let colors: PanelColors
    /// The bar under the pointer, reported as the pointer moves.
    var onHover: ((Int?) -> Void)?

    var body: some View {
        let columns = values.count * (barWidth + gap) - gap
        let width = CGFloat(max(0, columns)) * pitch - (pitch - dot)
        let height = CGFloat(rows) * pitch - (pitch - dot)
        let top = max(values.max() ?? 0, 1e-9)
        Canvas { context, _ in
            var faint = Path()
            var lit = Path()
            var strong = Path()
            var rose = Path()
            for (i, value) in values.enumerated() {
                let count = value > 0 ? max(1, Int((value / top * Double(rows)).rounded())) : 0
                for b in 0..<barWidth {
                    let x = CGFloat(i * (barWidth + gap) + b) * pitch
                    for r in 0..<rows {
                        let y = CGFloat(rows - 1 - r) * pitch
                        let rect = CGRect(x: x, y: y, width: dot, height: dot)
                        if failed.contains(i), r == 0 {
                            rose.addRect(rect)
                        } else if r < count {
                            if marked.contains(i) { strong.addRect(rect) } else { lit.addRect(rect) }
                        } else {
                            faint.addRect(rect)
                        }
                    }
                }
            }
            context.fill(faint, with: .color(colors.ink.opacity(0.09)))
            context.fill(lit, with: .color(colors.accent.opacity(0.85)))
            context.fill(strong, with: .color(colors.pink))
            context.fill(rose, with: .color(colors.rose))
        }
        .frame(width: max(0, width), height: height)
        .contentShape(Rectangle())
        .onContinuousHover { phase in
            guard let onHover else { return }
            switch phase {
            case .active(let point):
                let i = Int(point.x / (CGFloat(barWidth + gap) * pitch))
                onHover(values.indices.contains(i) ? i : nil)
            case .ended:
                onHover(nil)
            }
        }
    }
}
