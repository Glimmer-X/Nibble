import NibbleCore
import SwiftUI

/// The main window's content: the sidebar with its three pages, and the page. Everything floats
/// on the window's board; nothing here paints a surface except the source menu.
struct MainRootView: View {
    @Environment(MainModel.self) private var model
    @Environment(AppModel.self) private var app

    var body: some View {
        let colors = app.colors
        GeometryReader { geometry in
            ZStack(alignment: .bottomLeading) {
                content
                if model.sourceOpen {
                    Color.clear.contentShape(Rectangle()).onTapGesture { model.sourceOpen = false }
                    // Above the sidebar's source key.
                    SourceMenu(done: { model.sourceOpen = false }) {
                        withAnimation(.easeOut(duration: 0.28)) { model.go(to: .settings) }
                    }
                    .padding(.leading, model.sourceAnchor.minX)
                    .padding(.bottom, geometry.size.height - model.sourceAnchor.minY + 6)
                }
            }
        }
        .coordinateSpace(.named(BoardSpace.name))
        .foregroundStyle(colors.ink)
        .environment(\.colorScheme, app.appearance == .dark ? .dark : .light)
    }

    private var content: some View {
        HStack(alignment: .top, spacing: 0) {
            Sidebar()
                .frame(width: 200)
            VStack(alignment: .leading, spacing: 0) {
                Text(app.strings.page(model.page))
                    .font(Typeface.pixelLarge)
                    .frame(height: 32, alignment: .leading)
                    .padding(.bottom, 24)
                Group {
                    switch model.page {
                    case .home: HomePage()
                    case .history: HistoryPage()
                    case .settings: SettingsPage()
                    case .about: AboutPage()
                    }
                }
                .id(model.page)
                .transition(.opacity.combined(with: .offset(x: 16)))
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            }
            .padding(.top, 56)
            .padding(.leading, 24)
            .padding(.trailing, 40)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}

/// The sidebar: Nibble's mark, the pages (the open one on a plate of lit cells), and at the foot
/// who answers (a key to change the service and persona) and About.
private struct Sidebar: View {
    @Environment(MainModel.self) private var model
    @Environment(AppModel.self) private var app

    var body: some View {
        let colors = app.colors
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 10) {
                NibbleMark(pitch: 3, dot: 2).foregroundStyle(colors.accent)
                Text("Nibble").pixelText()
            }
            .frame(height: 32)
            .padding(.horizontal, 16)
            .padding(.bottom, 24)

            ForEach([MainPage.home, .history, .settings], id: \.self) { page in
                PageItem(page: page)
            }
            Spacer(minLength: 0)

            SourceKey()
                .padding(.trailing, 16)
                .padding(.bottom, 8)
            PageItem(page: .about)
                .padding(.bottom, 16)
        }
        .padding(.top, 48)
        .padding(.leading, 8)
        .task { app.refreshBackendState() }
    }
}

/// Who answers, at the sidebar's foot: a lamp for the connection and the service, the persona
/// under it; a click opens the source menu above.
private struct SourceKey: View {
    @Environment(MainModel.self) private var model
    @Environment(AppModel.self) private var app
    @State private var hot = false

    var body: some View {
        let colors = app.colors
        Button { model.sourceOpen.toggle() } label: {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 8) {
                    Rectangle()
                        .fill(app.connection == .connected ? colors.accent : colors.rose.opacity(app.connection == nil ? 0 : 1))
                        .frame(width: 6, height: 6)
                    Text(app.sourceName).pixelText().lineLimit(1)
                    DotIconView(icon: .chevron).foregroundStyle(colors.ink3)
                }
                Text(app.currentPersona).pixelText().foregroundStyle(colors.ink2).lineLimit(1).truncationMode(.tail)
                    .padding(.leading, 14)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(hot || model.sourceOpen ? colors.ink : colors.ink2)
        .onHover { hot = $0 }
        .onGeometryChange(for: CGRect.self) { $0.frame(in: .named(BoardSpace.name)) } action: { model.sourceAnchor = $0 }
        .boardLight("source", .segment, in: .main, pressed: model.sourceOpen)
    }
}

private struct PageItem: View {
    @Environment(MainModel.self) private var model
    @Environment(AppModel.self) private var app
    let page: MainPage
    @State private var hot = false

    var body: some View {
        let colors = app.colors
        let selected = model.page == page
        Button {
            withAnimation(.easeOut(duration: 0.28)) { model.go(to: page) }
        } label: {
            Text(app.strings.page(page))
                .pixelText()
                .padding(.horizontal, 16)
                .frame(maxWidth: .infinity, minHeight: 36, alignment: .leading)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(selected || hot ? colors.ink : colors.ink2)
        .onHover { hot = $0 }
        .modifier(SelectedPlate(id: "page-\(page.rawValue)", on: selected))
        .boardLight("page-\(page.rawValue)", .segment, in: .main, pressed: selected)
        .padding(.trailing, 16)
    }
}

/// Puts a view on a plate of lit cells while `on`. The view stays the same view either way, so
/// a row keeps its hover when its plate turns on (the delete key's confirming step relies on it).
struct SelectedPlate: ViewModifier {
    let id: String
    let on: Bool
    var clip: String?
    /// Warning cells (a row about to be deleted), brighter so they show over a selected row's.
    var rose = false

    func body(content: Content) -> some View {
        content.boardPlate(id, rose: rose, value: rose ? 0.3 : 0.27, page: "main", clip: clip, on: on)
    }
}
