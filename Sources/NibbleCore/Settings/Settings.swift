import Foundation

/// Everything the user can configure. Stored as JSON by NibbleStore; secrets (API keys) are not
/// here but in the Keychain.
///
/// Decoding fills missing keys with defaults, so adding a setting never breaks an existing file.
public struct Settings: Codable, Sendable, Equatable {
    /// The shortcut that summons and dismisses the panel.
    public var hotKey: KeyCombo
    /// Summoning the panel within this many minutes of the last activity continues the same
    /// conversation; after that a new one starts.
    public var continueWindowMinutes: Int
    public var retention: RetentionPolicy
    public var backend: BackendSettings
    public var appearance: AppearanceSetting
    public var language: LanguageSetting
    /// The chat's height in points, set by dragging its bottom edge.
    public var panelHeight: Double
    /// The panel's width in points, set by dragging its right edge.
    public var panelWidth: Double
    /// Nibble shows in the Dock; otherwise it lives in the menu bar only.
    public var showInDock: Bool
    /// Which key sends a message from the composer.
    public var sendKey: SendKey
    /// The colour of every board and of the interface's accents.
    public var colorTheme: ColorTheme
    /// The light at rest: behind the main window and the menu bar panel, and in the panel while
    /// nothing is happening.
    public var background: BackgroundMotion
    /// How large text is, for reading comfort.
    public var textSize: TextSize
    /// The reader's personas for the model APIs: names with instructions sent as the system prompt.
    public var personas: [Persona]
    /// The persona the model APIs answer as; nil for none (no system prompt).
    public var persona: Persona.ID?
    /// Nibble looks for a newer version once a day.
    public var checkForUpdates: Bool

    public init(
        hotKey: KeyCombo = .optionSpace,
        continueWindowMinutes: Int = 10,
        retention: RetentionPolicy = .standard,
        backend: BackendSettings = BackendSettings(),
        appearance: AppearanceSetting = .system,
        language: LanguageSetting = .system,
        panelHeight: Double = 560,
        panelWidth: Double = 480,
        showInDock: Bool = true,
        sendKey: SendKey = .return,
        colorTheme: ColorTheme = .violet,
        background: BackgroundMotion = .lava,
        textSize: TextSize = .small,
        personas: [Persona] = [],
        persona: Persona.ID? = nil,
        checkForUpdates: Bool = true
    ) {
        self.hotKey = hotKey
        self.continueWindowMinutes = continueWindowMinutes
        self.retention = retention
        self.backend = backend
        self.appearance = appearance
        self.language = language
        self.panelHeight = panelHeight
        self.panelWidth = panelWidth
        self.showInDock = showInDock
        self.sendKey = sendKey
        self.colorTheme = colorTheme
        self.background = background
        self.textSize = textSize
        self.personas = personas
        self.persona = persona
        self.checkForUpdates = checkForUpdates
    }

    public var continueWindow: Duration { .seconds(continueWindowMinutes * 60) }

    /// The persona the model APIs answer as, if it still exists.
    public var currentPersona: Persona? {
        persona.flatMap { id in personas.first { $0.id == id } }
    }

    public init(from decoder: any Decoder) throws {
        let defaults = Settings()
        let c = try decoder.container(keyedBy: CodingKeys.self)
        hotKey = try c.decodeIfPresent(KeyCombo.self, forKey: .hotKey) ?? defaults.hotKey
        continueWindowMinutes = try c.decodeIfPresent(Int.self, forKey: .continueWindowMinutes) ?? defaults.continueWindowMinutes
        retention = try c.decodeIfPresent(RetentionPolicy.self, forKey: .retention) ?? defaults.retention
        backend = try c.decodeIfPresent(BackendSettings.self, forKey: .backend) ?? defaults.backend
        appearance = (try? c.decodeIfPresent(AppearanceSetting.self, forKey: .appearance)) ?? defaults.appearance
        language = (try? c.decodeIfPresent(LanguageSetting.self, forKey: .language)) ?? defaults.language
        panelHeight = try c.decodeIfPresent(Double.self, forKey: .panelHeight) ?? defaults.panelHeight
        panelWidth = try c.decodeIfPresent(Double.self, forKey: .panelWidth) ?? defaults.panelWidth
        showInDock = try c.decodeIfPresent(Bool.self, forKey: .showInDock) ?? defaults.showInDock
        sendKey = (try? c.decodeIfPresent(SendKey.self, forKey: .sendKey)) ?? defaults.sendKey
        colorTheme = (try? c.decodeIfPresent(ColorTheme.self, forKey: .colorTheme)) ?? defaults.colorTheme
        background = (try? c.decodeIfPresent(BackgroundMotion.self, forKey: .background)) ?? defaults.background
        textSize = (try? c.decodeIfPresent(TextSize.self, forKey: .textSize)) ?? defaults.textSize
        personas = (try? c.decodeIfPresent([Persona].self, forKey: .personas)) ?? defaults.personas
        persona = try? c.decodeIfPresent(Persona.ID.self, forKey: .persona)
        checkForUpdates = (try? c.decodeIfPresent(Bool.self, forKey: .checkForUpdates)) ?? defaults.checkForUpdates
    }
}

