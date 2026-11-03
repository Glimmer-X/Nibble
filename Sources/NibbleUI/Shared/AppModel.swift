import AppKit
import NibbleCore
import Observation
import OSLog
import SwiftUI

/// The pages of the main window.
public enum MainPage: String, CaseIterable, Sendable {
    case home
    case history
    case settings
    /// At the foot of the sidebar.
    case about
}

/// What every window of Nibble shares: the settings, the language and colours, the backend's
/// state, the saved conversations, and the ways to reach the other windows.
@MainActor
@Observable
final class AppModel {
    private static let log = Logger(subsystem: Bundle.main.bundleIdentifier ?? "Nibble", category: "history")

    let session: ConversationSession
    /// Looks for a newer Nibble; its notice shows in the panel's conversation page, the menu bar
    /// panel and settings.
    let updates: Updates
    @ObservationIgnored let provider: any BackendProvider
    @ObservationIgnored let services: any SystemServices
    @ObservationIgnored let repository: any ConversationRepository
    @ObservationIgnored let dataFolder: URL
    /// Called when the reader changes a setting; the app saves it and applies what it touches.
    @ObservationIgnored var onSettingsChange: (NibbleCore.Settings) -> Void = { _ in }
    /// Set by `Interface`: open the main window on a page, show the panel, open a conversation in it.
    @ObservationIgnored var openMain: (MainPage) -> Void = { _ in }
    @ObservationIgnored var summonPanel: () -> Void = {}
    @ObservationIgnored var continueInPanel: (Conversation) -> Void = { _ in }

    var settings: NibbleCore.Settings {
        didSet {
            guard settings != oldValue else { return }
            applySettings(old: oldValue)
        }
    }

    var language: Language
    var strings: Strings { Strings(language: language) }
    /// The appearance the system is in; Nibble follows it unless a setting says otherwise.
    var systemAppearance: Appearance
    var appearance: Appearance {
        switch settings.appearance {
        case .system: systemAppearance
        case .light: .light
        case .dark: .dark
        }
    }

    var palette: Palette { Palette(appearance, theme: settings.colorTheme) }
    var colors: PanelColors { PanelColors(palette) }

    /// The Hermes profiles on offer (loaded while Hermes is in use).
    var profiles: [String] = []
    var connection: ConnectionStatus?
    var keyState: KeyState = .missing
    /// The shortcut key is waiting for a new combination.
    var recordingHotKey = false
    var opensAtLogin = false
    /// Nibble may capture the screen (the composer's capture key).
    var canCapture = false
    /// What else answers the summon shortcut.
    var hotKeyConflicts: [HotKeyConflict] = []
    /// A short note about a setting that could not be applied.
    var settingsNotice: String?

    /// Saved conversations, the most recently updated first.
    var history: [Conversation] = []
    var historyLoaded = false

    @ObservationIgnored private var checkTask: Task<Void, Never>?
    @ObservationIgnored private var historyTask: Task<Void, Never>?
    @ObservationIgnored private var appearanceObservation: NSKeyValueObservation?

    init(
        session: ConversationSession,
        updates: Updates,
        settings: NibbleCore.Settings,
        provider: any BackendProvider,
        services: any SystemServices,
        repository: any ConversationRepository,
        dataFolder: URL
    ) {
        self.session = session
        self.updates = updates
        self.settings = settings
        self.provider = provider
        self.services = services
        self.repository = repository
        self.dataFolder = dataFolder
        language = Language(settings.language)
        TextScale.shared.size = settings.textSize
        systemAppearance = Self.currentSystemAppearance()
        session.backend = provider.backend(for: settings.backend)
        applyPersona()
        session.describeError = { [weak self] error in
            guard let self else { return error.localizedDescription }
            return self.strings.describe(error, backend: self.settings.backend.kind)
        }
        appearanceObservation = NSApp.observe(\.effectiveAppearance) { [weak self] _, _ in
            MainActor.assumeIsolated { self?.systemAppearance = Self.currentSystemAppearance() }
        }
    }

    private static func currentSystemAppearance() -> Appearance {
        NSApp.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? .dark : .light
    }

    // MARK: - The backend

    /// Where answers come from: "Hermes", "Gemini" …
    var sourceName: String { strings.backendName(settings.backend.kind) }

