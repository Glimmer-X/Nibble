import NibbleCore
import SwiftUI

/// Where answers come from and who answers, as a menu drawn on the board's own cells: the services
/// (the one in use ticked, each with its model), then the personas of the service in use, and a
/// way to settings to manage them, then the model that answers and how hard it thinks; each opens
/// its choices in the same menu. Picking a service keeps the menu open for its personas; picking a
/// persona, a model or a level closes it. Shared by the quick chat's header, the menu bar panel and
/// the sidebar.
struct SourceMenu: View {
    @Environment(AppModel.self) private var app
    /// Closes the menu.
    let done: () -> Void
    /// Opens settings to manage the personas.
    let manage: () -> Void
    /// The choices shown in place of the services and personas, if any.
    @State private var page: Page?

    private enum Page {
        case models
        case thinking
    }

    var body: some View {
        Group {
            switch page {
            case .models: models
            case .thinking: thinking
            case nil: sources
            }
        }
        .padding(.vertical, 8)
        .frame(width: 248, alignment: .leading)
        .background { CellSurface(level: 0.1) }
        .shadow(color: .black.opacity(app.appearance == .dark ? 0.65 : 0.3), radius: 28, y: 20)
        .foregroundStyle(app.colors.ink)
        .task(id: "\(app.settings.backend.kind)|\(app.settings.backend.hermes.profile)") {
            await app.loadModels()
        }
    }

    private var sources: some View {
        let s = app.strings
        let choices = app.personaChoices
        return VStack(alignment: .leading, spacing: 0) {
            MenuLabel(text: s.service)
            ForEach(BackendSettings.Kind.allCases, id: \.self) { kind in
                SourceItem(title: s.backendName(kind), detail: app.sourceDetail(kind), selected: app.settings.backend.kind == kind) {
                    app.choose(source: kind)
                }
            }
            MenuLabel(text: s.persona).padding(.top, 8)
            // A long list of profiles scrolls rather than running off the window.
            ScrollView(.vertical) {
                VStack(spacing: 0) {
                    ForEach(choices) { choice in
                        SourceItem(title: choice.name, selected: choice.selected) {
                            app.choose(choice.pick)
                            done()
                        }
                    }
                }
            }
            .scrollIndicators(.never)
            .frame(height: CGFloat(min(choices.count, 5)) * SourceItem.height)
            if app.settings.backend.kind.isAPI {
                SourceItem(title: s.managePersonas, selected: false, plain: true) {
                    done()
                    manage()
                }
            }
            MenuLabel(text: s.model).padding(.top, 8)
            SourceItem(title: app.currentModel, selected: false, opens: true) {
                page = .models
            }
            MenuLabel(text: s.thinking).padding(.top, 8)
            SourceItem(title: s.thinkingLevel(app.settings.backend.thinking), selected: false, opens: true) {
                page = .thinking
            }
        }
    }

    /// The thinking levels, under a key back to the services.
    private var thinking: some View {
        let s = app.strings
        return VStack(alignment: .leading, spacing: 0) {
            SourceItem(title: s.thinking, selected: false, plain: true, back: true) { page = nil }
            ForEach(ThinkingLevel.allCases, id: \.self) { level in
                SourceItem(title: s.thinkingLevel(level), selected: app.settings.backend.thinking == level) {
                    app.settings.backend.thinking = level
                    done()
                }
            }
        }
    }

    /// The models of the backend in use, under a key back to the services. As tall as the
    /// services page, so the menu keeps its size.
    private var models: some View {
        VStack(alignment: .leading, spacing: 0) {
            SourceItem(title: app.strings.model, selected: false, plain: true, back: true) {
                page = nil
            }
            ModelList(height: Self.modelListHeight, fill: true, picked: done)
        }
    }

    /// Thirteen rows: with the key above, about the height of the services page with a few profiles.
    private static let modelListHeight = 13 * SourceItem.height
}

/// The models of the backend in use (`AppModel.modelGroups`), in rows of the source menu, scrolled
/// to the one in use. Picking one puts it in use. Shared by the source menu and settings.
struct ModelList: View {
    @Environment(AppModel.self) private var app
    /// The most it takes; a shorter list takes its own height unless `fill`.
    let height: CGFloat
    var fill = false
    /// A last row for typing a name instead, when given.
    var manual: (() -> Void)?
    let picked: () -> Void

    var body: some View {
        let groups = app.modelGroups
        let empty = groups.allSatisfy(\.choices.isEmpty)
        let selected = groups.flatMap(\.choices).first { $0.selected }?.id
        let content = groups.reduce(0) { $0 + ($1.title == nil ? 0 : 32) + CGFloat($1.choices.count) * SourceItem.height }
            + (empty ? 24 : 0) + (manual == nil ? 0 : SourceItem.height)
        ScrollViewReader { proxy in
            ScrollView(.vertical) {
                VStack(alignment: .leading, spacing: 0) {
                    if empty { MenuLabel(text: app.strings.noModels) }
                    ForEach(groups) { group in
                        if let title = group.title { MenuLabel(text: title).padding(.top, 8) }
                        ForEach(group.choices) { choice in
                            SourceItem(title: choice.title, detail: choice.detail, selected: choice.selected) {
                                app.choose(choice.pick)
                                picked()
                            }
                            .id(choice.id)
                        }
                    }
                    if let manual {
                        SourceItem(title: app.strings.typeModel, selected: false, plain: true, action: manual)
                    }
                }
            }
            .scrollIndicators(.never)
            .onAppear { if let selected { proxy.scrollTo(selected, anchor: .center) } }
        }
        .frame(height: fill ? height : min(content, height))
    }
}

/// A heading in the source menu.
private struct MenuLabel: View {
    @Environment(AppModel.self) private var app
    let text: String

    var body: some View {
        Text(text).pixelText().foregroundStyle(app.colors.ink2).lineLimit(1)
            .frame(height: 24).padding(.horizontal, 16)
    }
}

/// A row of the source menu: a tick when chosen, the name, and a detail on the right.
private struct SourceItem: View {
    @Environment(AppModel.self) private var app
    static let height: CGFloat = 28
    let title: String
    var detail: String?
    let selected: Bool
    /// A command rather than a choice: no tick column, dimmer.
    var plain = false
    /// Opens more choices: a mark on the right.
    var opens = false
    /// Goes back from those choices: a mark on the left.
    var back = false
    let action: () -> Void
    @State private var hot = false

    var body: some View {
        let colors = app.colors
        Button(action: action) {
            HStack(spacing: 8) {
                if back {
                    DotIconView(icon: .previous)
                } else if !plain {
                    Group {
                        if selected { DotIconView(icon: .check) } else { Color.clear }
                    }
                    .frame(width: 20, height: 14)
                }
                Text(title).pixelText().lineLimit(1).truncationMode(.middle)
                Spacer(minLength: 8)
                if let detail {
                    Text(detail).pixelText().foregroundStyle(colors.ink3).lineLimit(1).truncationMode(.middle)
                }
                if opens { DotIconView(icon: .next).foregroundStyle(colors.ink2) }
            }
            .padding(.horizontal, 16)
            .frame(height: Self.height)
            .background { if hot { CellSurface(level: 0.22, ground: false) } }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(plain ? (hot ? colors.ink : colors.ink2) : colors.ink)
        .onHover { hot = $0 }
    }
}
