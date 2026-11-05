import AppKit
import NibbleBackends
import NibbleCore
import NibbleStore
import NibbleSystem
import NibbleUI
import os

/// The composition root: builds the stores, the session, the interface and the hotkey, and owns
/// them for the life of the app. The only place that knows about every module.
@MainActor
final class AppController {
    private let session: ConversationSession
    private let updates: Updates
    let interface: Interface
    private let settingsStore: SettingsStore
    private var settings: Settings
    private var hotKey: GlobalHotKey?

    private static let log = Logger(subsystem: bundleIdentifier, category: "app")
    private static var bundleIdentifier: String { Bundle.main.bundleIdentifier ?? "com.glimmer.Nibble" }

    static func launch(atLogin: Bool) async -> AppController {
        let paths = AppPaths.standard(bundleIdentifier: bundleIdentifier)
        let store = SettingsStore(paths: paths)
        let settings: Settings
        do {
            settings = try store.load()
        } catch {
            log.error("Settings unreadable, using defaults: \(error.localizedDescription, privacy: .public)")
            settings = Settings()
        }

        let repository = FileConversationRepository(paths: paths)
        do {
            let removed = try await repository.prune(settings.retention, now: Date())
            if removed > 0 { log.info("Pruned \(removed) conversations") }
        } catch {
            log.error("Pruning failed: \(error.localizedDescription, privacy: .public)")
        }
        let restored = try? await repository.latest()
        let backends = Backends(secrets: KeychainSecretStore(service: bundleIdentifier))
        // `-NibbleScript sample|fail|ask` answers from a script, for trying the panel without a model.
        let script = UserDefaults.standard.string(forKey: "NibbleScript")
        let session = ConversationSession(
            backend: script.map(ScriptedBackend.named) ?? backends.backend(for: settings.backend),
            repository: repository,
            continueWindow: settings.continueWindow,
            restoring: restored
        )
        let defaults = UserDefaults.standard
        // `-NibbleRelease 0.2.0` pretends that version is out, to see its notice. Runs answered
        // from a script otherwise neither look nor show what was found before (screenshots stay
        // as they are).
        let pretend = defaults.string(forKey: "NibbleRelease").flatMap(AppVersion.init)
        let quiet = script != nil && pretend == nil
        let updateStore = UpdateStore(paths: paths)
        let updates = Updates(
            current: AppVersion(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "") ?? AppVersion("0")!,
            record: quiet ? UpdateRecord() : updateStore.load(),
            automatic: settings.checkForUpdates,
            source: pretend.map { PretendRelease(version: $0) as any ReleaseSource } ?? GitHubReleases(repository: "Glimmer-X/Nibble")
        )
        updates.onRecordChange = { record in
            do {
                try updateStore.save(record)
            } catch {
                log.error("Update record not saved: \(error.localizedDescription, privacy: .public)")
            }
        }
        let controller = AppController(
            session: session, updates: updates, settings: settings, store: store, repository: repository,
            provider: script.map { ScriptedProvider(base: backends, script: $0) } ?? backends, dataFolder: paths.dataDirectory
        )
        let interface = controller.interface
        // `-NibbleSelfTest <file>` drives the panel and the main window and writes a report
        // (`-NibbleSelfTestParts panel,edges` for only some of it).
        if let report = defaults.string(forKey: "NibbleSelfTest") {
            interface.runSelfTest(writingTo: report, failing: ScriptedBackend.named("fail"), parts: defaults.string(forKey: "NibbleSelfTestParts"))
            return controller
        }
        // `-NibbleDemo <folder>` plays the panel through its moments for scripts/demo.sh.
        if let folder = defaults.string(forKey: "NibbleDemo") {
            interface.runDemo(signals: folder, backends: [
                "answer": ScriptedBackend.named("demo"), "tool": ScriptedBackend.named("demo-tool"),
                "fail": ScriptedBackend.named("demo-fail"), "retry": ScriptedBackend.named("demo-retry"),
            ])
            return controller
        }
        // `-NibblePage home|history|settings|about|sheet|menu|source|strip` opens a page, the menu
        // bar panel, the quick chat's source menu or its strip; `-NibbleShowPanelAtLaunch YES`
        // the panel; `-NibbleAsk "…"` sends a question; `-NibbleSection app` scrolls settings to a
        // section. Otherwise a launch by the reader opens the main window, and a launch at login
        // stays quiet.
        let page = defaults.string(forKey: "NibblePage")
        let question = defaults.string(forKey: "NibbleAsk") ?? ""
        if let page, let main = MainPage(rawValue: page) {
            interface.openMain(main)
        } else if page == "sheet" {
            interface.panel.openSheet()
        } else if page == "menu" {
            interface.toggleMenu()
        } else if defaults.bool(forKey: "NibbleShowPanelAtLaunch") || !question.isEmpty {
            interface.panel.summon()
        } else if !atLogin {
            interface.openMain(.home)
        }
        if !question.isEmpty { interface.panel.ask(question) }
        if page == "source" { interface.panel.openSourceMenu() }
        if page == "strip" { interface.panel.collapseWhenOpen() }
        // `-NibbleWindowFile <file>` reports the window in front for scripts/shot.sh.
        if let file = defaults.string(forKey: "NibbleWindowFile") { interface.reportFrontWindow(to: file) }
        if !quiet { updates.start() }
        return controller
    }

