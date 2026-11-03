import Foundation
import NibbleCore

/// Makes the backend in use and tells the settings page about it: the Hermes profiles on offer,
/// whether it answers, where its key comes from.
///
/// Keys: a key pasted into Nibble is kept in the Keychain (one per backend kind and address, and
/// per Hermes profile). With Hermes on this Mac and no pasted key, the profile's own
/// `API_SERVER_KEY` is read from its `.env`.
@MainActor
public final class Backends: BackendProvider {
    private let secrets: any SecretStore
    private let hermesHome: HermesDirectory

    public init(secrets: any SecretStore, hermesHome: HermesDirectory = HermesDirectory()) {
        self.secrets = secrets
        self.hermesHome = hermesHome
    }

    public func backend(for settings: BackendSettings) -> any ChatBackend {
        let kind = settings.kind
        let address = settings.address(kind)
        let model = settings[api: kind].model
        return switch kind {
        case .hermes: HermesBackend(address: settings.hermes.address, profile: settings.hermes.profile, apiKey: key(for: settings))
        case .openAI: OpenAICompatibleBackend(address: address, model: model, apiKey: key(for: settings))
        case .gemini: GeminiBackend(address: address, model: model, apiKey: key(for: settings))
        case .anthropic: AnthropicBackend(address: address, model: model, apiKey: key(for: settings))
        }
    }

    public func profiles(for settings: BackendSettings) async -> [String] {
        let profiles = hermesHome.profiles()
        return profiles.isEmpty ? [settings.hermes.profile] : profiles
    }

    public func check(_ settings: BackendSettings) async -> ConnectionStatus {
        let kind = settings.kind
        let address = settings.address(kind)
        do {
            switch kind {
            case .hermes:
                try await HermesBackend(address: settings.hermes.address, profile: settings.hermes.profile, apiKey: key(for: settings)).check()
            case .openAI:
                guard !address.isEmpty else { return .notSet }
                _ = try await OpenAICompatibleBackend(address: address, model: "", apiKey: key(for: settings)).models()
            case .gemini:
                guard key(for: settings) != nil else { return .notSet }
                _ = try await GeminiBackend(address: address, model: "", apiKey: key(for: settings)).models()
            case .anthropic:
                guard key(for: settings) != nil else { return .notSet }
                _ = try await AnthropicBackend(address: address, model: "", apiKey: key(for: settings)).models()
            }
            return .connected
        } catch BackendError.notConfigured {
            return .notSet
        } catch BackendError.unauthorized {
            return .refused
        } catch BackendError.cannotConnect, BackendError.timedOut {
            return .unreachable
        } catch BackendError.server(let status, let message) {
            return .failed(message ?? "\(status)")
        } catch {
            return .failed(String(describing: error))
        }
    }

    public func keyState(for settings: BackendSettings) -> KeyState {
        if let saved = secrets.secret(for: account(settings)), !saved.isEmpty { return .saved }
        if settings.kind == .hermes, isLocal(settings.hermes.address), hermesHome.apiKey(for: settings.hermes.profile) != nil {
            return .fromHermes
        }
        return .missing
    }

    public func saveKey(_ key: String?, for settings: BackendSettings) throws {
        try secrets.setSecret(key?.trimmingCharacters(in: .whitespacesAndNewlines), for: account(settings))
    }

    public func forget(remoteSession handle: String, settings: BackendSettings) async throws {
        // Only Hermes keeps conversations on its side; its handles name the profile.
        guard let (profile, session) = HermesBackend.parse(handle: handle) else { return }
        var hermes = settings
        hermes.kind = .hermes
        hermes.hermes.profile = profile
        try await HermesBackend(address: settings.hermes.address, profile: profile, apiKey: key(for: hermes)).forget(session: session)
    }

    private func key(for settings: BackendSettings) -> String? {
        if let saved = secrets.secret(for: account(settings)), !saved.isEmpty { return saved }
        if settings.kind == .hermes, isLocal(settings.hermes.address) {
            return hermesHome.apiKey(for: settings.hermes.profile)
        }
        return nil
    }

    /// The Keychain account for the key of the backend in use.
    private func account(_ settings: BackendSettings) -> String {
        switch settings.kind {
        case .hermes: "hermes:\(host(settings.hermes.address)):\(settings.hermes.profile)"
        case .openAI: "openai:\(host(settings.address(.openAI)))"
        case .gemini: "gemini:\(host(settings.address(.gemini)))"
        case .anthropic: "anthropic:\(host(settings.address(.anthropic)))"
        }
    }

    private func host(_ address: String) -> String {
        HTTP.url(address, "").map { HTTP.address($0) } ?? address
    }

    private func isLocal(_ address: String) -> Bool {
        guard let host = HTTP.url(address, "")?.host() else { return false }
        return host == "127.0.0.1" || host == "localhost" || host == "::1"
    }
}
