import Foundation
import Testing
@testable import NibbleCore

/// Looking for a newer version: comparing versions, when checks run, when the notice shows, and
/// what dismissing it and checking by hand do.
@MainActor
@Suite struct UpdatesTests {
    /// A release source that answers what it is told and counts the questions.
    final class Source: ReleaseSource, @unchecked Sendable {
        private let lock = NSLock()
        private var answer: Result<Release, ReleaseError>
        private(set) var asked = 0

        init(_ answer: Result<Release, ReleaseError>) { self.answer = answer }

        func set(_ next: Result<Release, ReleaseError>) { lock.withLock { answer = next } }

        func latest() async throws -> Release {
            try lock.withLock {
                asked += 1
                return try answer.get()
            }
        }
    }

    static let page = URL(string: "https://github.com/Glimmer-X/Nibble/releases/tag/v0.1.2")!
    static func release(_ version: String) -> Release { Release(version: AppVersion(version)!, page: page) }

    /// A checker running 0.1.1 on a clock the test moves.
    final class Rig {
        var time = Date(timeIntervalSince1970: 1_800_000_000)
        let source: Source
        let updates: Updates
        var saved: [UpdateRecord] = []

        @MainActor init(_ answer: Result<Release, ReleaseError>, record: UpdateRecord = UpdateRecord(), automatic: Bool = true) {
            source = Source(answer)
            updates = Updates(current: AppVersion("0.1.1")!, record: record, automatic: automatic, source: source)
            updates.now = { [unowned self] in self.time }
            updates.onRecordChange = { [unowned self] in self.saved.append($0) }
        }

        func wait(hours: Double) { time += hours * 3600 }
    }

    // MARK: Versions

    @Test func versionsCompareNumberByNumber() {
        let v = { AppVersion($0)! }
        #expect(v("0.1.2") > v("0.1.1"))
        #expect(v("0.10.0") > v("0.9.9"))
        #expect(v("1.0") > v("0.99.99"))
        #expect(v("v0.2") == v("0.2.0"))
        #expect(v("V1.2.3") == v("1.2.3"))
        #expect(Set([v("0.2"), v("0.2.0"), v("v0.2.0.0")]).count == 1)
        #expect(v("0.2.0").description == "0.2.0")
        #expect(v("v0.2").description == "0.2")
    }

    @Test(arguments: ["", "v", "0.2.0-beta", "1..2", "nightly", "-1.0", "1.0.", " ", "1.x"])
    func anythingButNumbersIsNotAVersion(_ text: String) {
        #expect(AppVersion(text) == nil)
    }

    @Test func versionsAreSavedAsText() throws {
        let record = UpdateRecord(checked: Date(timeIntervalSince1970: 0), latest: Self.release("0.1.2"), ignored: AppVersion("0.1.2"))
        let data = try JSONEncoder().encode(record)
        #expect(String(decoding: data, as: UTF8.self).contains("\"0.1.2\""))
        #expect(try JSONDecoder().decode(UpdateRecord.self, from: data) == record)
    }

    @Test func aDamagedRecordKeepsWhatItCanRead() throws {
        let json = #"{"checked": 10, "latest": {"version": "beta", "page": "https://x"}, "ignored": "0.1.2"}"#
        let record = try JSONDecoder().decode(UpdateRecord.self, from: Data(json.utf8))
        #expect(record.latest == nil)
        #expect(record.ignored == AppVersion("0.1.2"))
    }

    // MARK: The notice

    @Test func aNewerReleaseShowsANotice() async {
        let rig = Rig(.success(Self.release("0.1.2")))
        #expect(rig.updates.notice == nil)
        await rig.updates.check(asked: false)
        #expect(rig.updates.notice?.version == AppVersion("0.1.2"))
        #expect(rig.updates.newer?.page == Self.page)
        #expect(rig.saved.last?.latest == Self.release("0.1.2"))
        #expect(rig.saved.last?.checked == rig.time)
    }

    @Test(arguments: ["0.1.1", "v0.1.1", "0.1.0", "0.0.9"])
    func theSameOrAnOlderReleaseShowsNothing(_ latest: String) async {
        // A build newer than the latest release (a development build) shows nothing either.
        let rig = Rig(.success(Self.release(latest)))
        await rig.updates.check(asked: true)
        #expect(rig.updates.newer == nil)
        #expect(rig.updates.notice == nil)
        #expect(rig.updates.status == .checked)
    }

    @Test func dismissingHidesTheNoticeUntilANewerRelease() async {
        let rig = Rig(.success(Self.release("0.1.2")))
        await rig.updates.check(asked: false)
        rig.updates.ignore()
        #expect(rig.updates.notice == nil)
        // Still newer: settings say so, without the notice.
        #expect(rig.updates.newer?.version == AppVersion("0.1.2"))
        #expect(rig.saved.last?.ignored == AppVersion("0.1.2"))

        // The next day's check finds the same release: still dismissed.
        rig.wait(hours: 25)
        await rig.updates.check(asked: false)
        #expect(rig.updates.notice == nil)

        // A newer release comes back with a notice.
        rig.source.set(.success(Self.release("0.1.3")))
        rig.wait(hours: 25)
        await rig.updates.check(asked: false)
        #expect(rig.updates.notice?.version == AppVersion("0.1.3"))
    }