/// The key that sends a message; the other combination starts a new line.
public enum SendKey: String, Codable, Sendable, CaseIterable {
    /// Return sends, Shift-Return starts a new line.
    case `return`
    /// ⌘Return sends, Return starts a new line.
    case commandReturn
}

/// Nibble's colour. Violet is Nibble's own; the others are LED colours chosen to keep the board's
/// look (see Palette).
public enum ColorTheme: String, Codable, Sendable, CaseIterable {
    case violet, teal, blue, rose, orange, amber
}

/// Text size: small is the designed size; medium enlarges reading text; large also doubles the
/// pixel face's pixels to three device pixels each.
public enum TextSize: String, Codable, Sendable, CaseIterable {
    case small, medium, large
}

/// The light at rest, shared by the main window, the menu bar panel and the idle panel.
public enum BackgroundMotion: String, Codable, Sendable, CaseIterable {
    /// Bodies of light drifting up.
    case lava
    /// Points of light near and far, twinkling.
    case stars
    /// The stars coming slowly toward the viewer.
    case tunnel
    /// Soft pools of light fading in and out here and there.
    case glimmer
    /// Wide, faint rings leaving the middle, like ripples.
    case ripple
}

public enum AppearanceSetting: String, Codable, Sendable, CaseIterable {
    case system
    case light
    case dark
}

public enum LanguageSetting: String, Codable, Sendable, CaseIterable {
    case system
    case chinese
    case english
}

/// Which backend answers, and how to reach each one. Every backend keeps its settings, so
/// switching between them loses nothing. Keys live in the Keychain, not here.
public struct BackendSettings: Codable, Sendable, Equatable {
    public enum Kind: String, Codable, Sendable, CaseIterable {
        /// Hermes Agent's API server.
        case hermes
        /// Any endpoint that speaks the OpenAI chat completions API (DeepSeek, Ollama, OpenRouter, …).
        case openAI
        /// Google's Gemini API.
        case gemini
        /// Anthropic's Claude API.
        case anthropic

        /// A model's API, answering as the reader's personas (Hermes has profiles of its own).
        public var isAPI: Bool { self != .hermes }

        /// Where the API is when its address is left empty (none for the OpenAI-compatible kind).
        public var officialAddress: String? {
            switch self {
            case .gemini: "https://generativelanguage.googleapis.com"
            case .anthropic: "https://api.anthropic.com"
            case .hermes, .openAI: nil
            }
        }
    }

    /// The backend in use.
    public var kind: Kind
    public var hermes: Hermes
    public var openAI: API
    public var gemini: API
    public var anthropic: API

    public init(kind: Kind = .hermes, hermes: Hermes = Hermes(), openAI: API = API(), gemini: API = API(), anthropic: API = API()) {
        self.kind = kind
        self.hermes = hermes
        self.openAI = openAI
        self.gemini = gemini
        self.anthropic = anthropic
    }

    /// The settings of a model's API (empty for Hermes).
    public subscript(api kind: Kind) -> API {
        get {
            switch kind {
            case .openAI: openAI
            case .gemini: gemini
            case .anthropic: anthropic
            case .hermes: API()
            }
        }
        set {
            switch kind {
            case .openAI: openAI = newValue
            case .gemini: gemini = newValue
            case .anthropic: anthropic = newValue
            case .hermes: break
            }
        }
    }

    /// The address a model's API is reached at: the one set, or its official one.
    public func address(_ kind: Kind) -> String {
        let set = self[api: kind].address
        return set.isEmpty ? kind.officialAddress ?? "" : set
    }

    public struct Hermes: Codable, Sendable, Equatable {
        /// The API server, `http://127.0.0.1:8642` unless the gateway was set up elsewhere.
        public var address: String
        /// The Hermes profile that answers (its own personality, model and memory).
        public var profile: String
        /// The model each profile answers with, by profile, when the reader picked one; a profile
        /// left out answers with its own default. Sent with each question; Hermes's config is
        /// left as it is.
        public var models: [String: HermesModel]
        /// Models the reader picked lately, the latest first (at most `recentLimit`).
        public var recent: [HermesModel]

