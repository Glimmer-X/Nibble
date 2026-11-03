import Carbon.HIToolbox
import NibbleCore
import SwiftUI

/// Every setting on one page in the main window: connection, appearance, quick chat, app and data.
/// Rows of 40 pt with labels in a 120 pt column; a group's chosen option is a lit chip, an
/// on/off setting a dot switch. On the right a ruler of short bars of lit board cells, one per
/// section: the section in view is the brightest, the pointer lights a bar and names it, a click
/// scrolls there.
struct SettingsPage: View {
    @Environment(AppModel.self) private var model
    /// Where each section's top is in the scrolling page.
    @State private var tops: [Section: CGFloat] = [:]
    @State private var atBottom = false
    @State private var current = Section.connection

    enum Section: String, CaseIterable, Hashable {
        case connection, look, quickChat, app, data
    }

    var body: some View {
        let s = model.strings
        let colors = model.colors
        ScrollViewReader { proxy in
            HStack(alignment: .top, spacing: 24) {
                ScrollView(.vertical) {
                    VStack(alignment: .leading, spacing: 0) {
                        BackendSection()
                            .modifier(SectionTop(section: .connection, tops: $tops))
                        SettingsSection(title: s.lookSection, section: .look) {
                            Row(s.mode) {
                                ForEach(AppearanceSetting.allCases, id: \.self) { option in
                                    Choice(id: "mode-\(option)", title: s.appearance(option), selected: model.settings.appearance == option) {
                                        model.settings.appearance = option
                                    }
                                }
                            }
                            Row(s.colorLabel) {
                                Flow(spacing: 8, lineSpacing: 8) {
                                    ForEach(ColorTheme.allCases, id: \.self) { theme in
                                        Choice(id: "theme-\(theme)", title: s.theme(theme), selected: model.settings.colorTheme == theme,
                                               swatch: Palette(model.appearance, theme: theme).accent.color) {
                                            model.settings.colorTheme = theme
                                        }
                                    }
                                }
                                .padding(.vertical, 8)
                            }
                            Row(s.textSizeLabel) {
                                ForEach(TextSize.allCases, id: \.self) { size in
                                    Choice(id: "text-\(size)", title: s.textSize(size), selected: model.settings.textSize == size) {
                                        model.settings.textSize = size
                                    }
                                }
                            }
                            Row(s.backgroundLabel) {
                                ForEach(BackgroundMotion.allCases, id: \.self) { motion in
                                    Choice(id: "background-\(motion)", title: s.background(motion), selected: model.settings.background == motion) {
                                        model.settings.background = motion
                                    }
                                }
                            }
                            Row(s.languageLabel) {
                                ForEach(LanguageSetting.allCases, id: \.self) { option in
                                    Choice(id: "lang-\(option)", title: s.language(option), selected: model.settings.language == option) {
                                        model.settings.language = option
                                    }
                                }
                            }
                        }
                        .modifier(SectionTop(section: .look, tops: $tops))
                        SettingsSection(title: s.quickChatSection, section: .quickChat) {
                            Row(s.hotKey) {
                                HotKeyChoice()
                                ConflictNote()
                            }
                            Row(s.send) {
                                ForEach(SendKey.allCases, id: \.self) { key in
                                    Choice(id: "send-\(key)", title: s.sendKey(key), selected: model.settings.sendKey == key) {
                                        model.settings.sendKey = key
                                    }
                                }
                            }
                            Row(s.continueLabel) {
                                ForEach([5, 10, 30], id: \.self) { minutes in
                                    Choice(id: "cont-\(minutes)", title: s.within(minutes: minutes), selected: model.settings.continueWindowMinutes == minutes) {
                                        model.settings.continueWindowMinutes = minutes
                                    }
                                }
                            }
                            Row(s.screenCapture) { CaptureStatus() }
                        }
                        .modifier(SectionTop(section: .quickChat, tops: $tops))
                        SettingsSection(title: s.dockSection, section: .app) {
                            Row(s.showInDock) {
                                DotSwitch(id: "dock", isOn: model.settings.showInDock, label: s.showInDock) { model.settings.showInDock.toggle() }
                            }
                            Row(s.openAtLogin) {
                                DotSwitch(id: "login", isOn: model.opensAtLogin, label: s.openAtLogin) { model.setOpensAtLogin(!model.opensAtLogin) }
                            }
                        }
                        .modifier(SectionTop(section: .app, tops: $tops))
                        SettingsSection(title: s.dataSection, section: .data) {
                            Row(s.keep) {
                                ForEach([7, 30, 90], id: \.self) { days in
                                    Choice(id: "keep-\(days)", title: s.days(days), selected: model.settings.retention.maxAgeDays == days) {
                                        model.settings.retention.maxAgeDays = days
                                    }
                                }
                            }
                            Row(s.location) {
                                Button { model.revealData() } label: {
                                    Text(model.dataFolder.path(percentEncoded: false).replacingOccurrences(of: NSHomeDirectory(), with: "~"))
                                        .pixelText()
                                        .lineLimit(1)
                                        .truncationMode(.middle)
                                        .padding(.horizontal, 8)
                                        .frame(height: 24)
                                        .contentShape(Rectangle())
                                }
                                .buttonStyle(.plain)
                                .foregroundStyle(colors.ink)
                                .boardLight("reveal", .segment, in: .main("body"))
                            }
                        }
                        .modifier(SectionTop(section: .data, tops: $tops))
                        if let notice = model.settingsNotice {
                            Text(notice).pixelText().foregroundStyle(colors.rose).padding(.top, 16)
                        }
                    }
                    .padding(.bottom, 32)
                    .frame(maxWidth: 560, alignment: .leading)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .scrollIndicators(.never)
                .coordinateSpace(.named(Self.space))
                .onScrollGeometryChange(for: Bool.self) { g in
                    g.contentSize.height > g.containerSize.height && g.contentOffset.y + g.containerSize.height >= g.contentSize.height - 4
                } action: { _, bottom in
                    atBottom = bottom
                }
                .boardClip("body")

                // Centred on the window's height: the page starts 112 pt below the window's top.
                SectionRuler(current: current) { section in
                    withAnimation(.easeOut(duration: 0.3)) { proxy.scrollTo(section, anchor: .top) }
                }
                .frame(maxHeight: .infinity)
                .padding(.bottom, 112)
            }
            .onChange(of: tops) { updateCurrent() }
            .onChange(of: atBottom) { updateCurrent() }
        }
        .onAppear {
            model.refreshBackendState()
            model.refreshLoginItem()
            model.refreshCapture()
            model.refreshConflicts()
            Task { await model.loadProfiles() }
        }
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didBecomeKeyNotification)) { _ in model.refreshCapture() }
        .onDisappear { model.recordingHotKey = false }
    }

    nonisolated static let space = "nibble.settings"

    /// The section in view: the last one whose top has reached the top of the page, or the last
    /// section once the page is scrolled to its end.
    private func updateCurrent() {
        if atBottom {
            current = .data
            return
        }
        var next = Section.connection
        for section in Section.allCases where (tops[section] ?? .infinity) <= 24 { next = section }
        current = next
    }
}

