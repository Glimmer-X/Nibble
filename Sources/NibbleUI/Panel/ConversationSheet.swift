import NibbleCore
import SwiftUI

/// The conversation's own page, behind the menu key: this conversation in numbers (questions,
/// tokens, speed, wait, context, failures, and each answer's speed as a dot chart) above the
/// most recent other conversations, which it can switch to. Its foot opens the main window.
struct ConversationSheet: View {
    @Environment(PanelModel.self) private var model

    var body: some View {
        let s = model.strings
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                IconKey(id: "sheet-back", icon: .back, label: s.back, place: .sheet) { model.closeSheet() }
                Text(s.thisChat).pixelText()
                Spacer(minLength: 0)
                IconKey(id: "sheet-close", icon: .close, label: s.close, place: .sheet) { model.controller?.dismiss() }
            }
            .padding(.horizontal, 16)
            .frame(height: 48)

            ScrollView(.vertical) {
                VStack(alignment: .leading, spacing: 32) {
                    Numbers(conversation: model.session.conversation)
                    Recent()
                }
                .padding(.horizontal, 24)
                .padding(.top, 8)
                .padding(.bottom, 24)
                .frame(maxWidth: .infinity, alignment: .leading)
                // Empty space inside the scrolling list moves the panel too.
                .background { DragSurface() }
            }
            .scrollIndicators(.never)
            .boardClip("sheet")

            HStack(spacing: 8) {
                TextKey(id: "sheet-all", title: s.allChats, place: .sheet) { model.openMain(.history) }
                TextKey(id: "sheet-settings", title: s.settings, place: .sheet) { model.openMain(.settings) }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 16)
            .frame(height: 48)
        }
    }
}

/// The conversation in numbers.
private struct Numbers: View {
    @Environment(PanelModel.self) private var model
    let conversation: Conversation

    var body: some View {
        let s = model.strings
        let colors = model.colors
        let report = ConversationReport(conversation)
        let replies = conversation.messages.filter { $0.role == .assistant && $0.status != .streaming }
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .top, spacing: 0) {
                figure(s.questionsLabel, DotFace.compact(report.questions))
                figure(s.tokensLabel, DotFace.compact(report.tokens))
                figure(s.speedLabel, DotFace.measure(report.averageSpeed), unit: "/s")
                figure(s.waitLabel, DotFace.measure(report.averageWait), unit: s.secondsUnit)
            }
            let notes = [report.context.map { s.context(DotFace.compact($0)) }, report.failures > 0 ? s.failures(report.failures) : nil].compactMap(\.self)
            if !notes.isEmpty {
                Text(notes.joined(separator: " · ")).pixelText().foregroundStyle(colors.ink2)
            }
            if replies.count > 1 {
                VStack(alignment: .leading, spacing: 8) {
                    Text(s.answerSpeeds).pixelText().foregroundStyle(colors.ink2)
                    DotBars(
                        values: replies.map { $0.stats?.tokensPerSecond ?? 0 },
                        failed: Set(replies.indices.filter { replies[$0].isFailed }),
                        rows: 8, barWidth: 2, gap: 1, pitch: 3, dot: 2,
                        colors: colors
                    )
                }
            }
        }
    }

    private func figure(_ label: String, _ value: String, unit: String? = nil) -> some View {
        let colors = model.colors
        return VStack(alignment: .leading, spacing: 8) {
            Text(label).pixelText().foregroundStyle(colors.ink2)
            HStack(alignment: .bottom, spacing: 4) {
                DotFigure(text: value, pitch: 3, dot: 2)
                if let unit { Text(unit).pixelText().foregroundStyle(colors.ink2).offset(y: 3) }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// The most recent other conversations; picking one opens it in the chat.
private struct Recent: View {
    @Environment(PanelModel.self) private var model

    var body: some View {
        let s = model.strings
        let colors = model.colors
        let current = model.session.conversation.id
        let others = model.app.history.filter { $0.id != current }.prefix(8)
        VStack(alignment: .leading, spacing: 0) {
            Text(s.recentChats).pixelText().foregroundStyle(colors.ink2).padding(.bottom, 8)
            if others.isEmpty, model.app.historyLoaded {
                Text(s.noOtherChats).pixelText().foregroundStyle(colors.ink3).frame(height: 32)
            }
            ForEach(Array(others)) { conversation in
                RecentRow(conversation: conversation)
            }
        }
    }
}

private struct RecentRow: View {
    @Environment(PanelModel.self) private var model
    let conversation: Conversation
    @State private var hot = false

    var body: some View {
        let s = model.strings
        let colors = model.colors
        Button { model.open(conversation) } label: {
            HStack(spacing: 16) {
                Text(conversation.title.isEmpty ? s.image : conversation.title)
                    .font(Typeface.message)
                    .lineLimit(1)
                    .foregroundStyle(hot ? colors.ink : colors.ink.opacity(0.85))
                Spacer(minLength: 0)
                Text(s.day(conversation.updatedAt) == s.today ? s.time(conversation.updatedAt) : s.day(conversation.updatedAt))
                    .pixelText()
                    .foregroundStyle(colors.ink2)
                    .fixedSize()
            }
            .padding(.horizontal, 8)
            .frame(height: 36)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .padding(.horizontal, -8)
        .onHover { hot = $0 }
        .boardLight("recent-\(conversation.id)", .segment, in: .sheetBody)
    }
}
