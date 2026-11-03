import CoreGraphics
import Foundation
import Testing
@testable import NibbleUI

/// The strip the chat folds into: its size and the places its light starts from, checked without a
/// window (the folding itself is in the on-screen self-test's `strip` part).
@MainActor
@Suite struct PanelStripTests {
    @Test func theStripIsWholeCellsAndHoldsItsAskingLine() {
        Typeface.register()
        let chinese = PanelStrip.size(Strings(language: .chinese))
        let english = PanelStrip.size(Strings(language: .english))
        for size in [chinese, english] {
            #expect(size.height == PanelStrip.height)
            #expect(size.width >= 280 && size.width.truncatingRemainder(dividingBy: 10) == 0)
        }
        // At the small size the Chinese line (等你确认, room for the cursor, 允许, 拒绝) takes 31 cells;
        // the English words are longer, so its strip is at least as wide.
        #expect(chinese.width == 310)
        #expect(english.width >= chinese.width)
    }

    @Test func anAnchorIsRemovedOnlyByTheViewThatReportedIt() {
        let registry = LightRegistry()
        let old = UUID()
        let new = UUID()
        registry.setAnchor(PanelStrip.keyAnchor, CGRect(x: 4, y: 4, width: 32, height: 32), owner: old)
        registry.setAnchor(PanelStrip.keyAnchor, CGRect(x: 4, y: 4, width: 32, height: 32), owner: new)
        registry.removeAnchor(PanelStrip.keyAnchor, owner: old)
        #expect(registry.anchors[PanelStrip.keyAnchor]?.midX == 20)
        registry.removeAnchor(PanelStrip.keyAnchor, owner: new)
        #expect(registry.anchors[PanelStrip.keyAnchor] == nil)
    }

    @Test func theStripSaysHowAReplyEnded() {
        let s = Strings(language: .chinese)
        #expect(s.done(thoughtFor: 18) == "完成 · 思考了 18 秒")
        #expect(s.done(thoughtFor: nil) == "完成")
        #expect(s.failed == "ERROR")
    }
}
