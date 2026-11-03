import CoreGraphics
import Foundation
import Testing
@testable import NibbleUI

/// The light registry's bookkeeping and history's choice after a delete: logic the windows rely on,
/// checked without one.
@MainActor
@Suite struct RegistryAndHistoryTests {
    @Test func aViewThatLeavesRemovesOnlyItsOwnEntries() {
        // The next transcript reports under the same names before the old one leaves.
        let registry = LightRegistry()
        let old = UUID()
        let new = UUID()
        registry.setPlate("box", LightRegistry.Plate(rect: .zero, rose: false, page: "main", owner: old))
        registry.setPlate("box", LightRegistry.Plate(rect: CGRect(x: 0, y: 0, width: 10, height: 10), rose: false, page: "main", owner: new))
        registry.setClip("transcript", .zero, owner: old)
        registry.setClip("transcript", .zero, owner: new)
        registry.update("key", kind: .key, place: .main, owner: old) { $0.hot = true }
        registry.update("key", kind: .key, place: .main, owner: new) { $0.hot = false }

        registry.removePlate("box", owner: old)
        registry.removeClip("transcript", owner: old)
        registry.removeControl("key", owner: old)
        #expect(registry.plates["box"] != nil)
        #expect(registry.clips["transcript"] != nil)
        #expect(registry.controls["key"] != nil)

        registry.removePlate("box", owner: new)
        registry.removeClip("transcript", owner: new)
        registry.removeControl("key", owner: new)
        #expect(registry.plates["box"] == nil)
        #expect(registry.clips["transcript"] == nil)
        #expect(registry.controls["key"] == nil)
    }

    @Test func deletingTheOpenConversationOpensTheNext() {
        let (a, b, c) = (UUID(), UUID(), UUID())
        let list = [a, b, c]
        #expect(MainModel.selection(afterDeleting: b, in: list, selected: b) == c)
        #expect(MainModel.selection(afterDeleting: c, in: list, selected: c) == b)
        // Nothing picked: the first is open.
        #expect(MainModel.selection(afterDeleting: a, in: list, selected: nil) == b)
        #expect(MainModel.selection(afterDeleting: b, in: list, selected: nil) == nil)
        // Another one picked stays picked.
        #expect(MainModel.selection(afterDeleting: b, in: list, selected: a) == a)
        #expect(MainModel.selection(afterDeleting: a, in: [a], selected: a) == nil)
    }
}
