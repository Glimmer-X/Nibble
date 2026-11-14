import Foundation

/// Builds backends from settings and answers what the settings page needs to know about them.
/// NibbleBackends implements it; the panel only sees this protocol.
@MainActor
public protocol BackendProvider: AnyObject {
    /// The backend that answers with these settings.
    func backend(for settings: BackendSettings) -> any ChatBackend
    /// The Hermes profiles the reader can pick (each its own personality, model and memory).
    func profiles(for settings: BackendSettings) async -> [String]
    /// The models the Hermes profile in use can answer with, and its own default; nil when Hermes
    /// does not answer.
    func hermesModels(for settings: BackendSettings) async -> HermesModelOptions?
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

/// What a Hermes profile can answer with: its default model, and the providers it is set up for,
/// each with its models, in Hermes's own order.
public struct HermesModelOptions: Sendable, Equatable {
    public struct Provider: Sendable, Equatable, Identifiable {
        /// The provider's id, as requests name it (`gemini`).
        public let id: String
        /// Its name for people (`Google AI Studio`).
        public let name: String
        public let models: [String]

        public init(id: String, name: String, models: [String]) {
            self.id = id
            self.name = name
            self.models = models
        }
    }

    /// The profile's own default; nil when its config names none.
    public let standard: BackendSettings.HermesModel?
    public let providers: [Provider]

    public init(standard: BackendSettings.HermesModel?, providers: [Provider]) {
        self.standard = standard
        self.providers = providers
    }
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