/// Reports where a section's top is in the scrolling page, and makes it a target to scroll to.
private struct SectionTop: ViewModifier {
    let section: SettingsPage.Section
    @Binding var tops: [SettingsPage.Section: CGFloat]

    func body(content: Content) -> some View {
        content
            .id(section)
            .onGeometryChange(for: CGFloat.self) { $0.frame(in: .named(SettingsPage.space)).minY } action: { tops[section] = $0 }
    }
}

/// The section ruler: a bar of two lit cells per section, top to bottom. The board draws the
/// bars (each reports itself as whole cells); the section in view is the brightest, the pointer
/// lights a bar and names its section to the left, a click scrolls there.
private struct SectionRuler: View {
    @Environment(AppModel.self) private var model
    let current: SettingsPage.Section
    let go: (SettingsPage.Section) -> Void

    var body: some View {
        VStack(alignment: .trailing, spacing: 11) {
            ForEach(SettingsPage.Section.allCases, id: \.self) { section in
                RulerBar(section: section, current: section == current) { go(section) }
            }
        }
        .frame(width: 19)
    }
}

private struct RulerBar: View {
    @Environment(AppModel.self) private var model
    let section: SettingsPage.Section
    let current: Bool
    let action: () -> Void
    @State private var hot = false

    var body: some View {
        let s = model.strings
        let title = switch section {
        case .connection: s.backendSection
        case .quickChat: s.quickChatSection
        case .app: s.dockSection
        case .look: s.lookSection
        case .data: s.dataSection
        }
        Button(action: action) {
            // Two cells by one; the board lights the nearest whole cells wherever the bar falls.
            Color.clear.frame(width: 19, height: 9).contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hot = $0 }
        .overlay(alignment: .trailing) {
            if hot {
                Text(title).pixelText().foregroundStyle(model.colors.ink).fixedSize()
                    .offset(x: -31)
                    .allowsHitTesting(false)
            }
        }
        .boardLight("ruler-\(section.rawValue)", .cells, in: .main, pressed: current)
        .accessibilityLabel(title)
    }
}

