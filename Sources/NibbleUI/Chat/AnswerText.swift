import AppKit
import SwiftUI

/// An answer laid out as one piece of text for `AnswerTextView`, so a drag selects across its
/// paragraphs, headings, lists, tables and code, and ⌘A takes all of it. Only an image breaks the
/// text: each run of text between images is one text view.
///
/// The look is the answer's own: every line on the 24 pt rhythm, 8 pt between blocks, list markers
/// in a 32 pt column (numbers in the pixel face, a 4 pt square for bullets), tables with headers in
/// the pixel face, code tinted and set in by 16 pt. Code wraps, its further lines set in by 16 pt
/// more.
@MainActor
enum AnswerLayout {
    enum Piece {
        case text(NSAttributedString)
        case image(URL, quoted: Bool)
    }

    /// The answer's colours.
    struct Ink {
        var ink: NSColor
        var ink2: NSColor
        var ink3: NSColor
        var code: NSColor
        var accent: NSColor

        init(_ colors: PanelColors) {
            ink = NSColor(colors.ink)
            ink2 = NSColor(colors.ink2)
            ink3 = NSColor(colors.ink3)
            code = NSColor(colors.code)
            accent = NSColor(colors.accent)
        }
    }

    static func pieces(of document: MarkdownDocument, ink: Ink) -> [Piece] {
        var pieces: [Piece] = []
        var text = NSMutableAttributedString()
        func flush() {
            // The last paragraph needs no break after it.
            if text.length > 0 {
                text.deleteCharacters(in: NSRange(location: text.length - 1, length: 1))
                pieces.append(.text(text))
            }
            text = NSMutableAttributedString()
        }
        var blocks = document.blocks
        // A rule at the end separates nothing.
        while let last = blocks.last, last.kind == .rule { blocks.removeLast() }
        for block in blocks {
            if case .image(let url) = block.kind {
                flush()
                pieces.append(.image(url, quoted: block.quoted))
                continue
            }
            append(block, to: text, first: text.length == 0, ink: ink)
        }
        flush()
        return pieces
    }

    // MARK: - Blocks

    private static func append(_ block: MarkdownDocument.Block, to text: NSMutableAttributedString, first: Bool, ink: Ink) {
        let indent: CGFloat = block.quoted ? 16 : 0
        let colour = block.quoted ? ink.ink2 : ink.ink
        // The space a block keeps from the one before it.
        let gap: CGFloat = first ? 0 : 8
        switch block.kind {
        case .paragraph:
            let font = NSFont.systemFont(ofSize: Typeface.messageSize)
            let style = rhythm(font, before: gap)
            style.firstLineHeadIndent = indent
            style.headIndent = indent
            text.append(paragraph(styled(block.text, font: font, colour: colour, ink: ink), style: style, font: font))
        case .heading:
            let font = NSFont.systemFont(ofSize: Typeface.headingSize, weight: .semibold)
            // Headings keep 8 pt more above them, the first one too.
            let style = rhythm(font, before: gap + 8)
            style.firstLineHeadIndent = indent
            style.headIndent = indent
            text.append(paragraph(styled(block.text, font: font, colour: colour, ink: ink), style: style, font: font))
        case .item(let marker, let depth):
            let font = NSFont.systemFont(ofSize: Typeface.messageSize)
            let start = indent + CGFloat(depth - 1) * 32
            let style = rhythm(font, before: gap)
            style.headIndent = start + 32
            style.tabStops = [NSTextTab(textAlignment: .left, location: start + 32)]
            let line = NSMutableAttributedString()
            switch marker {
            case .number(let n):
                style.firstLineHeadIndent = start
                line.append(NSAttributedString(string: String(format: "%02d", n), attributes: [.font: pixelFont, .foregroundColor: ink.ink2]))
                line.append(NSAttributedString(string: "\t", attributes: [.font: font]))
            case .bullet:
                // The bullet is a square drawn in place of the character (`AnswerLayoutManager`);
                // the character itself is there for copying.
                style.firstLineHeadIndent = start + 8
                line.append(NSAttributedString(string: "•", attributes: [.font: font, .foregroundColor: NSColor.clear, .answerSquare: ink.ink2]))
                line.append(NSAttributedString(string: "\t", attributes: [.font: font]))
            case .none:
                style.firstLineHeadIndent = start + 32
            }
            line.append(styled(block.text, font: font, colour: colour, ink: ink))
            text.append(paragraph(line, style: style, font: font))
        case .code:
            let font = NSFont.monospacedSystemFont(ofSize: Typeface.codeSize, weight: .regular)
            let lines = String(block.text.characters).trimmingCharacters(in: .newlines).components(separatedBy: "\n")
            for (i, line) in lines.enumerated() {
                let style = rhythm(font, before: i == 0 ? gap : 0)
                style.firstLineHeadIndent = indent + 16
                style.headIndent = indent + 32
                text.append(paragraph(NSAttributedString(string: line, attributes: [.font: font, .foregroundColor: ink.code]), style: style, font: font))
            }
        case .table(let header, let rows):
            text.append(table(header: header, rows: rows, gap: gap, indent: indent, colour: colour, ink: ink))
        case .rule:
            // One empty line 17 pt tall with the rule drawn across its middle (`AnswerLayoutManager`).
            let style = NSMutableParagraphStyle()
            style.paragraphSpacingBefore = gap
            style.minimumLineHeight = 17
            style.maximumLineHeight = 17
            style.firstLineHeadIndent = indent
            style.headIndent = indent
            text.append(NSAttributedString(string: "\n", attributes: [.font: NSFont.systemFont(ofSize: 1), .paragraphStyle: style, .answerRule: ink.ink3]))
        case .image:
            break
        }
    }

