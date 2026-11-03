import NibbleCore
import SwiftUI

/// The conversation. It scrolls freely over the board and follows the answer while it arrives,
/// until the reader scrolls up. Text dissolves into the board at the top and bottom edges.
///
/// Text and images are content: a drag on them selects the text or carries the image away. The
/// empty space around them, down to the bottom of the view, moves the panel.
struct ConversationView: View {
    @Environment(PanelModel.self) private var model
    @State private var position = ScrollPosition(edge: .bottom)
    @State private var followsBottom = true
    /// The visible height, so the empty space under a short conversation moves the panel too.
    @State private var viewport: CGFloat = 0

    /// How much of a question being edited, and its answer, still shows.
    static let replacedOpacity = 0.35

    var body: some View {
        let session = model.session
        let messages = session.conversation.messages
        // While the latest question is being edited, it and its answer are dimmed: sending
        // replaces them.
        let replacedFrom = session.editing.flatMap { id in messages.firstIndex { $0.id == id } } ?? messages.count
        ScrollView(.vertical) {
            VStack(alignment: .leading, spacing: 24) {
                ForEach(Array(messages.enumerated()), id: \.element.id) { index, message in
                    if message.role == .user {
                        UserMessageView(message: message, isLast: message.id == session.lastQuestion?.id, replaced: index >= replacedFrom)
                    } else {
                        ReplyView(message: message, isCurrent: message.id == session.lastReply?.id)
                            .opacity(index >= replacedFrom ? Self.replacedOpacity : 1)
                    }
                }
            }
            .padding(.top, 16)
            .padding(.horizontal, 24)
            .padding(.bottom, 24)
            .frame(maxWidth: .infinity, minHeight: viewport, alignment: .topLeading)
            .background { DragSurface { model.controller?.focusComposer() } }
        }
        .scrollIndicators(.never)
        .scrollPosition($position)
        // A short conversation starts at the top; a long one opens at its end.
        .defaultScrollAnchor(.top, for: .alignment)
        .defaultScrollAnchor(.bottom, for: .initialOffset)
        .onScrollGeometryChange(for: LightRegistry.Scroll.self) { geometry in
            LightRegistry.Scroll(offset: geometry.contentOffset.y, content: geometry.contentSize.height, container: geometry.containerSize.height)
        } action: { _, scroll in
            viewport = scroll.container
            model.registry.scroll.offset = scroll.offset
            model.registry.scroll.content = scroll.content
            model.registry.scroll.container = scroll.container
        }
        .onScrollPhaseChange { _, phase, context in
            // Only the reader's own scrolling counts. The view's own glide to the bottom as the
            // answer grows starts more than a line away when a paragraph arrives at once, and
            // taken for the reader's, it would stop following the answer.
            guard phase.isScrolling, phase != .animating else { return }
            model.registry.scroll.touched = Date()
            let g = context.geometry
            followsBottom = g.contentOffset.y + g.containerSize.height >= g.contentSize.height - 24
        }
        .onChange(of: session.conversation.messages.last?.text) { follow() }
        .onChange(of: session.conversation.messages.count) {
            followsBottom = true
            follow()
        }
        .onChange(of: session.phase) { follow() }
        .mask(
            LinearGradient(
                stops: [.init(color: .clear, location: 0), .init(color: .black, location: 0.04), .init(color: .black, location: 0.96), .init(color: .clear, location: 1)],
                startPoint: .top, endPoint: .bottom
            )
        )
        .boardClip("log")
        .onAppear { model.loadThumbnails() }
    }

    private func follow() {
        guard followsBottom else { return }
        withAnimation(.easeOut(duration: 0.16)) { position.scrollTo(edge: .bottom) }
    }
}

/// The reader's own message, on the right: images on their own, text on a plate of lit cells.
/// The latest question shows an edit key to its left under the pointer (with a backend that takes
/// the whole conversation each time); while it is being edited, a key to cancel.
private struct UserMessageView: View {
    @Environment(PanelModel.self) private var model
    let message: Message
    let isLast: Bool
    /// Being edited: sending replaces it.
    let replaced: Bool
    @State private var hot = false

    var body: some View {
        content
            .opacity(replaced ? ConversationView.replacedOpacity : 1)
            // The key hangs off the question's bottom left corner: it takes no room, so a long
            // question does not wrap anew when it shows.
            .overlay(alignment: .bottomLeading) { key.alignmentGuide(.leading) { $0[.trailing] + 8 } }
            // About three quarters of the panel's width, so a wider panel gives the question room too.
            .frame(maxWidth: max(240, (model.settings.panelWidth - 48) * 0.78), alignment: .trailing)
            .frame(maxWidth: .infinity, alignment: .trailing)
            .onHover { hot = $0 }
    }

    @ViewBuilder
    private var key: some View {
        let s = model.strings
        let session = model.session
        if isLast, session.editing == message.id {
            TextKey(id: "cancel-edit", title: s.cancelEditing) { model.cancelEditing() }
        } else if isLast, hot, session.canEditLastQuestion {
            TextKey(id: "edit-question", title: s.editQuestion) { model.editLastQuestion() }
        }
    }

