import AppKit
import Foundation
import NibbleCore
import SwiftUI
import Testing
@testable import NibbleUI

/// The notice of a newer version: its band of light on the board, and the notice and lamps
/// reporting themselves to the board and leaving together when it is dismissed.
@MainActor
@Suite struct UpdateNoticeTests {
    // MARK: The glint

    /// A board on a fake clock with one glinting rose plate 400 pt wide.
    @MainActor final class Rig {
        let board = Board(width: 480, maxHeight: 200)
        var ms = 0.0
        let rect = BoardScene.Rect(x0: 40, y0: 100, x1: 440, y1: 140)

        init() {
            board.now = { [unowned self] in self.ms }
            board.setPalette(Palette(.dark))
            board.setMotion(nil)
        }

        /// Renders at `ms` into the glint's period; returns each lit column's level in the
        /// plate's middle row (nil where unlit).
        func row(at phase: Double) -> [Int?] {
            ms = Board.glintPeriod * 7 + phase
            var scene = BoardScene(width: 480, height: 200)
            scene.plates = [BoardScene.Plate(rect: rect, clip: nil, rose: true, value: 0.27, glint: true)]
            board.render(scene)
            let r = 12
            return (0..<board.cols).map { c in
                let packed = board.cellColors[r * board.cols + c]
                guard packed != Board.pack(board.fill(0)) else { return nil }
                return board.fills.firstIndex { Board.pack($0) == packed }
            }
        }

        /// The column of the brightest cell.
        func brightest(_ row: [Int?]) -> Int {
            row.indices.max { (row[$0] ?? -1) < (row[$1] ?? -1) }!
        }
    }

    @Test func aBandOfLightCrossesTheNoticeThenRests() {
        let rig = Rig()
        // Resting: the plate is even.
        let resting = rig.row(at: Board.glintRun + 300)
        #expect(Set(resting.compactMap(\.self)).count == 1)
        #expect(resting.compactMap(\.self).count == 40)

        // Crossing: brighter cells around the band, which moves left to right.
        let early = rig.row(at: Board.glintRun * 0.3)
        let late = rig.row(at: Board.glintRun * 0.7)
        #expect(Set(early.compactMap(\.self)).count > 1)
        #expect(rig.brightest(early) < rig.brightest(late))
        #expect(early.compactMap(\.self).max()! > resting.compactMap(\.self).max()!)
        // The band never reaches past the plate.
        #expect(early.compactMap(\.self).count == 40)
        #expect(early[3] == nil && early[44] == nil)
    }

    @Test func theBandStaysAwayWhenMotionIsReduced() {
        let rig = Rig()
        rig.board.still = true
        #expect(Set(rig.row(at: Board.glintRun * 0.5).compactMap(\.self)).count == 1)
    }

    @Test func theBandsInEveryWindowRunTogether() {
        // The band's place depends only on the clock, so notices in different windows agree.
        let rig = Rig()
        rig.ms = 123_456
        let a = rig.board.glint(across: rig.rect)
        let other = Board(width: 340, maxHeight: 500)
        other.now = { 123_456 }
        #expect(a == other.glint(across: rig.rect))
    }

    // MARK: The notice in a window

    struct NoBackend: ChatBackend {
        func respond(to request: ChatRequest) -> AsyncThrowingStream<ChatEvent, any Error> { AsyncThrowingStream { $0.finish() } }
    }

    final class NoProvider: BackendProvider {
        func backend(for settings: BackendSettings) -> any ChatBackend { NoBackend() }
        func profiles(for settings: BackendSettings) async -> [String] { [] }
        func check(_ settings: BackendSettings) async -> ConnectionStatus { .connected }
        func keyState(for settings: BackendSettings) -> KeyState { .missing }
        func saveKey(_ key: String?, for settings: BackendSettings) throws {}
        func forget(remoteSession handle: String, settings: BackendSettings) async throws {}
    }