    /// The table's cells, row by row, as cells of one `AnswerTable`: columns as wide as their
    /// text needs, 16 pt apart (see `AnswerTable.widths`).
    private static func table(header: [AttributedString], rows: [[AttributedString]], gap: CGFloat, indent: CGFloat, colour: NSColor, ink: Ink) -> NSAttributedString {
        let columns = max(header.count, rows.map(\.count).max() ?? 0)
        guard columns > 0 else { return NSAttributedString() }
        let font = NSFont.systemFont(ofSize: Typeface.tableSize)
        var all: [(cells: [AttributedString], header: Bool)] = []
        if !header.isEmpty { all.append((header, true)) }
        all += rows.map { ($0, false) }
        // Each column's widest cell on one line.
        var natural = [CGFloat](repeating: 0, count: columns)
        for row in all {
            for (c, content) in row.cells.enumerated() {
                let face = row.header ? pixelFont : font
                natural[c] = max(natural[c], NSAttributedString(string: String(content.characters), attributes: [.font: face]).size().width.rounded(.up) + 1)
            }
        }
        let table = AnswerTable(natural: natural, indent: indent)
        table.numberOfColumns = columns
        table.layoutAlgorithm = .fixedLayoutAlgorithm
        table.hidesEmptyCells = false
        // 8 pt above and below the table, besides the space between blocks.
        table.setWidth(gap + 8, type: .absoluteValueType, for: .margin, edge: .minY)
        table.setWidth(8, type: .absoluteValueType, for: .margin, edge: .maxY)
        table.setWidth(indent, type: .absoluteValueType, for: .margin, edge: .minX)

        let out = NSMutableAttributedString()
        for (r, row) in all.enumerated() {
            for c in 0..<columns {
                let cell = NSTextTableBlock(table: table, startingRow: r, rowSpan: 1, startingColumn: c, columnSpan: 1)
                cell.verticalAlignment = .middleAlignment
                cell.setValue(natural[c], type: .absoluteValueType, for: .width)
                if c < columns - 1 { cell.setWidth(16, type: .absoluteValueType, for: .padding, edge: .maxX) }
                let content = c < row.cells.count ? row.cells[c] : AttributedString()
                if row.header {
                    cell.setWidth(4, type: .absoluteValueType, for: .padding, edge: .maxY)
                    let style = NSMutableParagraphStyle()
                    style.textBlocks = [cell]
                    out.append(paragraph(NSAttributedString(string: String(content.characters), attributes: [.font: pixelFont, .foregroundColor: ink.ink2]), style: style, font: pixelFont))
                } else {
                    let style = rhythm(font, before: 0)
                    style.textBlocks = [cell]
                    out.append(paragraph(styled(content, font: font, colour: colour, ink: ink), style: style, font: font))
                }
            }
        }
        return out
    }

