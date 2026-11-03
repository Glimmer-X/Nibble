import Foundation
import Observation

/// A version of Nibble as its release tag names it: "0.1.2" or "v0.1.2". Compared part by part,
/// missing parts counting as 0, so 0.2 equals 0.2.0 and comes after 0.1.9.
public struct AppVersion: Sendable, Hashable, Comparable, Codable, CustomStringConvertible {
    public let parts: [Int]

    /// Nil for anything but dot-separated numbers (a pre-release tag such as "0.2.0-beta").
    public init?(_ text: String) {
        var text = text.trimmingCharacters(in: .whitespaces)
        if text.first == "v" || text.first == "V" { text.removeFirst() }
        let parts = text.split(separator: ".", omittingEmptySubsequences: false).map { Int($0) }
        guard !parts.isEmpty, parts.allSatisfy({ $0 != nil && $0! >= 0 }) else { return nil }
        self.parts = parts.compactMap(\.self)
    }

    public var description: String { parts.map(String.init).joined(separator: ".") }

    public static func < (a: AppVersion, b: AppVersion) -> Bool {
        for i in 0..<max(a.parts.count, b.parts.count) {
            let x = i < a.parts.count ? a.parts[i] : 0
            let y = i < b.parts.count ? b.parts[i] : 0
            if x != y { return x < y }
        }
        return false
    }

    public static func == (a: AppVersion, b: AppVersion) -> Bool { !(a < b) && !(b < a) }

    public func hash(into hasher: inout Hasher) {
        var parts = parts
        while parts.last == 0 { parts.removeLast() }
        hasher.combine(parts)
    }

    public init(from decoder: any Decoder) throws {
        let text = try decoder.singleValueContainer().decode(String.self)
        guard let version = AppVersion(text) else {
            throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "Not a version: \(text)"))
        }
        self = version
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(description)
    }
}

/// A published release: its version and the page it can be downloaded from.
public struct Release: Sendable, Equatable, Codable {
    public var version: AppVersion
    public var page: URL

    public init(version: AppVersion, page: URL) {
        self.version = version
        self.page = page
    }
}

/// Where the latest release is looked up (GitHub's releases, in the app).
public protocol ReleaseSource: Sendable {
    func latest() async throws -> Release
}

/// Why a check found nothing.
public enum ReleaseError: Error, Equatable, Sendable {
    /// The server could not be reached.
    case unreachable
    /// The server answered with an error status (403 and 429 when it limits requests).
    case refused(status: Int)
    /// There is no release yet.
    case noRelease
    /// The answer could not be read, or its tag is not a version.
    case unreadable
}

/// What the update checks have found, kept between launches.
public struct UpdateRecord: Codable, Equatable, Sendable {
    /// The last check that got an answer.
    public var checked: Date?
    /// The latest release that check found.
    public var latest: Release?
    /// The release whose notice the reader dismissed; its notice stays away until a newer one.
    public var ignored: AppVersion?

    public init(checked: Date? = nil, latest: Release? = nil, ignored: AppVersion? = nil) {
        self.checked = checked
        self.latest = latest
        self.ignored = ignored
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        checked = try? c.decodeIfPresent(Date.self, forKey: .checked)
        latest = try? c.decodeIfPresent(Release.self, forKey: .latest)
        ignored = try? c.decodeIfPresent(AppVersion.self, forKey: .ignored)
    }
}

/// Looks for a newer Nibble: once a day while automatic checks are on, and whenever the reader
/// asks. A newer release shows as a notice until the reader dismisses it; it comes back with the
/// next release, or when the reader checks again.
///
/// An automatic check that fails says nothing and tries again an hour later; one the reader asked
/// for says it failed.
@MainActor
@Observable
public final class Updates {
    public enum Status: Equatable, Sendable {
        case idle
        case checking
        /// The last check the reader asked for got an answer.
        case checked
        /// The last check the reader asked for failed.
        case failed(ReleaseError)
    }

    /// The version running.
    public let current: AppVersion
    public private(set) var record: UpdateRecord {
        didSet { if record != oldValue { onRecordChange(record) } }
    }
    public private(set) var status: Status = .idle
    /// Checks once a day by themselves.
    public var automatic: Bool

    /// Time between automatic checks.
    public static let interval: TimeInterval = 24 * 3600
    /// Time before an automatic check that failed is tried again.
    public static let retry: TimeInterval = 3600

    @ObservationIgnored private let source: any ReleaseSource
    /// Told of every change to the record, to save it.
    @ObservationIgnored public var onRecordChange: (UpdateRecord) -> Void = { _ in }
    /// The clock. Tests replace it.
    @ObservationIgnored public var now: () -> Date = Date.init
    /// When an automatic check last started, answered or not.
    @ObservationIgnored private var attempted: Date?
    @ObservationIgnored private var task: Task<Void, Never>?
    /// Counts checks started, so only the latest one clears `task`.
    @ObservationIgnored private var generation = 0
    @ObservationIgnored private var schedule: Task<Void, Never>?

    public init(current: AppVersion, record: UpdateRecord, automatic: Bool, source: any ReleaseSource) {
        self.current = current
        self.record = record
        self.automatic = automatic
        self.source = source
    }

    /// The latest release, if it is newer than the version running.
    public var newer: Release? {
        guard let latest = record.latest, latest.version > current else { return nil }
        return latest
    }

    /// The newer release to tell the reader about: nil once they dismissed it.
    public var notice: Release? {
        guard let newer, newer.version != record.ignored else { return nil }
        return newer
    }

    /// Whether an automatic check should run now.
    public var isDue: Bool {
        guard automatic, status != .checking else { return false }
        let time = now()
        if let checked = record.checked, time.timeIntervalSince(checked) < Self.interval { return false }
        if let attempted, time.timeIntervalSince(attempted) < Self.retry { return false }
        return true
    }

    /// Dismisses the notice until a newer release, or until the reader checks again.
    public func ignore() {
        guard let notice else { return }
        record.ignored = notice.version
    }

    /// Checks now, at the reader's request: the result shows in `status`, and a dismissed notice
    /// comes back if the release is still newer. A check already under way gives way to it.
    public func check() {
        run(asked: true)
    }

    /// Checks if a day has passed since the last answer (and an hour since a failed try).
    public func checkIfDue() {
        guard isDue, task == nil else { return }
        run(asked: false)
    }

    private func run(asked: Bool) {
        task?.cancel()
        // Settings show the check under way at once.
        if asked { status = .checking }
        generation += 1
        let mine = generation
        task = Task { [weak self] in
            await self?.check(asked: asked)
            if self?.generation == mine { self?.task = nil }
        }
    }

    /// Checks when due now and then every hour while automatic checks are on.
    public func start() {
        schedule?.cancel()
        schedule = Task { [weak self] in
            while !Task.isCancelled {
                self?.checkIfDue()
                try? await Task.sleep(for: .seconds(Self.retry))
            }
        }
    }

    public func stop() {
        schedule?.cancel()
        schedule = nil
    }

    /// One check. Public for tests; the interface uses `check()` and `checkIfDue()`.
    public func check(asked: Bool) async {
        if asked { status = .checking } else { attempted = now() }
        do {
            let latest = try await source.latest()
            guard !Task.isCancelled else { return }
            var next = record
            next.checked = now()
            next.latest = latest
            if asked { next.ignored = nil }
            record = next
            if asked { status = .checked }
        } catch {
            guard !Task.isCancelled else { return }
            if asked { status = .failed(error as? ReleaseError ?? .unreachable) }
        }
    }
}