    final class NoServices: SystemServices {
        func canCaptureScreen(ask: Bool) -> Bool { false }
        func captureScreen(at point: CGPoint) async throws -> PreparedImage { throw BackendError.unsupported }
        func prepareImage(_ data: Data) -> PreparedImage? { nil }
        func openScreenCaptureSettings() {}
        func reveal(_ url: URL) {}
        func hotKeyConflicts(_ combo: KeyCombo) async -> [HotKeyConflict] { [] }
        var opensAtLogin: Bool { false }
        func setOpensAtLogin(_ on: Bool) throws {}
    }

    struct NoRepository: ConversationRepository {
        func save(_ conversation: Conversation) async throws {}
        func load(id: Conversation.ID) async throws -> Conversation? { nil }
        func latest() async throws -> Conversation? { nil }
        func all() async throws -> [Conversation] { [] }
        func delete(id: Conversation.ID) async throws {}
        func storeAttachment(_ data: Data, mediaType: String, for conversationID: Conversation.ID) async throws -> NibbleCore.Attachment { throw BackendError.unsupported }
        func attachmentData(_ attachment: NibbleCore.Attachment, in conversationID: Conversation.ID) async throws -> Data { Data() }
        func prune(_ policy: RetentionPolicy, now: Date) async throws -> Int { 0 }
    }

    struct Out: ReleaseSource {
        func latest() async throws -> Release { throw ReleaseError.unreachable }
    }

    /// The app's model running 0.1.1, with 0.1.2 found earlier.
    static func app() -> AppModel {
        _ = NSApplication.shared
        let record = UpdateRecord(latest: Release(version: AppVersion("0.1.2")!, page: URL(string: "https://github.com/Glimmer-X/Nibble/releases")!))
        let updates = Updates(current: AppVersion("0.1.1")!, record: record, automatic: false, source: Out())
        let session = ConversationSession(backend: NoBackend(), repository: NoRepository(), continueWindow: .seconds(600))
        return AppModel(session: session, updates: updates, settings: Settings(), provider: NoProvider(), services: NoServices(),
                        repository: NoRepository(), dataFolder: FileManager.default.temporaryDirectory)
    }

    struct Page: View {
        @Environment(AppModel.self) private var app

        var body: some View {
            VStack(alignment: .leading, spacing: 0) {
                if let release = app.updates.notice {
                    UpdateNotice(release: release, id: "notice", place: .main)
                }
                HStack { Text("Settings"); UpdateLamp(id: "lamp") }
                Spacer(minLength: 0)
            }
            .frame(width: 400, height: 200, alignment: .topLeading)
            .coordinateSpace(.named(BoardSpace.name))
        }
    }

    @Test func theNoticeAndItsLampLightTheBoardUntilDismissed() async throws {
        let app = Self.app()
        let registry = LightRegistry()
        let host = NSHostingView(rootView: Page().environment(app).environment(\.lightRegistry, registry))
        host.frame = CGRect(x: 0, y: 0, width: 400, height: 200)
        // Hosted in a window that is never shown.
        let window = NSWindow(contentRect: host.frame, styleMask: .borderless, backing: .buffered, defer: true)
        window.contentView = host
        func settle() async throws {
            for _ in 0..<3 {
                host.layoutSubtreeIfNeeded()
                try await Task.sleep(for: .milliseconds(40))
            }
        }
        try await settle()

        let plate = try #require(registry.plates["notice-plate"])
        #expect(plate.rose && plate.glint && !plate.lamp)
        #expect(plate.rect.width == 400)
        #expect(plate.rect.height == UpdateNotice.height)
        let lamp = try #require(registry.plates["lamp"])
        #expect(lamp.rose && lamp.lamp)
        #expect(registry.controls["notice-download"] != nil)
        #expect(registry.controls["notice-ignore"] != nil)

        app.updates.ignore()
        try await settle()
        try await Task.sleep(for: .milliseconds(300))
        try await settle()
        #expect(registry.plates["notice-plate"] == nil)
        #expect(registry.plates["lamp"] == nil)
        #expect(registry.controls["notice-download"] == nil)
        window.contentView = nil
    }

    @Test func turningTheDailyCheckOffAndOnFollowsTheSetting() {
        let app = Self.app()
        #expect(!app.updates.automatic)
        app.settings.checkForUpdates = false
        #expect(!app.updates.automatic)
        app.settings.checkForUpdates = true
        #expect(app.updates.automatic)
    }
}
