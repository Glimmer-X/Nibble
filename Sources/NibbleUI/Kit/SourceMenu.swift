import NibbleCore
import SwiftUI

/// Where answers come from and who answers, as a menu drawn on the board's own cells: the services
/// (the one in use ticked, each with its model), then the personas of the service in use, and a
/// way to settings to manage them. Picking a service keeps the menu open for its personas; picking
/// a persona closes it. Shared by the quick chat's header, the menu bar panel and the sidebar.
struct SourceMenu: View {
    @Environment(AppModel.self) private var app
    /// Closes the menu.
    let done: () -> Void
    /// Opens settings to manage the personas.
    let manage: () -> Void

    var body: some View {
        let s = app.strings
        let colors = app.colors
        let choices = app.personaChoices
        VStack(alignment: .leading, spacing: 0) {
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
            if app.settings.backend.kind.isAPI {
                SourceItem(title: s.managePersonas, selected: false, plain: true) {
                    done()
                    manage()
                }
            }
        }
        .padding(.vertical, 8)
        .frame(width: 248, alignment: .leading)
        .background { CellSurface(level: 0.1) }
        .shadow(color: .black.opacity(app.appearance == .dark ? 0.65 : 0.3), radius: 28, y: 20)
        .foregroundStyle(colors.ink)
        .task(id: app.settings.backend.kind) {
            if app.settings.backend.kind == .hermes { await app.loadProfiles() }
        }
    }

    private struct Label: View {
        @Environment(AppModel.self) private var app
        let text: String

        var body: some View {
            Text(text).pixelText().foregroundStyle(app.colors.ink2)
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
    let action: () -> Void
    @State private var hot = false

    var body: some View {
        let colors = app.colors
        Button(action: action) {
            HStack(spacing: 8) {
                if !plain {
                    Group {
                        if selected { DotIconView(icon: .check) } else { Color.clear }
                    }
                    .frame(width: 20, height: 14)
                }
                Text(title).pixelText().lineLimit(1)
                Spacer(minLength: 8)
                if let detail {
                    Text(detail).pixelText().foregroundStyle(colors.ink3).lineLimit(1).truncationMode(.middle)
                }
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
