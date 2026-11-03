import Foundation
import NibbleCore

/// Loads and saves what the update checks found (`UpdateRecord`) as `updates.json` in the data
/// directory: one small file, replaced on every change.
public struct UpdateStore: Sendable {
    public let file: URL

    public init(paths: AppPaths) {
        self.file = paths.updatesFile
    }

    /// The saved record; an empty one when nothing was saved or the file cannot be read.
    public func load() -> UpdateRecord {
        (try? JSONFile.read(UpdateRecord.self, from: file)) ?? UpdateRecord()
    }

    public func save(_ record: UpdateRecord) throws {
        try JSONFile.write(record, to: file)
    }
}
