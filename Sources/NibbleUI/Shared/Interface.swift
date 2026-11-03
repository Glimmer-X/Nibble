import AppKit
import NibbleCore

/// Nibble's whole interface: the floating panel, the main window, the menu bar item and the app's
/// menus, sharing one `AppModel`. The app target builds it and hands it the hotkey's presses.
@MainActor
public final class Interface: NSObject {
    public let panel: PanelController
    public let main: MainWindowController
    let app: AppModel
    private var statusItem: StatusItemController?
    private var monitors: [Any] = []

    public init(
        session: ConversationSession,
        updates: Updates,
        settings: NibbleCore.Settings,
        provider: any BackendProvider,
        services: any SystemServices,
        repository: any ConversationRepository,
        dataFolder: URL,
        onSettingsChange: @escaping (NibbleCore.Settings) -> Void
    ) {
        Typeface.register()
        app = AppModel(session: session, updates: updates, settings: settings, provider: provider, services: services, repository: repository, dataFolder: dataFolder)
        panel = PanelController(app: app)
        main = MainWindowController(app: app)
        super.init()
        app.onSettingsChange = { [weak self] next in
            self?.applyDock()
            self?.installMenus()
            onSettingsChange(next)
        }
        app.openMain = { [weak self] page in self?.main.show(page) }
        app.summonPanel = { [weak self] in self?.panel.summon() }
        app.continueInPanel = { [weak self] conversation in self?.panel.show(conversation) }
        statusItem = StatusItemController(interface: self)
        installMenus()
        applyDock()
        installMonitors()
    }

    /// The summon shortcut was pressed.
    public func hotKeyPressed() {
        guard !app.recordingHotKey else { return }
        panel.toggle()
    }

    /// Opens the main window (the Dock icon was clicked, the app was opened again).
    public func openMain(_ page: MainPage? = nil) {
        main.show(page)
    }

    /// Opens (or closes) the menu bar item's panel, as a click on the item does.
    public func toggleMenu() {
        statusItem?.clicked()
    }

    var menuIsOpen: Bool { statusItem?.menuIsOpen ?? false }

    /// Writes where the window in front is (its number and frame, top left origin) to `path` once
    /// it has settled, for scripts/shot.sh. The window is put in front of other apps' first (a
    /// covered window does not draw its board). Development only.
    public func reportFrontWindow(to path: String, after seconds: Double = 2.5) {
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(seconds))
            let window = NSApp.windows
                .filter { $0.isVisible && $0.alphaValue > 0.99 && $0.frame.width > 200 }
                .max { $0.level.rawValue < $1.level.rawValue }
            guard let window, let screen = NSScreen.screens.first else { return }
            window.orderFrontRegardless()
            try? await Task.sleep(for: .seconds(0.8))
            let f = window.frame
            let line = "\(window.windowNumber) \(Int(f.minX)) \(Int(screen.frame.maxY - f.maxY)) \(Int(f.width)) \(Int(f.height))\n"
            FileManager.default.createFile(atPath: path, contents: Data(line.utf8))
        }
    }

    /// Strings in the interface's language, for the app target's own needs.
    var strings: Strings { app.strings }

    /// Shows Nibble in the Dock, or only in the menu bar, as the settings say.
    private func applyDock() {
        let policy: NSApplication.ActivationPolicy = app.settings.showInDock ? .regular : .accessory
        guard NSApp.activationPolicy() != policy else { return }
        NSApp.setActivationPolicy(policy)
        // Leaving the Dock hides the app's windows with it; bring the main window back.
        if policy == .accessory, main.isVisible {
            DispatchQueue.main.async { [weak self] in self?.main.show() }
        }
    }

    private func installMenus() {
        NSApp.mainMenu = MainMenu.make(app.strings, target: self)
    }

    @objc func openSettings(_ sender: Any?) { main.show(.settings) }
    @objc func openAbout(_ sender: Any?) { main.show(.about) }
    @objc func openHome(_ sender: Any?) { main.show(.home) }
    @objc func showPanel(_ sender: Any?) { panel.summon() }
    @objc func newChat(_ sender: Any?) {
        panel.summon()
        panel.model.newChat()
    }

    /// Recording the summon shortcut (in settings) takes the next key combination with a modifier.
    private func installMonitors() {
        monitors.append(NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, self.app.recordingHotKey else { return event }
            if event.keyCode == 53 { // Esc
                self.app.recordingHotKey = false
                return nil
            }
            var modifiers: KeyCombo.Modifiers = []
            let flags = event.modifierFlags
            if flags.contains(.command) { modifiers.insert(.command) }
            if flags.contains(.option) { modifiers.insert(.option) }
            if flags.contains(.control) { modifiers.insert(.control) }
            if flags.contains(.shift) { modifiers.insert(.shift) }
            guard !modifiers.isEmpty, modifiers != .shift else { return nil }
            self.app.settings.hotKey = KeyCombo(keyCode: event.keyCode, modifiers: modifiers)
            self.app.recordingHotKey = false
            return nil
        } as Any)
    }
}
