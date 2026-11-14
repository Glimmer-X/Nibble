import NibbleCore
import SwiftUI

/// Where answers come from and who answers, as a menu drawn on the board's own cells: the services
/// (the one in use ticked, each with its model), then the personas of the service in use, and a
/// way to settings to manage them. With Hermes, the model the profile answers with follows; it
/// opens the models on offer in the same menu. Picking a service keeps the menu open for its
/// personas; picking a persona or a model closes it. Shared by the quick chat's header, the menu
/// bar panel and the sidebar.
struct SourceMenu: View {
    @Environment(AppModel.self) private var app
    /// Closes the menu.
    let done: () -> Void
    /// Opens settings to manage the personas.
    let manage: () -> Void
    /// Showing the Hermes models rather than the services and personas.
    @State private var choosingModel = false

    var body: some View {
        Group {
            if choosingModel { models } else { sources }
        }
        .padding(.vertical, 8)
        .frame(width: 248, alignment: .leading)
        .background { CellSurface(level: 0.1) }
        .shadow(color: .black.opacity(app.appearance == .dark ? 0.65 : 0.3), radius: 28, y: 20)
        .foregroundStyle(app.colors.ink)
        .task(id: "\(app.settings.backend.kind)|\(app.settings.backend.hermes.profile)") {
            guard app.settings.backend.kind == .hermes else { return }
            await app.loadProfiles()
            await app.loadHermesModels()
        }
    }

    private var sources: some View {
        let s = app.strings
        let choices = app.personaChoices
        let hermes = app.settings.backend.kind == .hermes
        return VStack(alignment: .leading, spacing: 0) {
            Label(text: s.service)
            ForEach(BackendSettings.Kind.allCases, id: \.self) { kind in
                SourceItem(title: s.backendName(kind), detail: app.sourceDetail(kind), selected: app.settings.backend.kind == kind) {
                    app.choose(source: kind)
                }
            }
            Label(text: s.persona).padding(.top, 8)
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
            if hermes {
                Label(text: s.model).padding(.top, 8)
                SourceItem(title: app.hermesModel?.model ?? s.defaultModel, selected: false, opens: true) {
                    choosingModel = true
                }
            } else {
                SourceItem(title: s.managePersonas, selected: false, plain: true) {
                    done()
                    manage()
                }
            }
        }
    }

    /// The models of the Hermes profile in use, under a key back to the services. As tall as the
    /// services page, so the menu keeps its size; the list scrolls to the model in use.
    private var models: some View {
        let groups = app.modelGroups
        let selected = groups.flatMap(\.choices).first { $0.selected }?.id
        return VStack(alignment: .leading, spacing: 0) {
            SourceItem(title: app.strings.model, selected: false, plain: true, back: true) {
                choosingModel = false
            }
            ScrollViewReader { proxy in
                ScrollView(.vertical) {
                    VStack(alignment: .leading, spacing: 0) {
                        ForEach(groups) { group in
                            if let title = group.title { Label(text: title).padding(.top, 8) }
                            ForEach(group.choices) { choice in
                                SourceItem(title: choice.title, detail: choice.detail, selected: choice.selected) {
                                    app.choose(hermesModel: choice.model)
                                    done()
                                }
                                .id(choice.id)
                            }
                        }
                    }
                }
                .scrollIndicators(.never)
                .onAppear { if let selected { proxy.scrollTo(selected, anchor: .center) } }
            }
            .frame(height: Self.modelListHeight)
        }
    }

    /// Eleven rows: with the key above, about the height of the services page with a few profiles.
    private static let modelListHeight = 11 * SourceItem.height

    private struct Label: View {
        @Environment(AppModel.self) private var app
        let text: String

        var body: some View {
            Text(text).pixelText().foregroundStyle(app.colors.ink2).lineLimit(1)
                .frame(height: 24).padding(.horizontal, 16)
        }
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