    @Test func checkingByHandBringsADismissedNoticeBack() async {
        let rig = Rig(.success(Self.release("0.1.2")))
        await rig.updates.check(asked: false)
        rig.updates.ignore()
        await rig.updates.check(asked: true)
        #expect(rig.updates.notice?.version == AppVersion("0.1.2"))
        #expect(rig.updates.record.ignored == nil)
    }

    @Test func dismissingWithNoNoticeChangesNothing() {
        let rig = Rig(.success(Self.release("0.1.2")))
        rig.updates.ignore()
        #expect(rig.updates.record == UpdateRecord())
        #expect(rig.saved.isEmpty)
    }

    @Test func aNoticeFoundBeforeShowsAtLaunch() {
        // The record from an earlier run: no check needed for the notice to show.
        let record = UpdateRecord(checked: Date(timeIntervalSince1970: 1_800_000_000), latest: Self.release("0.2"))
        let rig = Rig(.failure(.unreachable), record: record)
        #expect(rig.updates.notice?.version == AppVersion("0.2"))
    }

    @Test func installingTheNewVersionEndsTheNotice() {
        // The record says 0.1.2 is out; this copy is 0.1.2 now.
        let record = UpdateRecord(latest: Self.release("0.1.2"))
        let updates = Updates(current: AppVersion("0.1.2")!, record: record, automatic: true, source: Source(.failure(.unreachable)))
        #expect(updates.notice == nil)
        #expect(updates.newer == nil)
    }

    // MARK: When checks run

    @Test func automaticChecksRunOnceADay() async {
        let rig = Rig(.success(Self.release("0.1.1")))
        #expect(rig.updates.isDue)
        await rig.updates.check(asked: false)
        #expect(!rig.updates.isDue)
        rig.wait(hours: 23)
        #expect(!rig.updates.isDue)
        rig.wait(hours: 1.5)
        #expect(rig.updates.isDue)
    }

    @Test func aFailedAutomaticCheckSaysNothingAndTriesAgainAnHourLater() async {
        let rig = Rig(.failure(.unreachable))
        await rig.updates.check(asked: false)
        #expect(rig.updates.status == .idle)
        #expect(rig.updates.record == UpdateRecord())
        #expect(rig.saved.isEmpty)
        #expect(!rig.updates.isDue)
        rig.wait(hours: 0.9)
        #expect(!rig.updates.isDue)
        rig.wait(hours: 0.2)
        #expect(rig.updates.isDue)
    }

    @Test func aFailedCheckKeepsWhatWasFoundBefore() async {
        let record = UpdateRecord(checked: Date(timeIntervalSince1970: 1_700_000_000), latest: Self.release("0.1.2"))
        let rig = Rig(.failure(.refused(status: 403)), record: record)
        await rig.updates.check(asked: false)
        #expect(rig.updates.record == record)
        #expect(rig.updates.notice?.version == AppVersion("0.1.2"))
    }

    @Test(arguments: [ReleaseError.unreachable, .refused(status: 403), .refused(status: 429), .noRelease, .unreadable])
    func aCheckByHandSaysWhyItFailed(_ error: ReleaseError) async {
        let rig = Rig(.failure(error))
        await rig.updates.check(asked: true)
        #expect(rig.updates.status == .failed(error))
        // Asking again clears it while the check runs, and success replaces it.
        rig.source.set(.success(Self.release("0.1.1")))
        await rig.updates.check(asked: true)
        #expect(rig.updates.status == .checked)
    }

    @Test func turnedOffNothingRunsByItself() async {
        let rig = Rig(.success(Self.release("0.1.2")), automatic: false)
        #expect(!rig.updates.isDue)
        rig.updates.checkIfDue()
        try? await Task.sleep(for: .milliseconds(50))
        #expect(rig.source.asked == 0)
        // Checking by hand still works.
        await rig.updates.check(asked: true)
        #expect(rig.updates.notice != nil)
    }

    @Test func checkIfDueChecksOnceUntilTheNextDay() async throws {
        let rig = Rig(.success(Self.release("0.1.2")))
        rig.updates.checkIfDue()
        rig.updates.checkIfDue()
        for _ in 0..<100 where rig.updates.record.checked == nil {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(rig.updates.notice != nil)
        rig.updates.checkIfDue()
        try await Task.sleep(for: .milliseconds(50))
        #expect(rig.source.asked == 1)
    }

    @Test func checkingByHandShowsProgressThenTheResult() async throws {
        let rig = Rig(.success(Self.release("0.1.2")))
        rig.updates.check()
        #expect(rig.updates.status == .checking)
        #expect(!rig.updates.isDue)
        for _ in 0..<100 where rig.updates.status == .checking {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(rig.updates.status == .checked)
        #expect(rig.updates.notice != nil)
    }
}
