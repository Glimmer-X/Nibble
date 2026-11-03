import AppKit
import NibbleCore
import SwiftUI

/// History: every saved conversation, grouped by day and searchable, and the one picked, read in
/// full, with keys to continue it in the quick chat or delete it. A row deletes from the list too.
///
/// The list takes about a third of the page (300–400 pt); the transcript sits beside it at a
/// reading width (at most 640 pt), so a large window leaves room on the right instead of
/// stretching the lines.
struct HistoryPage: View {
    @Environment(MainModel.self) private var model
    @Environment(AppModel.self) private var app
    static let readingWidth: CGFloat = 640

    var body: some View {
        GeometryReader { geometry in
            page(listWidth: min(400, max(300, (geometry.size.width * 0.34).rounded())))
        }
    }

    private func page(listWidth: CGFloat) -> some View {
        @Bindable var model = model
        let s = app.strings
        let colors = app.colors
        let found = filtered
        let open = found.first { $0.id == model.selected } ?? found.first
        return HStack(alignment: .top, spacing: 32) {
            VStack(alignment: .leading, spacing: 12) {
                SearchField(text: $model.search, placeholder: s.searchChats)
                ScrollView(.vertical) {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        if found.isEmpty, app.historyLoaded {
                            Text(app.history.isEmpty ? s.noChatsYet(HotKeyName.describe(app.settings.hotKey)) : s.nothingFound)
                                .pixelText().foregroundStyle(colors.ink2).padding(.horizontal, 12).padding(.top, 8)
                        }
                        ForEach(groups(found), id: \.day) { group in
                            Text(s.day(group.day)).pixelText().foregroundStyle(colors.ink2)
                                .padding(.horizontal, 12).padding(.top, 16).padding(.bottom, 4)
                            ForEach(group.conversations) { conversation in
                                HistoryRow(conversation: conversation, selected: open?.id == conversation.id) {
                                    model.selected = conversation.id
                                } delete: {
                                    model.delete(conversation, in: found)
                                }
                            }
                        }
                    }
                    .padding(.bottom, 24)
                    if !app.history.isEmpty, model.search.trimmingCharacters(in: .whitespaces).isEmpty {
                        ClearAll().padding(.leading, 4).padding(.bottom, 32)
                    }
                }
                .scrollIndicators(.never)
                .mask(
                    LinearGradient(
                        stops: [.init(color: .black, location: 0), .init(color: .black, location: 0.94), .init(color: .clear, location: 1)],
                        startPoint: .top, endPoint: .bottom
                    )
                )
                .boardClip("list")
            }
            .frame(width: listWidth)
            .padding(.leading, -12)

            if let conversation = open {
                TranscriptView(conversation: conversation)
                    .id(conversation.id)
                    .frame(maxWidth: Self.readingWidth, alignment: .topLeading)
                    .modifier(TranscriptArea())
            }
            Spacer(minLength: 0)
        }
    }

    private var filtered: [Conversation] {
        let query = model.search.trimmingCharacters(in: .whitespaces)
        guard !query.isEmpty else { return app.history }
        return app.history.filter { conversation in
            conversation.messages.contains { $0.text.localizedCaseInsensitiveContains(query) }
                || (conversation.persona?.localizedCaseInsensitiveContains(query) ?? false)
        }
    }

    private struct Group {
        let day: Date
        let conversations: [Conversation]
    }

    private func groups(_ conversations: [Conversation]) -> [Group] {
        let calendar = Calendar.current
        var result: [Group] = []
        for conversation in conversations {
            let day = calendar.startOfDay(for: conversation.updatedAt)
            if let last = result.last, last.day == day {
                result[result.count - 1] = Group(day: day, conversations: last.conversations + [conversation])
            } else {
                result.append(Group(day: day, conversations: [conversation]))
            }
        }
        return result
    }
}

/// A row of the list. Under the pointer it shows a delete key at its right end; a click turns the
/// key, the row's cells and its second line into a warning, a second click on the same key
/// deletes. Leaving the row cancels.
private struct HistoryRow: View {
    @Environment(AppModel.self) private var app
    let conversation: Conversation
    let selected: Bool
    let select: () -> Void
    let delete: () -> Void
    @State private var hot = false
    @State private var confirming = false

    var body: some View {
        let s = app.strings
        ConversationRow(
            conversation: conversation, place: .main("list"), selected: selected, trailingRoom: 24,
            warning: confirming ? s.confirmDelete : nil, action: select
        )
        .overlay(alignment: .trailing) {
            if hot || confirming {
                IconKey(
                    id: "row-delete-\(conversation.id)", icon: .close, label: confirming ? s.confirmDelete : s.delete,
                    place: .main("list"), size: 28, tint: confirming ? app.colors.rose : nil
                ) {
                    if confirming { delete() } else { confirming = true }
                }
                .padding(.trailing, 4)
            }
        }
        .modifier(SelectedPlate(id: "row-confirm-\(conversation.id)", on: confirming, clip: "list", rose: true))
        .onHover { inside in
            hot = inside
            if !inside { confirming = false }
        }
    }
}

/// The transcript's area on a box of dim cells, a little past its text: it reads apart from the
/// list, and the background light stays out from behind what is being read. The box stops short
/// of the window's foot, and the transcript scrolls inside it: its text comes and goes a little
/// within the box's edge, never past it.
private struct TranscriptArea: ViewModifier {
    /// From the window's foot to the box's.
    static let foot: CGFloat = 20
    /// From the box's foot to where the transcript's text ends.
    static let inset: CGFloat = 12

    func body(content: Content) -> some View {
        content
            .padding(.bottom, Self.foot + Self.inset)
            .background {
                Color.clear
                    .boardPlate("transcript-box", value: 0.09, page: "main", clip: nil)
                    .padding(EdgeInsets(top: -16, leading: -20, bottom: Self.foot, trailing: -20))
            }
    }
}

