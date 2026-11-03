import AppKit
import SwiftUI

/// An answer's Markdown as blocks, parsed with Foundation's Markdown support (no dependency).
struct MarkdownDocument: Equatable {
    struct Block: Identifiable, Equatable {
        enum Kind: Equatable {
            case paragraph
            case heading(Int)
            case code(language: String?)
            /// A list item: its marker ("01" or a square), how deeply nested.
            case item(marker: Marker, depth: Int)
            case table(header: [AttributedString], rows: [[AttributedString]])
            case image(URL)
            case rule
        }

        enum Marker: Equatable {
            case number(Int)
            case bullet
            /// A further paragraph of the same item.
            case none
        }

        let id: Int
        var kind: Kind
        var text: AttributedString
        /// Inside a quote.
        var quoted: Bool
    }

    let blocks: [Block]

    init(_ markdown: String) {
        let options = AttributedString.MarkdownParsingOptions(
            allowsExtendedAttributes: true,
            interpretedSyntax: .full,
            failurePolicy: .returnPartiallyParsedIfPossible
        )
        guard let parsed = try? AttributedString(markdown: markdown, options: options) else {
            blocks = [Block(id: 0, kind: .paragraph, text: AttributedString(markdown), quoted: false)]
            return
        }
        blocks = Self.blocks(of: parsed)
    }

    private static func blocks(of parsed: AttributedString) -> [Block] {
        var blocks: [Block] = []
        var currentIdentity: Int?
        var tableIdentity: Int?
        var tableHeader: [AttributedString] = []
        var tableRows: [Int: [Int: AttributedString]] = [:]
        var seenItems = Set<Int>()

        func flushTable() {
            guard tableIdentity != nil else { return }
            let rows = tableRows.keys.sorted().map { r in
                let cells = tableRows[r] ?? [:]
                return (0..<(cells.keys.max().map { $0 + 1 } ?? 0)).map { cells[$0] ?? AttributedString() }
            }
            blocks.append(Block(id: blocks.count, kind: .table(header: tableHeader, rows: rows), text: AttributedString(), quoted: false))
            tableIdentity = nil
            tableHeader = []
            tableRows = [:]
        }

        for run in parsed.runs {
            let piece = AttributedString(parsed[run.range])
            guard let intent = run.presentationIntent else {
                // Text outside any block: part of the last paragraph.
                if let last = blocks.indices.last { blocks[last].text += piece }
                continue
            }
            let components = intent.components
            // A table collects its cells into one block.
            if let table = components.first(where: { if case .table = $0.kind { true } else { false } }) {
                if tableIdentity != table.identity {
                    flushTable()
                    tableIdentity = table.identity
                }
                var column = 0
                var row: Int?
                var header = false
                for c in components {
                    switch c.kind {
                    case .tableCell(let index): column = index
                    case .tableRow(let index): row = index
                    case .tableHeaderRow: header = true
                    default: break
                    }
                }
                if header {
                    while tableHeader.count <= column { tableHeader.append(AttributedString()) }
                    tableHeader[column] += piece
                } else if let row {
                    tableRows[row, default: [:]][column, default: AttributedString()] += piece
                }
                currentIdentity = nil
                continue
            }
            flushTable()

            guard let block = components.first else { continue }
            if block.identity == currentIdentity, let last = blocks.indices.last {
                blocks[last].text += piece
                continue
            }
            currentIdentity = block.identity
            let quoted = components.contains { if case .blockQuote = $0.kind { true } else { false } }
            var kind: Block.Kind = .paragraph
            switch block.kind {
            case .header(let level): kind = .heading(level)
            case .codeBlock(let language): kind = .code(language: language)
            case .thematicBreak: kind = .rule
            default:
                if let item = components.first(where: { if case .listItem = $0.kind { true } else { false } }),
                   case .listItem(let ordinal) = item.kind {
                    let depth = components.filter {
                        switch $0.kind {
                        case .orderedList, .unorderedList: true
                        default: false
                        }
                    }.count
                    let ordered = components.first {
                        switch $0.kind {
                        case .orderedList, .unorderedList: true
                        default: false
                        }
                    }.map { if case .orderedList = $0.kind { true } else { false } } ?? false
                    let first = seenItems.insert(item.identity).inserted
                    kind = .item(marker: first ? (ordered ? .number(ordinal) : .bullet) : .none, depth: max(1, depth))
                }
            }
            // A paragraph that is only an image shows the image.
            if case .paragraph = kind, let url = run.imageURL {
                blocks.append(Block(id: blocks.count, kind: .image(url), text: AttributedString(), quoted: quoted))
                currentIdentity = nil
                continue
            }
            blocks.append(Block(id: blocks.count, kind: kind, text: piece, quoted: quoted))
        }
        flushTable()
        return blocks
    }
}

