import Foundation
import NibbleCore

/// Loads and saves `Settings` as `settings.json` in the data directory.
public struct SettingsStore: Sendable {
    public let file: URL

    public init(paths: AppPaths) {
        self.file = paths.settingsFile
    }

    /// The saved settings, or the defaults when nothing has been saved yet.
    public func load() throws -> Settings {
        try JSONFile.read(Settings.self, from: file) ?? Settings()
    }

    public func save(_ settings: Settings) throws {
        try JSONFile.write(settings, to: file)
    }
}
