import NibbleCore
import SwiftUI
import UniformTypeIdentifiers

/// Everything that floats on the board: the chat page (header, conversation, composer), the
/// conversation page behind the menu key, the source menu, the strip the chat folds into, and the
/// chat's edges. The board itself is drawn behind by `BoardView`; nothing here paints a surface
/// except the send key and the menu.
///
/// Presses on the panel's empty places move it (a click there gives the composer the keyboard, or
/// unfolds the strip); text, images and keys take their own. The edges and corners, which change
/// the size, sit above all of this (`PanelEdges`).
///
/// While the chat folds into the strip and back its pages keep the chat's size, held at the top
/// right corner with the window, so nothing reflows as the window closes in around them.
struct PanelRootView: View {
    @Environment(PanelModel.self) private var model

    var body: some View {
        let colors = model.colors
        GeometryReader { geometry in
            let folding = model.mini || model.mininess > 0
            let chat = folding ? model.chatSize : geometry.size
            ZStack(alignment: .topTrailing) {
                DragSurface {
                    if model.mini { model.expand() } else { model.controller?.focusComposer() }
                }
                ZStack(alignment: .topLeading) {
                    ChatPage(height: chat.height)
                        .modifier(PageMotion(page: .chat))
                    if model.page == .sheet || model.pageChange != nil {
                        ConversationSheet()
                            .modifier(PageMotion(page: .sheet))
                    }
                    if model.menuOpen {
                        Color.clear.contentShape(Rectangle())
                            .onTapGesture { model.closeMenu() }
                        SourceMenu(done: { model.closeMenu() }, manage: { model.openMain(.settings) })
                            .offset(x: 16, y: 48)
                    }
                }
                .frame(width: chat.width, height: chat.height, alignment: .topLeading)
                .opacity(model.chatFade)
                .allowsHitTesting(!folding)
                if folding {
                    PanelStrip()
                        .opacity(model.stripFade)
                        .allowsHitTesting(model.mini)
                }
            }
            .frame(width: geometry.size.width, height: geometry.size.height, alignment: .topTrailing)
        }
        .coordinateSpace(.named(BoardSpace.name))
        .overlay { Rectangle().strokeBorder(colors.rim, lineWidth: 1).allowsHitTesting(false) }
        .foregroundStyle(colors.ink)
        .environment(\.colorScheme, model.appearance == .dark ? .dark : .light)
        .onDrop(of: [.fileURL, .image], delegate: ImageDrop(model: model))
    }
}

/// Pages cross-fade with a slight slide (24 pt) while a band of light sweeps across the board.
private struct PageMotion: ViewModifier {
    @Environment(PanelModel.self) private var model
    let page: PanelModel.Page

    func body(content: Content) -> some View {
        let (alpha, shift) = motion()
        content
            .opacity(alpha)
            .offset(x: shift)
            .allowsHitTesting(model.page == page && model.pageChange == nil)
    }

    private func motion() -> (Double, Double) {
        guard let change = model.pageChange else { return (model.page == page ? 1 : 0, 0) }
        let e = change.progress * change.progress * (3 - 2 * change.progress)
        if page == change.to { return (e, change.direction * 24 * (1 - e)) }
        return (1 - e, -change.direction * 24 * e)
    }
}

/// The chat page. The bar is the composer alone, centred; the header unrolls as the bar grows into
/// the chat, before the conversation appears.
private struct ChatPage: View {
    @Environment(PanelModel.self) private var model
    let height: CGFloat

    var body: some View {
        let chat = model.view == .chat
        VStack(spacing: 0) {
            if chat {
                Header()
                    .frame(height: max(0, min(48, height - model.composerHeight)), alignment: .top)
                    .clipped()
                ConversationView()
                    .frame(maxHeight: .infinity)
            } else {
                Spacer(minLength: 0)
            }
            ComposerView()
            if !chat { Spacer(minLength: 0) }
        }
        .frame(height: height)
    }
}