/// An answer rendered on the 24 pt text rhythm. No boxes: code is tinted and set in, quotes are
/// quiet and set in, list numbers are in the pixel face.
struct MarkdownView: View {
    @Environment(AppModel.self) private var model
    let document: MarkdownDocument

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(document.blocks) { block in
                blockView(block)
                    .padding(.leading, block.quoted ? 16 : 0)
                    .foregroundStyle(block.quoted ? model.colors.ink2 : model.colors.ink)
            }
        }
        .textSelection(.enabled)
        // The text's whole block, as wide as its longest line, gaps between paragraphs included,
        // belongs to the text: a press there selects or does nothing, never moves the window.
        .contentShape(Rectangle())
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private func blockView(_ block: MarkdownDocument.Block) -> some View {
        let colors = model.colors
        switch block.kind {
        case .paragraph:
            Text(styled(block.text)).font(Typeface.message).rhythm()
                .fixedSize(horizontal: false, vertical: true)
        case .heading:
            Text(styled(block.text)).font(Typeface.heading).rhythm(fontSize: Typeface.headingSize)
                .padding(.top, 8)
                .fixedSize(horizontal: false, vertical: true)
        case .code:
            ScrollView(.horizontal, showsIndicators: false) {
                Text(String(block.text.characters).trimmingCharacters(in: .newlines))
                    .font(Typeface.code)
                    .foregroundStyle(colors.code)
                    .rhythm(fontSize: Typeface.codeSize)
                    .fixedSize()
            }
            .padding(.leading, 16)
        case .item(let marker, let depth):
            HStack(alignment: .firstTextBaseline, spacing: 0) {
                Group {
                    switch marker {
                    case .number(let n):
                        Text(String(format: "%02d", n)).pixelText().foregroundStyle(colors.ink2)
                    case .bullet:
                        Rectangle().fill(colors.ink2).frame(width: 4, height: 4).padding(.leading, 8)
                            .alignmentGuide(.firstTextBaseline) { _ in 8 }
                    case .none:
                        Color.clear.frame(width: 1, height: 1)
                    }
                }
                .frame(width: 32, alignment: .leading)
                Text(styled(block.text)).font(Typeface.message).rhythm()
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.leading, CGFloat(depth - 1) * 32)
        case .table(let header, let rows):
            Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 0) {
                if !header.isEmpty {
                    GridRow {
                        ForEach(header.indices, id: \.self) { i in
                            Text(String(header[i].characters)).pixelText().foregroundStyle(colors.ink2)
                                .padding(.bottom, 4)
                        }
                    }
                }
                ForEach(rows.indices, id: \.self) { r in
                    GridRow {
                        ForEach(rows[r].indices, id: \.self) { c in
                            Text(styled(rows[r][c])).font(Typeface.table).rhythm(fontSize: Typeface.tableSize)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
            }
            .padding(.vertical, 8)
        case .image(let url):
            AnswerImage(url: url)
        case .rule:
            Rectangle().fill(colors.ink3).frame(height: 1).padding(.vertical, 8)
        }
    }

    /// Inline styles: strong, emphasis, code, links, struck text.
    private func styled(_ text: AttributedString) -> AttributedString {
        let colors = model.colors
        var out = text
        for run in text.runs {
            let range = run.range
            if let inline = run.inlinePresentationIntent {
                if inline.contains(.code) {
                    out[range].font = Typeface.code
                    out[range].foregroundColor = colors.code
                }
                if inline.contains(.stronglyEmphasized) { out[range].font = .system(size: Typeface.messageSize, weight: .semibold) }
                if inline.contains(.emphasized) { out[range].font = .system(size: Typeface.messageSize).italic() }
                if inline.contains(.strikethrough) { out[range].strikethroughStyle = .single }
            }
            if run.link != nil {
                out[range].foregroundColor = colors.accent
                out[range].underlineStyle = .single
            }
        }
        return out
    }
}

/// An image in an answer, at most 264 pt wide, sized on the 8 pt grid. Data URLs (Hermes turns
/// the files it makes into them) and web addresses both work.
private struct AnswerImage: View {
    let url: URL
    @State private var image: NSImage?

    var body: some View {
        Group {
            if let image {
                let size = Self.size(image.size)
                Image(nsImage: image).resizable().interpolation(.high).frame(width: size.width, height: size.height)
                    .draggableImage(image)
            } else {
                Color.clear.frame(width: 1, height: 1)
            }
        }
        .padding(.vertical, 8)
        .task(id: url) { image = await Self.load(url) }
    }

    static func size(_ natural: CGSize) -> CGSize {
        guard natural.width > 0, natural.height > 0 else { return CGSize(width: 8, height: 8) }
        let width = max(8, (min(264, natural.width) / 8).rounded(.down) * 8)
        let height = max(8, (width * natural.height / natural.width / 8).rounded() * 8)
        return CGSize(width: width, height: height)
    }

    static func load(_ url: URL) async -> NSImage? {
        if url.scheme == "data" {
            guard let comma = url.absoluteString.firstIndex(of: ","),
                  let data = Data(base64Encoded: String(url.absoluteString[url.absoluteString.index(after: comma)...]))
            else { return nil }
            return NSImage(data: data)
        }
        guard url.scheme == "https" || url.scheme == "http",
              let (data, _) = try? await URLSession.shared.data(from: url)
        else { return nil }
        return NSImage(data: data)
    }
}