    private var content: some View {
        let colors = model.colors
        return VStack(alignment: .trailing, spacing: 8) {
            ForEach(message.attachments) { attachment in
                VStack(alignment: .trailing, spacing: 8) {
                    Thumbnail(image: model.thumbnails[attachment.id], width: 160, height: 96)
                        .draggableImage(model.thumbnails[attachment.id])
                    Text(model.attachmentName(attachment)).pixelText().foregroundStyle(colors.ink2)
                }
            }
            if !message.text.isEmpty {
                Text(message.text)
                    .font(Typeface.message)
                    .rhythm()
                    .foregroundStyle(colors.ink)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                    // The whole plate is the text's: a press on its edge selects, never moves the panel.
                    .contentShape(Rectangle())
                    .boardPlate("user-\(message.id)", value: replaced ? 0.1 : 0.27)
            }
        }
    }
}

extension View {
    /// Lets the image be dragged out to other apps (a drag on it never moves the panel).
    @ViewBuilder
    func draggableImage(_ image: NSImage?) -> some View {
        if let image {
            draggable(Image(nsImage: image))
        } else {
            self
        }
    }
}

/// An image cropped to fill its box.
struct Thumbnail: View {
    let image: NSImage?
    let width: CGFloat
    let height: CGFloat

    var body: some View {
        Group {
            if let image {
                Image(nsImage: image).resizable().interpolation(.high).aspectRatio(contentMode: .fill)
            } else {
                Color.clear
            }
        }
        .frame(width: width, height: height)
        .clipped()
    }
}

/// An answer: a status line (what the model is doing, then how long it thought), the answer,
/// and its keys (copy; allow and deny; retry).
private struct ReplyView: View {
    @Environment(PanelModel.self) private var model
    let message: Message
    let isCurrent: Bool

    var body: some View {
        let colors = model.colors
        VStack(alignment: .leading, spacing: 8) {
            StatusLine(message: message, isCurrent: isCurrent)
            if case .failed(let reason) = message.status {
                if !message.text.isEmpty { MarkdownBody(text: message.text) }
                Text(reason)
                    .font(Typeface.message)
                    .rhythm()
                    .foregroundStyle(colors.rose)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .fixedSize(horizontal: false, vertical: true)
                    .contentShape(Rectangle())
                    .boardPlate("error-\(message.id)", rose: true)
                    .padding(.leading, -12)
                    .textSelection(.enabled)
            } else if !message.text.isEmpty {
                MarkdownBody(text: message.text)
            }
            foot
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private var foot: some View {
        let s = model.strings
        let session = model.session
        HStack(spacing: 8) {
            if isCurrent, case .attention(let approval) = session.phase {
                TextKey(id: "allow", title: s.allow) { model.answer(.allow) }
                if approval.canAllowForConversation {
                    TextKey(id: "allow-chat", title: s.allowForConversation) { model.answer(.allowForConversation) }
                        .help(s.allowForConversationHelp)
                }
                TextKey(id: "deny", title: s.deny) { model.answer(.deny) }
            } else if message.isFailed, isCurrent, !session.isResponding {
                if session.failureNeedsSettings {
                    TextKey(id: "settings-\(message.id)", title: s.settings) { model.openMain(.settings) }
                }
                TextKey(id: "retry-\(message.id)", title: s.retry) { model.retry() }
            } else if message.status == .complete, !message.text.isEmpty {
                TextKey(id: "copy-\(message.id)", title: model.copied == message.id ? s.copied : s.copy) { model.copy(message) }
            } else if message.status == .cancelled, !message.text.isEmpty {
                Text(s.stopped).pixelText().foregroundStyle(model.colors.ink2)
            }
        }
        .padding(.leading, -8)
    }
}

/// The answer's Markdown, parsed once per change of text.
private struct MarkdownBody: View {
    let text: String

    var body: some View {
        MarkdownView(document: MarkdownDocument(text))
    }
}

/// What the model is doing while it works (with the seconds counting), how fast it writes, and
/// afterwards how long it thought.
private struct StatusLine: View {
    @Environment(PanelModel.self) private var model
    let message: Message
    let isCurrent: Bool
    var body: some View {
        // Only the reply in progress counts seconds; a finished one is still.
        if isCurrent, model.session.isResponding {
            TimelineView(.periodic(from: .now, by: 0.5)) { timeline in
                content(at: timeline.date)
            }
        } else {
            content(at: Date())
        }
    }

    @ViewBuilder
    private func content(at date: Date) -> some View {
        let text = line(at: date)
        if !text.isEmpty {
            Text(text)
                .pixelText()
                .lineLimit(1)
                .truncationMode(.middle)
                .foregroundStyle(model.colors.ink2)
                .id(label(at: date))
                .transition(.opacity.animation(.easeOut(duration: 0.42)))
        }
    }

    /// The part of the line that changes with the activity (a new activity fades in; the seconds
    /// ticking over do not).
    private func label(at date: Date) -> String {
        guard isCurrent, let phase = model.session.phase else { return "done" }
        switch phase {
        case .waiting: return "waiting"
        case .working(let a): return "working-\(a.kind)-\(a.detail ?? "")"
        case .attention: return "attention"
        case .writing: return "writing"
        }
    }

    private func line(at date: Date) -> String {
        let s = model.strings
        let session = model.session
        if isCurrent, let phase = session.phase {
            return model.phaseLine(phase, at: date)
        }
        switch message.status {
        case .failed, .streaming:
            return ""
        case .cancelled:
            return message.text.isEmpty ? s.stopped : ""
        case .complete:
            guard let work = message.stats?.workSeconds, work >= 1 else { return "" }
            return s.thought(seconds: Int(work.rounded()))
        }
    }
}