    /// Who answers: the Hermes profile, or the reader's persona ("Default" for none).
    var currentPersona: String {
        let backend = settings.backend
        guard backend.kind.isAPI else { return backend.hermes.profile }
        return settings.currentPersona.map { strings.personaName($0) } ?? strings.noPersona
    }

    /// "Hermes · general", "Gemini · Default".
    var personaLabel: String { "\(sourceName) · \(currentPersona)" }

    /// One persona the reader can pick for the backend in use.
    struct PersonaChoice: Identifiable, Hashable {
        enum Pick: Hashable {
            case profile(String)
            case persona(Persona.ID?)
        }

        let pick: Pick
        let name: String
        let selected: Bool
        var id: Pick { pick }
    }

    /// The Hermes profiles, or "Default" and the reader's personas.
    var personaChoices: [PersonaChoice] {
        let backend = settings.backend
        guard backend.kind.isAPI else {
            let names = profiles.isEmpty ? [backend.hermes.profile] : profiles
            return names.map { PersonaChoice(pick: .profile($0), name: $0, selected: $0 == backend.hermes.profile) }
        }
        let current = settings.currentPersona?.id
        return [PersonaChoice(pick: .persona(nil), name: strings.noPersona, selected: current == nil)]
            + settings.personas.map { PersonaChoice(pick: .persona($0.id), name: strings.personaName($0), selected: $0.id == current) }
    }

    func choose(_ pick: PersonaChoice.Pick) {
        switch pick {
        case .profile(let name): settings.backend.hermes.profile = name
        case .persona(let id): settings.persona = id
        }
    }

    /// Switches the backend in use; each keeps its own settings.
    func choose(source kind: BackendSettings.Kind) {
        settings.backend.kind = kind
    }

    /// What a backend is set to, for menus: the model of an API ("Not set" without one), Hermes'
    /// address.
    func sourceDetail(_ kind: BackendSettings.Kind) -> String {
        guard kind.isAPI else { return settings.backend.hermes.address.replacingOccurrences(of: "http://", with: "") }
        let model = settings.backend[api: kind].model
        return model.isEmpty ? strings.notSet : model
    }

    /// The label kept with conversations and the system prompt, from the backend and persona in use.
    private func applyPersona() {
        let backend = settings.backend
        if backend.kind.isAPI, let persona = settings.currentPersona {
            session.persona = strings.personaName(persona)
            session.instructions = persona.prompt
        } else {
            let model = backend[api: backend.kind].model
            session.persona = backend.kind.isAPI ? (model.isEmpty ? sourceName : model) : backend.hermes.profile
            session.instructions = nil
        }
    }

    private func applySettings(old: NibbleCore.Settings) {
        language = Language(settings.language)
        TextScale.shared.size = settings.textSize
        if settings.hotKey != old.hotKey { refreshConflicts() }
        if settings.checkForUpdates != old.checkForUpdates {
            updates.automatic = settings.checkForUpdates
            updates.checkIfDue()
        }
        if settings.backend != old.backend {
            session.backend = provider.backend(for: settings.backend)
            if settings.backend.hermes.address != old.backend.hermes.address { profiles = [] }
            refreshBackendState()
        }
        applyPersona()
        onSettingsChange(settings)
    }

    // MARK: - Personas

    /// Adds a persona with a name of its own and puts it in use.
    @discardableResult
    func addPersona() -> Persona {
        let taken = Set(settings.personas.map(\.name))
        var name = strings.newPersona
        var n = 2
        while taken.contains(name) {
            name = "\(strings.newPersona) \(n)"
            n += 1
        }
        let persona = Persona(name: name)
        settings.personas.append(persona)
        settings.persona = persona.id
        return persona
    }

    func save(_ persona: Persona) {
        guard let index = settings.personas.firstIndex(where: { $0.id == persona.id }) else { return }
        settings.personas[index] = persona
    }

    /// Deletes a persona; answers go back to no persona if it was in use.
    func deletePersona(_ id: Persona.ID) {
        settings.personas.removeAll { $0.id == id }
        if settings.persona == id { settings.persona = nil }
    }