/// The key at the end of the list that deletes every saved conversation, in the warning colour on
/// a plate of warning cells; a second click confirms.
private struct ClearAll: View {
    @Environment(MainModel.self) private var model
    @Environment(AppModel.self) private var app
    @State private var confirming = false

    var body: some View {
        let s = app.strings
        TextKey(id: "clear-all", title: confirming ? s.confirmClear : s.clearHistory, place: .main("list"), tint: app.colors.rose) {
            if confirming {
                app.deleteAll()
                model.selected = nil
                confirming = false
            } else {
                confirming = true
            }
        }
        .boardPlate("clear-all", rose: true, value: confirming ? 0.3 : 0.18, page: "main", clip: "list")
        .onChange(of: model.selected) { confirming = false }
    }
}

/// A search field on a plate of dim cells as wide as the list under it; brighter while typed in.
private struct SearchField: View {
    @Environment(AppModel.self) private var app
    @Binding var text: String
    let placeholder: String
    @FocusState private var focused: Bool

    var body: some View {
        HStack(spacing: 10) {
            DotIconView(icon: .search).foregroundStyle(app.colors.ink2)
            TextField(placeholder, text: $text)
                .textFieldStyle(.plain)
                .font(Typeface.message)
                .foregroundStyle(app.colors.ink)
                .focused($focused)
        }
        .padding(.horizontal, 12)
        .frame(height: 32)
        .contentShape(Rectangle())
        .onTapGesture { focused = true }
        .boardPlate("search", value: focused ? 0.2 : 0.1, page: "main", clip: nil)
    }
}

/// A saved conversation read in full: the reader's text on plates, the answers with how long the
/// model thought and how fast it wrote.
private struct TranscriptView: View {
    @Environment(MainModel.self) private var model
    @Environment(AppModel.self) private var app
    let conversation: Conversation
    @State private var confirming = false
    @State private var images: [Attachment.ID: NSImage] = [:]

    var body: some View {
        let s = app.strings
        let colors = app.colors
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 4) {
                Text(conversation.title.isEmpty ? s.image : conversation.title)
                    .font(Typeface.heading)
                    .lineLimit(2)
                Text(meta).pixelText().foregroundStyle(colors.ink2)
            }
            HStack(spacing: 8) {
                TextKey(id: "continue", title: s.continueInPanel, place: .main) { app.continueInPanel(conversation) }
                TextKey(id: "delete", title: confirming ? s.confirmDelete : s.delete, place: .main, tint: confirming ? colors.rose : nil) {
                    if confirming { delete() } else { confirming = true }
                }
            }
            .padding(.leading, -8)
            .padding(.top, 8)
            .padding(.bottom, 8)

            ScrollView(.vertical) {
                VStack(alignment: .leading, spacing: 24) {
                    ForEach(conversation.messages) { message in
                        if message.role == .user { question(message) } else { answer(message) }
                    }
                }
                .padding(.top, 16)
                .padding(.bottom, 32)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .scrollIndicators(.never)
            .mask(
                LinearGradient(
                    stops: [.init(color: .clear, location: 0), .init(color: .black, location: 0.03), .init(color: .black, location: 0.95), .init(color: .clear, location: 1)],
                    startPoint: .top, endPoint: .bottom
                )
            )
            .boardClip("transcript")
        }
        .task(id: conversation.id) { await loadImages() }
        .onChange(of: model.selected) { confirming = false }
    }

    private var meta: String {
        let s = app.strings
        var parts = ["\(s.day(conversation.updatedAt)) \(s.time(conversation.updatedAt))", s.questions(conversation.questionCount)]
        if let persona = conversation.persona, !persona.isEmpty { parts.insert(persona, at: 1) }
        return parts.joined(separator: " · ")
    }

    private func question(_ message: Message) -> some View {
        let colors = app.colors
        return VStack(alignment: .trailing, spacing: 8) {
            ForEach(message.attachments) { attachment in
                Thumbnail(image: images[attachment.id], width: 160, height: 96)
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
                    .boardPlate("history-\(message.id)", page: "main", clip: "transcript")
            }
        }
        .frame(maxWidth: 420, alignment: .trailing)
        .frame(maxWidth: .infinity, alignment: .trailing)
    }

    @ViewBuilder
    private func answer(_ message: Message) -> some View {
        let s = app.strings
        let colors = app.colors
        VStack(alignment: .leading, spacing: 8) {
            if !message.text.isEmpty {
                MarkdownView(document: MarkdownDocument(message.text))
            }
            if case .failed(let reason) = message.status {
                Text(reason)
                    .font(Typeface.message)
                    .rhythm()
                    .foregroundStyle(colors.rose)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .fixedSize(horizontal: false, vertical: true)
                    .boardPlate("history-error-\(message.id)", rose: true, page: "main", clip: "transcript")
                    .padding(.leading, -12)
            }
            let thought = message.stats?.workSeconds.flatMap { $0 >= 1 ? Int($0.rounded()) : nil }
            let speed = message.stats?.tokensPerSecond.flatMap { $0 > 0 ? Int($0.rounded()) : nil }
            let line = message.status == .cancelled ? s.stopped : s.answerMeta(thought: thought, speed: speed)
            if !line.isEmpty {
                Text(line).pixelText().foregroundStyle(colors.ink3)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func delete() {
        model.delete(conversation, in: app.history)
    }

    private func loadImages() async {
        for attachment in conversation.messages.flatMap(\.attachments) where attachment.isImage && images[attachment.id] == nil {
            if let data = await app.data(for: attachment, in: conversation), let image = NSImage(data: data) {
                images[attachment.id] = image
            }
        }
    }
}
