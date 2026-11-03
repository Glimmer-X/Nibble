import Foundation

/// Every location where Nibble keeps user data. Nothing else in the app builds paths.
///
/// Layout under `dataDirectory`:
///
///     settings.json
///     conversations/<conversation-id>/conversation.json
///     conversations/<conversation-id>/attachments/<attachment-id>
///
/// Secrets (API keys) never go here; they belong in the Keychain.
public struct AppPaths: Sendable, Equatable {
    public let dataDirectory: URL

    public init(dataDirectory: URL) {
        self.dataDirectory = dataDirectory
    }

    /// `~/Library/Application Support/<bundle identifier>`. Debug builds have their own bundle
    /// identifier, so they never touch the data of an installed release.
    ///
    /// `NIBBLE_DATA_DIR` overrides the location (tests, tools, a throwaway profile).
    public static func standard(
        bundleIdentifier: String,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> AppPaths {
        if let override = environment["NIBBLE_DATA_DIR"], !override.isEmpty {
            return AppPaths(dataDirectory: URL(filePath: override, directoryHint: .isDirectory))
        }
        let support = URL.applicationSupportDirectory
        return AppPaths(dataDirectory: support.appending(path: bundleIdentifier, directoryHint: .isDirectory))
    }

    public var settingsFile: URL {
        dataDirectory.appending(path: "settings.json", directoryHint: .notDirectory)
    }

    public var conversationsDirectory: URL {
        dataDirectory.appending(path: "conversations", directoryHint: .isDirectory)
    }
}
