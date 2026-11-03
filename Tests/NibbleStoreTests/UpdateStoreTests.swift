import Foundation
import NibbleCore
import Testing
@testable import NibbleStore

/// What the update checks found survives a restart, and a missing or damaged file is no record.
@Suite struct UpdateStoreTests {
    @Test func theRecordRoundTrips() throws {
        let sandbox = try StoreTests.Sandbox()
        let store = UpdateStore(paths: sandbox.paths)
        #expect(store.load() == UpdateRecord())
        let record = UpdateRecord(
            checked: Date(timeIntervalSince1970: 1_800_000_000.25),
            latest: Release(version: AppVersion("0.1.2")!, page: URL(string: "https://github.com/Glimmer-X/Nibble/releases/tag/v0.1.2")!),
            ignored: AppVersion("0.1.2")
        )
        try store.save(record)
        #expect(store.file.lastPathComponent == "updates.json")
        #expect(store.load() == record)
        let text = try String(contentsOf: store.file, encoding: .utf8)
        #expect(text.contains("\"0.1.2\""))
        #expect(text.contains("2027-01-15T08:00:00.250Z"))
    }

    @Test func aDamagedFileIsNoRecord() throws {
        let sandbox = try StoreTests.Sandbox()
        let store = UpdateStore(paths: sandbox.paths)
        try Data("{ not json".utf8).write(to: store.file)
        #expect(store.load() == UpdateRecord())
    }
}