/// What else answers the summon shortcut: a lamp of one rose board cell and a line in rose. The
/// shortcut is kept; this only says so.
private struct ConflictNote: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        if !model.hotKeyConflicts.isEmpty {
            HStack(spacing: 10) {
                Color.clear.frame(width: 9, height: 9).boardLamp("hotkey-conflict", value: 0.6, rose: true)
                Text(model.strings.conflict(model.hotKeyConflicts))
                    .pixelText()
                    .foregroundStyle(model.colors.rose)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            .padding(.leading, 8)
        }
    }
}

/// Whether Nibble may capture the screen, and the way to System Settings when it may not.
private struct CaptureStatus: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let s = model.strings
        let colors = model.colors
        HStack(spacing: 8) {
            Rectangle().fill(model.canCapture ? colors.accent : colors.rose).frame(width: 6, height: 6)
            Text(model.canCapture ? s.allowed : s.notAllowed).pixelText().foregroundStyle(colors.ink2)
        }
        .padding(.leading, 8)
        if !model.canCapture {
            TextKey(id: "capture-settings", title: s.openSystemSettings, place: .main("body")) { model.openCaptureSettings() }
        }
    }
}

/// The backend: which service answers, where it is, its key, and who answers (a Hermes profile,
/// or a model and the reader's persona). Each service keeps its own settings.
private struct BackendSection: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        let s = model.strings
        let kind = model.settings.backend.kind
        SettingsSection(title: s.backendSection, section: .connection) {
            Row(s.service) {
                Flow(spacing: 8, lineSpacing: 8) {
                    ForEach(BackendSettings.Kind.allCases, id: \.self) { option in
                        Choice(id: "backend-\(option)", title: s.backendName(option), selected: kind == option) {
                            model.choose(source: option)
                        }
                    }
                }
                .padding(.vertical, 8)
            }
            Row(s.address) {
                Group {
                    if kind == .hermes {
                        Field(id: "address", text: $model.settings.backend.hermes.address, placeholder: "http://127.0.0.1:8642")
                    } else {
                        Field(id: "address", text: api(kind, \.address), placeholder: kind.officialAddress ?? "https://api.deepseek.com")
                    }
                }
                .id(kind)
                ConnectionBadge()
            }
            Row(s.key) { KeyField().id(kind) }
            if kind == .hermes {
                Row(s.persona) {
                    Flow(spacing: 8, lineSpacing: 8) {
                        ForEach(model.personaChoices) { choice in
                            Choice(id: "persona-\(choice.name)", title: choice.name, selected: choice.selected) {
                                model.choose(choice.pick)
                            }
                        }
                    }
                    .padding(.vertical, 8)
                }
            } else {
                Row(s.model) {
                    Field(id: "model", text: api(kind, \.model), placeholder: Self.modelPlaceholder(kind)).id(kind)
                }
                Row(s.persona) { PersonaEditor() }
            }
        }
    }

    /// A setting of a model's API, for its field.
    private func api(_ kind: BackendSettings.Kind, _ path: WritableKeyPath<BackendSettings.API, String>) -> Binding<String> {
        Binding(
            get: { model.settings.backend[api: kind][keyPath: path] },
            set: { model.settings.backend[api: kind][keyPath: path] = $0 }
        )
    }

    private static func modelPlaceholder(_ kind: BackendSettings.Kind) -> String {
        switch kind {
        case .gemini: "gemini-2.5-flash"
        case .anthropic: "claude-sonnet-5-5"
        case .openAI, .hermes: "deepseek-flash"
        }
    }
}