        public static let recentLimit = 5

        public init(
            address: String = "http://127.0.0.1:8642",
            profile: String = "default",
            models: [String: HermesModel] = [:],
            recent: [HermesModel] = []
        ) {
            self.address = address
            self.profile = profile
            self.models = models
            self.recent = recent
        }

        /// The model the profile in use answers with, if the reader picked one.
        public var model: HermesModel? { models[profile] }

        /// Puts `model` in use for the profile in use; nil goes back to the profile's default.
        public mutating func choose(_ model: HermesModel?) {
            models[profile] = model
            guard let model else { return }
            recent.removeAll { $0 == model }
            recent.insert(model, at: 0)
            recent = Array(recent.prefix(Self.recentLimit))
        }

        public init(from decoder: any Decoder) throws {
            let defaults = Hermes()
            let c = try decoder.container(keyedBy: CodingKeys.self)
            address = try c.decodeIfPresent(String.self, forKey: .address) ?? defaults.address
            profile = try c.decodeIfPresent(String.self, forKey: .profile) ?? defaults.profile
            models = (try? c.decodeIfPresent([String: HermesModel].self, forKey: .models)) ?? [:]
            recent = Array(((try? c.decodeIfPresent([HermesModel].self, forKey: .recent)) ?? []).prefix(Self.recentLimit))
        }
    }

    /// A model as Hermes names it: the provider it goes through (`gemini`, `openrouter`, a
    /// provider of the reader's own) and the model's id there.
    public struct HermesModel: Codable, Sendable, Hashable {
        public var provider: String
        public var model: String

        public init(provider: String, model: String) {
            self.provider = provider
            self.model = model
        }
    }

    /// A model's API: where it is and which model answers.
    public struct API: Codable, Sendable, Equatable {
        /// The API's base address (for the OpenAI-compatible kind, before `/chat/completions`,
        /// e.g. `https://api.deepseek.com`). Empty means the official address.
        public var address: String
        public var model: String

        public init(address: String = "", model: String = "") {
            self.address = address
            self.model = model
        }

        public init(from decoder: any Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            address = try c.decodeIfPresent(String.self, forKey: .address) ?? ""
            model = try c.decodeIfPresent(String.self, forKey: .model) ?? ""
        }
    }

    public init(from decoder: any Decoder) throws {
        let defaults = BackendSettings()
        let c = try decoder.container(keyedBy: CodingKeys.self)
        kind = (try? c.decodeIfPresent(Kind.self, forKey: .kind)) ?? defaults.kind
        hermes = try c.decodeIfPresent(Hermes.self, forKey: .hermes) ?? defaults.hermes
        openAI = try c.decodeIfPresent(API.self, forKey: .openAI) ?? defaults.openAI
        gemini = try c.decodeIfPresent(API.self, forKey: .gemini) ?? defaults.gemini
        anthropic = try c.decodeIfPresent(API.self, forKey: .anthropic) ?? defaults.anthropic
    }
}

/// How much conversation history Nibble keeps. Older or excess conversations are deleted,
/// attachments included.
public struct RetentionPolicy: Codable, Sendable, Equatable {
    public var maxAgeDays: Int
    public var maxConversations: Int

    public init(maxAgeDays: Int, maxConversations: Int) {
        self.maxAgeDays = maxAgeDays
        self.maxConversations = maxConversations
    }

    public static let standard = RetentionPolicy(maxAgeDays: 30, maxConversations: 200)

    public var maxAge: TimeInterval { TimeInterval(maxAgeDays) * 86_400 }
}

/// A key plus modifiers, independent of any hotkey API.
public struct KeyCombo: Codable, Sendable, Hashable {
    public struct Modifiers: OptionSet, Codable, Sendable, Hashable {
        public let rawValue: Int
        public init(rawValue: Int) { self.rawValue = rawValue }

        public static let command = Modifiers(rawValue: 1 << 0)
        public static let option = Modifiers(rawValue: 1 << 1)
        public static let control = Modifiers(rawValue: 1 << 2)
        public static let shift = Modifiers(rawValue: 1 << 3)
    }

    /// macOS virtual key code (the `kVK_*` constants).
    public var keyCode: UInt16
    public var modifiers: Modifiers

    public init(keyCode: UInt16, modifiers: Modifiers) {
        self.keyCode = keyCode
        self.modifiers = modifiers
    }

    /// ⌥Space. kVK_Space is 0x31.
    public static let optionSpace = KeyCombo(keyCode: 0x31, modifiers: .option)
}
