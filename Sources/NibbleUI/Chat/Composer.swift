import NibbleCore
import SwiftUI

/// The composer: attachments above, then `[input][capture][send]`. The empty bar is this alone.
struct ComposerView: View {
    @Environment(PanelModel.self) private var model
    @State private var lines = 1
    /// An input method is composing in the field: the placeholder makes way at once.
    @State private var composing = false

    var body: some View {
        @Bindable var session = model.session
        let colors = model.colors
        let s = model.strings
        // One line of input with its inset, beside 32 pt keys. The margins above and below make
        // the empty bar `Typeface.barHeight` tall; the keys sit level with the last line.
        let field = Typeface.line + 8
        let margin = (Typeface.barHeight - max(field, 32)) / 2
        let lift = max(0, (field - 32) / 2)
        VStack(alignment: .leading, spacing: 0) {
            if let notice = model.notice {
                Text(notice)
                    .pixelText()
                    .foregroundStyle(colors.ink2)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, 16)
                    .padding(.horizontal, 24)
            }
            if !session.pendingAttachments.isEmpty {
                FlowChips()
                    .padding(.top, 16)
                    .padding(.horizontal, 24)
            }
            HStack(alignment: .bottom, spacing: 8) {
                ZStack(alignment: .topLeading) {
                    if session.draft.isEmpty && !composing {
                        Text(s.placeholder)
                            .font(.system(size: Typeface.inputSize))
                            .foregroundStyle(colors.ink2)
                            .frame(height: Typeface.line)
                            .padding(.top, 4)
                            .allowsHitTesting(false)
                    }
                    ComposerInput(
                        text: $session.draft,
                        font: .systemFont(ofSize: Typeface.inputSize),
                        color: model.palette.t[4].nsColor,
                        caret: model.palette.accent.nsColor,
                        focusRequest: model.focusRequest,
                        sendsWithCommand: model.settings.sendKey == .commandReturn,
                        onLines: { lines = min(6, $0) },
                        onSubmit: { model.send() },
                        onType: { model.controller?.typed(at: $0) },
                        onImages: { items in
                            for item in items { model.attach(data: item.data, name: item.name) }
                        },
                        onComposing: { composing = $0 }
                    )
                }
                .frame(height: CGFloat(lines) * Typeface.line + 8)
                .onChange(of: session.draft) { model.settleFailure() }

                // Dimmer than the header's keys: it sits beside the send key's light.
                IconKey(id: "capture", icon: .capture, label: s.capture, rest: 0.5) { model.capture() }
                    .padding(.bottom, lift)
                SendKey()
                    .padding(.bottom, lift)
            }
            .padding(.vertical, margin)
            .padding(.leading, 24)
            .padding(.trailing, 16)
        }
        .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { model.composerHeight = $0 }
    }
}

/// Attachments waiting to be sent: a thumbnail, the name, a key to remove it.
private struct FlowChips: View {
    @Environment(PanelModel.self) private var model

    var body: some View {
        let colors = model.colors
        HStack(spacing: 16) {
            ForEach(model.session.pendingAttachments) { attachment in
                HStack(spacing: 8) {
                    Thumbnail(image: model.thumbnails[attachment.id], width: 64, height: 40)
                    Text(model.attachmentName(attachment))
                        .pixelText()
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .frame(maxWidth: 200, alignment: .leading)
                        .foregroundStyle(colors.ink2)
                    IconKey(id: "remove-\(attachment.id)", icon: .cross, label: model.strings.remove, size: 24) {
                        model.remove(attachment)
                    }
                }
                .frame(height: 40)
            }
        }
        .onAppear { model.loadThumbnails() }
    }
}

/// The send key: the board's one lamp (violet stepping toward pink) with a 5 × 5 dot display that
/// shows what is happening. Unlit when there is nothing to send.
private struct SendKey: View {
    @Environment(PanelModel.self) private var model

    var body: some View {
        let colors = model.colors
        let lit = model.sendLit
        Button { model.sendOrStop() } label: {
            KeyDisplayView(dots: model.keyDots)
                .frame(width: 32, height: 32)
                .litKey(lit, colors: colors)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(lit ? colors.onAccent : colors.ink3)
        .onHover { model.sendHot = $0 }
        .boardLight("send", .send, in: .chat)
        .accessibilityLabel(model.session.isResponding ? model.strings.stop : model.strings.send)
    }
}

extension View {
    /// The send key's lit face, violet stepping toward pink (also the strip's key while a reply runs).
    func litKey(_ lit: Bool, colors: PanelColors) -> some View {
        background {
            if lit {
                LinearGradient(
                    stops: [.init(color: colors.accent, location: 0.3), .init(color: colors.pink, location: 1)],
                    startPoint: .topLeading, endPoint: .bottomTrailing
                )
            }
        }
    }
}