/// Whether the backend answers: a small lit square and a word.
private struct ConnectionBadge: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let s = model.strings
        let colors = model.colors
        let (text, on): (String, Bool) = switch model.connection {
        case nil: (s.checking, false)
        case .connected: (s.connected, true)
        case .unreachable: (s.unreachable, false)
        case .refused: (s.keyRefused, false)
        case .notSet: (s.notSet, false)
        case .failed: (s.unreachable, false)
        }
        HStack(spacing: 8) {
            Rectangle().fill(on ? colors.accent : colors.rose.opacity(model.connection == nil ? 0 : 1)).frame(width: 6, height: 6)
            Text(text).pixelText().foregroundStyle(colors.ink2).lineLimit(1)
        }
        .fixedSize()
    }
}

/// The key: read from Hermes on this Mac, kept in the Keychain, or to be pasted.
private struct KeyField: View {
    @Environment(AppModel.self) private var model
    @State private var draft = ""

    var body: some View {
        let s = model.strings
        let colors = model.colors
        switch model.keyState {
        case .fromHermes:
            Text(s.keyFromHermes).pixelText().foregroundStyle(colors.ink).padding(.leading, 8)
            Spacer(minLength: 0)
        case .saved:
            Text(s.keySaved).pixelText().foregroundStyle(colors.ink).padding(.leading, 8)
            Spacer(minLength: 0)
            IconKey(id: "key-remove", icon: .cross, label: s.remove, place: .main("body"), size: 24) { model.saveKey(nil) }
        case .missing:
            SecureField(s.keyPlaceholder, text: $draft)
                .textFieldStyle(.plain)
                .font(Typeface.message)
                .foregroundStyle(colors.ink)
                .padding(.horizontal, 8)
                .frame(height: 24)
                .onSubmit { save() }
                .boardLight("key", .segment, in: .main("body"))
            if !draft.isEmpty {
                IconKey(id: "key-save", icon: .check, label: s.save, place: .main("body"), size: 24) { save() }
            }
        }
    }

    private func save() {
        let key = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else { return }
        model.saveKey(key)
        draft = ""
    }
}

/// A plain text field on the board; it lights the cells under it while edited.
private struct Field: View {
    @Environment(AppModel.self) private var model
    let id: String
    @Binding var text: String
    let placeholder: String
    @State private var draft = ""
    @FocusState private var focused: Bool

    var body: some View {
        TextField(placeholder, text: $draft)
            .textFieldStyle(.plain)
            .font(Typeface.message)
            .foregroundStyle(model.colors.ink)
            .padding(.horizontal, 8)
            .frame(height: 24)
            .focused($focused)
            .onAppear { draft = text }
            .onChange(of: text) { if !focused { draft = text } }
            .onSubmit { commit() }
            .onChange(of: focused) { if !focused { commit() } }
            .boardLight(id, .segment, in: .main("body"), pressed: focused)
    }

    private func commit() {
        let value = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        if value != text { text = value }
    }
}

/// The summon shortcut; click it, then press the new combination.
private struct HotKeyChoice: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let s = model.strings
        Choice(id: "hotkey", title: model.recordingHotKey ? s.recording : HotKeyName.describe(model.settings.hotKey), selected: model.recordingHotKey) {
            model.recordingHotKey.toggle()
        }
    }
}