    /// Checks the connection and where the key comes from, after the reader stops typing.
    func refreshBackendState() {
        keyState = provider.keyState(for: settings.backend)
        connection = nil
        checkTask?.cancel()
        let backend = settings.backend
        checkTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(600))
            guard !Task.isCancelled, let self else { return }
            let status = await provider.check(backend)
            guard !Task.isCancelled, backend == self.settings.backend else { return }
            connection = status
            if status == .connected, backend.kind == .hermes { await loadProfiles() }
        }
    }

    func saveKey(_ key: String?) {
        do {
            try provider.saveKey(key, for: settings.backend)
            session.backend = provider.backend(for: settings.backend)
            settingsNotice = nil
            refreshBackendState()
        } catch {
            settingsNotice = String(describing: error)
        }
    }

    func loadProfiles() async {
        let list = await provider.profiles(for: settings.backend)
        profiles = list
    }

    // MARK: - The app

    func refreshLoginItem() {
        opensAtLogin = services.opensAtLogin
    }

    func setOpensAtLogin(_ on: Bool) {
        do {
            try services.setOpensAtLogin(on)
            settingsNotice = nil
        } catch {
            settingsNotice = strings.loginItemFailed
        }
        refreshLoginItem()
    }

    func revealData() {
        services.reveal(dataFolder)
    }

    @ObservationIgnored private var conflictTask: Task<Void, Never>?

    /// Looks again for what else answers the summon shortcut.
    func refreshConflicts() {
        conflictTask?.cancel()
        let combo = settings.hotKey
        conflictTask = Task { [weak self, services] in
            let found = await services.hotKeyConflicts(combo)
            guard !Task.isCancelled, let self, combo == self.settings.hotKey else { return }
            hotKeyConflicts = found
        }
    }

    func refreshCapture() {
        canCapture = services.canCaptureScreen(ask: false)
    }

    func openCaptureSettings() {
        services.openScreenCaptureSettings()
    }

    /// Opens the download page of the newer release.
    func openRelease() {
        guard let page = updates.newer?.page else { return }
        NSWorkspace.shared.open(page)
    }

    /// "0.1.0" and "1", from the app's Info.plist.
    var version: (version: String, build: String) {
        let info = Bundle.main.infoDictionary ?? [:]
        return (info["CFBundleShortVersionString"] as? String ?? "–", info["CFBundleVersion"] as? String ?? "–")
    }

    // MARK: - Saved conversations

    /// Reads the saved conversations again (after a reply, when a window that lists them opens).
    func reloadHistory() {
        historyTask?.cancel()
        historyTask = Task { [weak self, repository] in
            let all = (try? await repository.all()) ?? []
            guard !Task.isCancelled, let self else { return }
            history = all.filter { !$0.isEmpty }
            historyLoaded = true
        }
    }

    /// Puts a conversation that was just saved at the top of the list.
    func remember(_ conversation: Conversation) {
        guard historyLoaded, !conversation.isEmpty else { return }
        history.removeAll { $0.id == conversation.id }
        history.insert(conversation, at: 0)
    }

    /// Deletes a saved conversation with its attachments, and its Hermes session. The panel's
    /// current conversation starts over if it was this one.
    func delete(_ conversation: Conversation) {
        var doomed = conversation
        if session.conversation.id == conversation.id {
            // The panel's copy may have its Hermes session before the saved one does.
            doomed = session.conversation
            session.discardConversation()
        }
        history.removeAll { $0.id == conversation.id }
        erase([doomed])
    }

    /// Deletes every saved conversation with its attachments and Hermes sessions, and the
    /// panel's conversation, saved or not.
    func deleteAll() {
        var doomed = history.filter { $0.id != session.conversation.id }
        if !session.conversation.isEmpty {
            doomed.append(session.conversation)
            session.discardConversation()
        }
        history = []
        erase(doomed)
    }

    /// Deletes conversations from disk, then their Hermes sessions. Nibble's copies go whatever
    /// happens; a Hermes that cannot be reached keeps its own (the failure is logged).
    private func erase(_ conversations: [Conversation]) {
        let ids = conversations.map(\.id)
        let handles = conversations.compactMap(\.remoteSessionID)
        let settings = settings.backend
        Task { [repository, provider] in
            for id in ids { try? await repository.delete(id: id) }
            for handle in handles {
                do {
                    try await provider.forget(remoteSession: handle, settings: settings)
                } catch {
                    Self.log.error("Could not delete \(handle, privacy: .public) from Hermes: \(String(describing: error), privacy: .public)")
                }
            }
        }
    }

    /// The bytes of an attachment of a saved conversation.
    func data(for attachment: Attachment, in conversation: Conversation) async -> Data? {
        try? await repository.attachmentData(attachment, in: conversation.id)
    }
}