/// The header: the service over the persona in smaller type on the left (a menu to change them),
/// then new chat, menu (with a rose cell while a newer version waits behind it), collapse and
/// close.
private struct Header: View {
    @Environment(PanelModel.self) private var model

    var body: some View {
        let colors = model.colors
        let s = model.strings
        HStack(spacing: 8) {
            Button { model.toggleMenu() } label: {
                HStack(spacing: 8) {
                    VStack(alignment: .leading, spacing: 0) {
                        Text(model.sourceName).pixelText().lineLimit(1)
                        Text(model.currentPersona).font(Typeface.pixelSmall).foregroundStyle(colors.ink2).lineLimit(1)
                    }
                    DotIconView(icon: .chevron).foregroundStyle(colors.ink2)
                }
                .padding(.horizontal, 8)
                .frame(minHeight: 32)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .foregroundStyle(colors.ink)
            // The persona keeps its whole name; the empty space beside it gives way.
            .layoutPriority(1)
            .boardLight("persona", .segment, in: .chat, pressed: model.menuOpen)
            .accessibilityLabel("\(s.persona): \(model.currentPersona)")
            Spacer(minLength: 8)
            IconKey(id: "new", icon: .add, label: s.newChat) { model.newChat() }
            IconKey(id: "sheet", icon: .menu, label: s.thisChat) { model.toggleSheet() }
                .overlay(alignment: .topTrailing) { UpdateLamp(id: "sheet-update-lamp", page: "chat") }
            IconKey(id: "collapse", icon: .collapse, label: s.collapse) { model.collapse() }
            IconKey(id: "close", icon: .close, label: s.close) { model.controller?.dismiss() }
        }
        .padding(.horizontal, 16)
        .frame(height: 48)
    }
}

/// A surface drawn as the board's own cells at one level, for overlays that must hide what is
/// under them.
struct CellSurface: View {
    @Environment(AppModel.self) private var app
    @Environment(\.board) private var board
    let level: Double
    var ground = true

    var body: some View {
        let _ = app.appearance // redraw when the colours change
        let fill = board?.fill(level) ?? SIMD3(0, 0, 0)
        let groundFill = board?.groundFill ?? SIMD3(0, 0, 0)
        Canvas { context, size in
            if ground { context.fill(Path(CGRect(origin: .zero, size: size)), with: .color(Self.color(groundFill))) }
            let pitch = 10.0
            let square = 9.0
            var path = Path()
            var y = 0.0
            while y < size.height {
                var x = 0.0
                while x < size.width {
                    path.addRect(CGRect(x: x, y: y, width: min(square, size.width - x), height: min(square, size.height - y)))
                    x += pitch
                }
                y += pitch
            }
            context.fill(path, with: .color(Self.color(fill)))
        }
    }

    static func color(_ c: SIMD3<UInt8>) -> Color {
        Color(.sRGB, red: Double(c.x) / 255, green: Double(c.y) / 255, blue: Double(c.z) / 255)
    }
}

/// Images dropped on the panel: the board lights where the file is while it is dragged.
private struct ImageDrop: DropDelegate {
    let model: PanelModel

    func validateDrop(info: DropInfo) -> Bool { info.hasItemsConforming(to: [.fileURL, .image]) }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        model.registry.drop = info.location
        return DropProposal(operation: .copy)
    }

    func dropExited(info: DropInfo) { model.registry.drop = nil }

    func performDrop(info: DropInfo) -> Bool {
        model.registry.drop = nil
        let providers = info.itemProviders(for: [.fileURL])
        for provider in providers {
            _ = provider.loadObject(ofClass: URL.self) { url, _ in
                guard let url else { return }
                Task { @MainActor in model.attach(files: [url]) }
            }
        }
        if providers.isEmpty {
            for provider in info.itemProviders(for: [.image]) {
                provider.loadDataRepresentation(forTypeIdentifier: UTType.image.identifier) { data, _ in
                    guard let data else { return }
                    Task { @MainActor in model.attach(data: data, name: nil) }
                }
            }
        }
        return true
    }
}