    private init(
        session: ConversationSession,
        updates: Updates,
        settings: Settings,
        store: SettingsStore,
        repository: FileConversationRepository,
        provider: any BackendProvider,
        dataFolder: URL
    ) {
        self.session = session
        self.updates = updates
        self.settings = settings
        self.settingsStore = store
        var apply: (Settings) -> Void = { _ in }
        interface = Interface(
            session: session,
            updates: updates,
            settings: settings,
            provider: provider,
            services: SystemServicesProvider(),
            repository: repository,
            dataFolder: dataFolder,
            onSettingsChange: { apply($0) }
        )
        registerHotKey(settings.hotKey)
        apply = { [weak self] in self?.settingsChanged($0) }
    }

    /// Saves the settings and applies what they touch outside the panel.
    private func settingsChanged(_ next: Settings) {
        let previous = settings
        settings = next
        do {
            try settingsStore.save(next)
        } catch {
            Self.log.error("Settings not saved: \(error.localizedDescription, privacy: .public)")
        }
        session.continueWindow = next.continueWindow
        if next.hotKey != previous.hotKey { registerHotKey(next.hotKey) }
    }

    /// Runs driven by a script (the self-test, the demo's recording, screenshots) leave the shortcut
    /// alone: when two apps register one combination only one of them gets it, and such a run must
    /// not take it from the Nibble in use, not even after it quits.
    private static let scripted = ["NibbleSelfTest", "NibbleDemo", "NibbleWindowFile"]
        .contains { UserDefaults.standard.string(forKey: $0) != nil }

    private func registerHotKey(_ combo: KeyCombo) {
        hotKey?.unregister()
        hotKey = nil
        guard !Self.scripted else { return }
        do {
            hotKey = try GlobalHotKey(combo) { [weak self] in self?.interface.hotKeyPressed() }
        } catch {
            Self.log.error("Hotkey unavailable: \(String(describing: error), privacy: .public)")
        }
    }
}

/// A release that is always out (`-NibbleRelease`), for seeing the notice of a newer version.
private struct PretendRelease: ReleaseSource {
    let version: AppVersion

    func latest() async throws -> Release {
        Release(version: version, page: URL(string: "https://github.com/Glimmer-X/Nibble/releases")!)
    }
}

/// Keeps the scripted backend in place whatever the settings say (`-NibbleScript`).
@MainActor
private final class ScriptedProvider: BackendProvider {
    let base: Backends
    let script: String

    init(base: Backends, script: String) {
        self.base = base
        self.script = script
    }

    func backend(for settings: BackendSettings) -> any ChatBackend { ScriptedBackend.named(script) }
    func profiles(for settings: BackendSettings) async -> [String] { await base.profiles(for: settings) }
    func check(_ settings: BackendSettings) async -> ConnectionStatus { .connected }
    func keyState(for settings: BackendSettings) -> KeyState { base.keyState(for: settings) }
    func saveKey(_ key: String?, for settings: BackendSettings) throws { try base.saveKey(key, for: settings) }
    /// Scripted replies keep nothing anywhere else.
    func forget(remoteSession handle: String, settings: BackendSettings) async throws {}
}