    // MARK: - Lines

    private static var pixelFont: NSFont {
        NSFont(name: Typeface.pixelName, size: Typeface.pixelSize) ?? .systemFont(ofSize: Typeface.pixelSize)
    }

    /// A paragraph on the text rhythm: every line `Typeface.line` tall, the glyphs where SwiftUI's
    /// `rhythm()` put them (half the room the face leaves above its line, half below).
    private static func rhythm(_ font: NSFont, before: CGFloat) -> NSMutableParagraphStyle {
        let style = NSMutableParagraphStyle()
        style.minimumLineHeight = Typeface.line
        style.maximumLineHeight = Typeface.line
        style.paragraphSpacingBefore = before
        style.lineBreakMode = .byWordWrapping
        return style
    }

    /// How far a face's glyphs are lifted from where a fixed line height leaves them (the baseline
    /// the face's descent above the line's bottom) to where SwiftUI's `rhythm()` put them: the
    /// room the system face of that size leaves in the line, half above and half below.
    static func lift(_ font: NSFont) -> CGFloat {
        let system = NSFont.systemFont(ofSize: font.pointSize)
        let natural = (system.ascender - system.descender + system.leading).rounded(.up)
        return (Typeface.line + natural) / 2 - (font.ascender - font.descender)
    }

    /// `content` as one paragraph with `style`, its glyphs lifted onto the rhythm, ended by a break.
    private static func paragraph(_ content: NSAttributedString, style: NSParagraphStyle, font: NSFont) -> NSAttributedString {
        let out = NSMutableAttributedString(attributedString: content)
        out.append(NSAttributedString(string: "\n", attributes: [.font: font]))
        let whole = NSRange(location: 0, length: out.length)
        out.addAttribute(.paragraphStyle, value: style, range: whole)
        if style.minimumLineHeight > 0 {
            out.addAttribute(.baselineOffset, value: lift(font), range: whole)
        }
        return out
    }

    /// The block's text in its face and colour, with inline styles: strong, emphasis, code, links
    /// and struck text.
    private static func styled(_ text: AttributedString, font: NSFont, colour: NSColor, ink: Ink) -> NSAttributedString {
        let out = NSMutableAttributedString()
        for run in text.runs {
            var attributes: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: colour]
            if let inline = run.inlinePresentationIntent {
                var face = font
                if inline.contains(.stronglyEmphasized) { face = NSFont.systemFont(ofSize: font.pointSize, weight: .semibold) }
                if inline.contains(.emphasized) { face = NSFontManager.shared.convert(face, toHaveTrait: .italicFontMask) }
                if inline.contains(.code) {
                    face = NSFont.monospacedSystemFont(ofSize: Typeface.codeSize, weight: .regular)
                    attributes[.foregroundColor] = ink.code
                }
                if inline.contains(.strikethrough) { attributes[.strikethroughStyle] = NSUnderlineStyle.single.rawValue }
                attributes[.font] = face
            }
            if let link = run.link {
                attributes[.link] = link
                attributes[.foregroundColor] = ink.accent
                attributes[.underlineStyle] = NSUnderlineStyle.single.rawValue
            }
            out.append(NSAttributedString(string: String(text[run.range].characters), attributes: attributes))
        }
        return out
    }
}

/// A table in an answer. Its columns are as wide as their widest cell on one line; when that is
/// wider than the answer, the narrow columns keep their width and the rest share what is left, their
/// cells wrapping. The widths are set again whenever the answer's width changes (`fit(in:width:)`).
final class AnswerTable: NSTextTable {
    let natural: [CGFloat]
    let indent: CGFloat

