import AppKit
import Observation
import SwiftUI
import Testing
@testable import NibbleUI

/// A plate turning on or off under a view leaves the view the same view: history's delete key
/// relies on its row keeping its hover while the row turns into a warning.
@MainActor
@Suite struct PlateSwitchTests {
    @Observable final class Switch {
        var on = false
    }

    final class Count {
        var appeared = 0
    }

    struct Probe: View {
        let plate: Switch
        let count: Count
        let registry: LightRegistry

        var body: some View {
            Color.clear
                .frame(width: 90, height: 36)
                .onAppear { count.appeared += 1 }
                .modifier(SelectedPlate(id: "row", on: plate.on, rose: true))
                .frame(width: 120, height: 60)
                .coordinateSpace(.named(BoardSpace.name))
                .environment(\.lightRegistry, registry)
        }
    }

    @Test func aPlateTurningOnKeepsTheViewUnderIt() async throws {
        let plate = Switch()
        let count = Count()
        let registry = LightRegistry()
        // Hosted in a window that is never shown.
        let host = NSHostingView(rootView: Probe(plate: plate, count: count, registry: registry))
        host.frame = CGRect(x: 0, y: 0, width: 120, height: 60)
        let window = NSWindow(contentRect: host.frame, styleMask: .borderless, backing: .buffered, defer: true)
        window.contentView = host
        func settle() async throws {
            host.layoutSubtreeIfNeeded()
            try await Task.sleep(for: .milliseconds(30))
            host.layoutSubtreeIfNeeded()
        }
        try await settle()
        #expect(count.appeared == 1)
        #expect(registry.plates["row"] == nil)

        plate.on = true
        try await settle()
        #expect(registry.plates["row"]?.rose == true)
        #expect(registry.plates["row"]?.rect.width == 90)

        plate.on = false
        try await settle()
        #expect(registry.plates["row"] == nil)
        #expect(count.appeared == 1)
        window.contentView = nil
    }
}
