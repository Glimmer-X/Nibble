import AppKit
import Testing
@testable import NibbleUI

/// An answer's text as one selectable piece: what it holds, how tall it is and how its tables share
/// the width. (Its look was compared with the earlier SwiftUI views by rendering both headless.)
@MainActor
@Suite struct AnswerTextTests {
    static func pieces(_ markdown: String) -> [AnswerLayout.Piece] {
        Typeface.register()
        return AnswerLayout.pieces(of: MarkdownDocument(markdown), ink: AnswerLayout.Ink(UpdateNoticeTests.app().colors))
    }

    static func view(_ markdown: String) -> AnswerTextView? {
        guard case .text(let text) = pieces(markdown).first else { return nil }
        let view = AnswerTextView.make()
        view.show(text, links: .white)
        return view
    }

    @Test func oneTextHoldsEveryKindOfBlock() {
        let markdown = "Intro **bold**.\n\n## Steps\n\n1. One\n2. Two\n\n- Dot\n\n> Quoted\n\n```\nlet a = 1\nlet b = 2\n```\n\n| A | B |\n| --- | --- |\n| 1 | 2 |"
        let pieces = Self.pieces(markdown)
        #expect(pieces.count == 1)
        guard case .text(let text) = pieces.first else { return }
        #expect(text.string == "Intro bold.\nSteps\n01\tOne\n02\tTwo\n•\tDot\nQuoted\nlet a = 1\nlet b = 2\nA\nB\n1\n2")
    }

    @Test func imagesSplitTheText() {
        let pieces = Self.pieces("Before\n\n![chart](https://example.com/a.png)\n\nAfter")
        #expect(pieces.count == 3)
        if case .text(let before) = pieces[0] { #expect(before.string == "Before") } else { Issue.record("no text first") }
        if case .image(let url, _) = pieces[1] { #expect(url.absoluteString == "https://example.com/a.png") } else { Issue.record("no image") }
        if case .text(let after) = pieces[2] { #expect(after.string == "After") } else { Issue.record("no text last") }
    }

    @Test func aRuleAtTheEndIsLeftOut() {
        guard case .text(let text) = Self.pieces("Text\n\n---").first else { return }
        #expect(text.string == "Text")
    }

    @Test func linesKeepTheRhythm() throws {
        let view = try #require(Self.view("One\n\nTwo"))
        // Two lines on the rhythm, 8 pt between the paragraphs.
        #expect(view.fit(width: 400).height == Typeface.line * 2 + 8)
    }

    @Test func copyingGivesPlainTextWithoutDrawnMarks() throws {
        let view = try #require(Self.view("1. One\n\n- Dot\n\n---\n\nEnd"))
        let board = NSPasteboard(name: NSPasteboard.Name("nibble-tests-\(UUID().uuidString)"))
        defer { board.releaseGlobally() }
        board.clearContents()
        view.setSelectedRange(NSRange(location: 0, length: view.textStorage?.length ?? 0))
        #expect(view.writeSelection(to: board, types: view.writablePasteboardTypes))
        #expect(board.string(forType: .string) == "01\tOne\n•\tDot\n\nEnd")
    }

    @Test func narrowColumnsKeepTheirWidthInAWideTable() {
        // A table that fits keeps every column as wide as its text.
        #expect(AnswerTable.widths([40, 40], available: 400) == [40, 40])
        // Too wide: the narrow columns keep theirs, the long one takes what is left.
        #expect(AnswerTable.widths([40, 428, 26], available: 388) == [40, 290, 26])
        // Long columns share it.
        #expect(AnswerTable.widths([300, 300], available: 216) == [100, 100])
    }
}
