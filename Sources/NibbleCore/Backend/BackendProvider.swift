import Foundation

/// Builds backends from settings and answers what the settings page needs to know about them.
/// NibbleBackends implements it; the panel only sees this protocol.
@MainActor
public protocol BackendProvider: AnyObject {
    /// The backend that answers with these settings.
    func backend(for settings: BackendSettings) -> any ChatBackend
    /// The Hermes profiles the reader can pick (each its own personality, model and memory).
    func profiles(for settings: BackendSettings) async -> [String]
    /// Whether the backend answers and accepts the key.
    func check(_ settings: BackendSettings) async -> ConnectionStatus
    /// Where the key for these settings comes from.
    func keyState(for settings: BackendSettings) -> KeyState
    /// Saves a key the reader pasted (nil removes it).
    func saveKey(_ key: String?, for settings: BackendSettings) throws
    /// Deletes what a backend keeps of a conversation on its side (a Hermes session), given the
    /// handle it issued (`Conversation.remoteSessionID`). The address and key come from
    /// `settings`, whichever backend is in use now.
    func forget(remoteSession handle: String, settings: BackendSettings) async throws
}

public enum ConnectionStatus: Sendable, Equatable {
    case connected
    /// Nothing answered at the address.
    case unreachable
    /// The backend answered but refused the key.
    case refused
    /// The settings are not filled in yet.
    case notSet
    /// Something else went wrong.
    case failed(String)
}

public enum KeyState: Sendable, Equatable {
    /// Read from the Hermes profile's own `.env` on this Mac.
    case fromHermes
    /// The reader saved one in the Keychain.
    case saved
    case missing
}