    init(natural: [CGFloat], indent: CGFloat) {
        self.natural = natural
        self.indent = indent
        super.init()
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    /// The columns' widths in `available` points, 16 pt between columns.
    static func widths(_ natural: [CGFloat], available: CGFloat) -> [CGFloat] {
        var widths = natural
        var room = available - CGFloat(max(0, natural.count - 1)) * 16
        var open = Array(natural.indices)
        while !open.isEmpty {
            let share = room / CGFloat(open.count)
            let narrow = open.filter { natural[$0] <= share }
            if narrow.isEmpty {
                for c in open { widths[c] = max(24, share.rounded(.down)) }
                break
            }
            for c in narrow { room -= natural[c] }
            open.removeAll { narrow.contains($0) }
        }
        return widths
    }

    /// Sets every table's column widths in `storage` for text `width` wide; says whether any
    /// changed.
    static func fit(in storage: NSTextStorage, width: CGFloat) -> Bool {
        var changed = false
        var widths: [ObjectIdentifier: [CGFloat]] = [:]
        storage.enumerateAttribute(.paragraphStyle, in: NSRange(location: 0, length: storage.length)) { value, _, _ in
            guard let style = value as? NSParagraphStyle else { return }
            for case let cell as NSTextTableBlock in style.textBlocks {
                guard let table = cell.table as? AnswerTable else { continue }
                // A table as wide as the text is laid out about 10 pt narrower, squeezing every
                // column: 12 pt are kept free.
                let columns = widths[ObjectIdentifier(table)] ?? Self.widths(table.natural, available: width - table.indent - 12)
                widths[ObjectIdentifier(table)] = columns
                let w = columns[cell.startingColumn]
                if cell.value(for: .width) != w {
                    cell.setValue(w, type: .absoluteValueType, for: .width)
                    changed = true
                }
            }
        }
        return changed
    }
}

extension NSAttributedString.Key {
    /// A character drawn as a 4 pt square in this colour (a list's bullet).
    static let answerSquare = NSAttributedString.Key("NibbleAnswerSquare")
    /// An empty line drawn as a 1 pt rule across the answer in this colour.
    static let answerRule = NSAttributedString.Key("NibbleAnswerRule")
}

/// Draws what the answer's text marks for drawing: bullets' squares and rules.
final class AnswerLayoutManager: NSLayoutManager {
    override func drawBackground(forGlyphRange glyphs: NSRange, at origin: NSPoint) {
        super.drawBackground(forGlyphRange: glyphs, at: origin)
        guard let storage = textStorage else { return }
        let characters = characterRange(forGlyphRange: glyphs, actualGlyphRange: nil)
        storage.enumerateAttribute(.answerSquare, in: characters) { value, range, _ in
            guard let colour = value as? NSColor else { return }
            let glyph = glyphIndexForCharacter(at: range.location)
            let line = lineFragmentRect(forGlyphAt: glyph, effectiveRange: nil)
            // The glyph's place, the paragraph's lift included.
            let at = location(forGlyphAt: glyph)
            let baseline = (origin.y + line.minY + at.y).rounded()
            colour.setFill()
            // Its top 8 pt above the baseline, like the bullet the answer had.
            NSRect(x: (origin.x + line.minX + at.x).rounded(), y: baseline - 8, width: 4, height: 4).fill()
        }
        storage.enumerateAttribute(.answerRule, in: characters) { value, range, _ in
            guard let colour = value as? NSColor else { return }
            let glyph = glyphIndexForCharacter(at: range.location)
            let line = lineFragmentRect(forGlyphAt: glyph, effectiveRange: nil)
            let indent = (storage.attribute(.paragraphStyle, at: range.location, effectiveRange: nil) as? NSParagraphStyle)?.headIndent ?? 0
            colour.setFill()
            NSRect(x: origin.x + line.minX + indent, y: (origin.y + line.minY + 8).rounded(), width: line.width - indent, height: 1).fill()
        }
    }
}

/// The text view an answer's text is shown in: selectable, never edited, as tall as its text.
final class AnswerTextView: NSTextView {
    static func make() -> AnswerTextView {
        let storage = NSTextStorage()
        let layout = AnswerLayoutManager()
        storage.addLayoutManager(layout)
        let container = NSTextContainer(size: NSSize(width: 100, height: CGFloat.greatestFiniteMagnitude))
        container.lineFragmentPadding = 0
        container.widthTracksTextView = true
        layout.addTextContainer(container)
        let view = AnswerTextView(frame: .zero, textContainer: container)
        view.isEditable = false
        view.isSelectable = true
        view.isRichText = true
        view.drawsBackground = false
        view.textContainerInset = .zero
        view.isVerticallyResizable = false
        view.isHorizontallyResizable = false
        view.usesFontPanel = false
        view.importsGraphics = false
        view.unregisterDraggedTypes()
        return view
    }