/// A group of rows under its title: the title in the larger pixel face with a steady lamp of one
/// board cell before it; the rows are set in beneath it.
private struct SettingsSection<Content: View>: View {
    @Environment(AppModel.self) private var model
    let title: String
    let section: SettingsPage.Section
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 12) {
                Color.clear.frame(width: 9, height: 9)
                    .boardLamp("section-\(section.rawValue)", value: 0.5)
                Text(title).font(Typeface.pixelSection).foregroundStyle(model.colors.ink)
            }
            .frame(height: 40, alignment: .bottom)
            .padding(.top, 16)
            .padding(.bottom, 4)
            content
        }
    }
}

private struct Row<Content: View>: View {
    @Environment(AppModel.self) private var model
    let label: String
    @ViewBuilder let content: Content

    init(_ label: String, @ViewBuilder content: () -> Content) {
        self.label = label
        self.content = content()
    }

    var body: some View {
        // Labels set in by 24 pt under the section's title; the controls start at 136 pt (wider
        // labels at the large text size).
        HStack(alignment: .top, spacing: 16) {
            Text(label).pixelText().foregroundStyle(model.colors.ink2).lineLimit(1)
                .frame(width: Typeface.rowLabelWidth, height: Typeface.rowHeight, alignment: .leading)
                .padding(.leading, 24)
            HStack(spacing: 8) { content }
                .padding(.leading, -8)
                .frame(maxWidth: .infinity, minHeight: Typeface.rowHeight, alignment: .leading)
        }
    }
}

/// Names of key combinations as shown to the reader: "⌥ Space".
enum HotKeyName {
    static func describe(_ combo: KeyCombo) -> String {
        var mods = ""
        if combo.modifiers.contains(.control) { mods += "⌃" }
        if combo.modifiers.contains(.option) { mods += "⌥" }
        if combo.modifiers.contains(.shift) { mods += "⇧" }
        if combo.modifiers.contains(.command) { mods += "⌘" }
        return "\(mods) \(key(combo.keyCode))"
    }

    static func key(_ code: UInt16) -> String {
        switch Int(code) {
        case kVK_Space: return "Space"
        case kVK_Return: return "Return"
        case kVK_Tab: return "Tab"
        case kVK_Escape: return "Esc"
        default:
            let letters: [Int: String] = [
                kVK_ANSI_A: "A", kVK_ANSI_B: "B", kVK_ANSI_C: "C", kVK_ANSI_D: "D", kVK_ANSI_E: "E", kVK_ANSI_F: "F",
                kVK_ANSI_G: "G", kVK_ANSI_H: "H", kVK_ANSI_I: "I", kVK_ANSI_J: "J", kVK_ANSI_K: "K", kVK_ANSI_L: "L",
                kVK_ANSI_M: "M", kVK_ANSI_N: "N", kVK_ANSI_O: "O", kVK_ANSI_P: "P", kVK_ANSI_Q: "Q", kVK_ANSI_R: "R",
                kVK_ANSI_S: "S", kVK_ANSI_T: "T", kVK_ANSI_U: "U", kVK_ANSI_V: "V", kVK_ANSI_W: "W", kVK_ANSI_X: "X",
                kVK_ANSI_Y: "Y", kVK_ANSI_Z: "Z", kVK_ANSI_0: "0", kVK_ANSI_1: "1", kVK_ANSI_2: "2", kVK_ANSI_3: "3",
                kVK_ANSI_4: "4", kVK_ANSI_5: "5", kVK_ANSI_6: "6", kVK_ANSI_7: "7", kVK_ANSI_8: "8", kVK_ANSI_9: "9",
                kVK_ANSI_Slash: "/", kVK_ANSI_Period: ".", kVK_ANSI_Comma: ",", kVK_ANSI_Semicolon: ";",
            ]
            return letters[Int(code)] ?? "#\(code)"
        }
    }
}