    /// Shows `text`, keeping the selection where the text allows (an answer grows as it arrives).
    func show(_ text: NSAttributedString, links: NSColor) {
        linkTextAttributes = [.foregroundColor: links, .underlineStyle: NSUnderlineStyle.single.rawValue, .cursor: NSCursor.pointingHand]
        guard let storage = textStorage, !storage.isEqual(to: text) else { return }
        let selection = selectedRanges
        storage.setAttributedString(text)
        if let width { _ = AnswerTable.fit(in: storage, width: width) }
        let length = storage.length
        let kept = selection.map(\.rangeValue).filter { NSMaxRange($0) <= length }
        if !kept.isEmpty { selectedRanges = kept.map { NSValue(range: $0) } }
    }

    /// The width the text was last laid out at.
    private var width: CGFloat?

    /// The size the text takes `width` wide; with no width, its widest line.
    func fit(width: CGFloat?) -> CGSize {
        guard let layout = layoutManager, let container = textContainer, let storage = textStorage else { return .zero }
        let proposed = width.flatMap { $0.isFinite && $0 > 0 ? $0 : nil }
        container.size = NSSize(width: proposed ?? 100_000, height: CGFloat.greatestFiniteMagnitude)
        if let proposed {
            self.width = proposed
            if AnswerTable.fit(in: storage, width: proposed) {
                layout.invalidateLayout(forCharacterRange: NSRange(location: 0, length: storage.length), actualCharacterRange: nil)
            }
        }
        layout.ensureLayout(for: container)
        let used = layout.usedRect(for: container)
        return CGSize(width: proposed ?? used.width.rounded(.up), height: used.height.rounded(.up))
    }

    // The window moves only by its empty space.
    override var mouseDownCanMoveWindow: Bool { false }
    // A press on a panel that is not key selects at once.
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    // Images dropped on an answer go to the panel, which takes them anywhere on it.
    override func updateDragTypeRegistration() { unregisterDraggedTypes() }

    /// Beside the text, right of its longest line, is the panel's own space.
    override func hitTest(_ point: NSPoint) -> NSView? {
        guard let hit = super.hitTest(point), let layout = layoutManager, let container = textContainer else { return nil }
        let p = convert(point, from: superview)
        return p.x <= layout.usedRect(for: container).maxX ? hit : nil
    }

    /// Typing goes to the input, as if it had the keyboard; shortcuts, the arrows and Esc stay
    /// with the text and the window.
    override func keyDown(with event: NSEvent) {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        if event.keyCode == 53 {
            nextResponder?.tryToPerform(#selector(NSResponder.cancelOperation(_:)), with: self)
            return
        }
        guard flags.isDisjoint(with: [.command, .control]), let typed = event.characters?.unicodeScalars.first,
              typed.value >= 0x20, typed.value != 0x7F, !(0xF700...0xF8FF).contains(typed.value)
        else { return super.keyDown(with: event) }
        guard let window, let input = window.contentView.flatMap(Self.input(in:)), input.isEditable else { return }
        window.makeFirstResponder(input)
        input.keyDown(with: event)
    }

    private static func input(in view: NSView) -> ComposerTextView? {
        if let input = view as? ComposerTextView { return input }
        for sub in view.subviews { if let found = input(in: sub) { return found } }
        return nil
    }
}

/// An answer's text in one selectable view.
struct AnswerText: NSViewRepresentable {
    let text: NSAttributedString
    let links: NSColor

    func makeNSView(context: Context) -> AnswerTextView {
        AnswerTextView.make()
    }

    func updateNSView(_ view: AnswerTextView, context: Context) {
        view.show(text, links: links)
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView view: AnswerTextView, context: Context) -> CGSize? {
        view.fit(width: proposal.width)
    }
}
