import NibbleCore
import SwiftUI

/// Home: how Nibble was used lately. Four figures (asked today, tokens in seven days, the
/// answers' speed and how long they kept the reader waiting), the last fourteen days as a dot
/// chart, who answered, and the latest conversations.
struct HomePage: View {
    @Environment(MainModel.self) private var model
    @Environment(AppModel.self) private var app

    var body: some View {
        let s = app.strings
        let colors = app.colors
        let report = UsageReport(app.history)
        ScrollView(.vertical) {
            VStack(alignment: .leading, spacing: 40) {
                if app.connection == .notSet { SetUpLine() }
                HStack(alignment: .top, spacing: 16) {
                    Figure(label: s.askedToday, value: DotFace.compact(report.today.questions))
                    Figure(label: s.tokensWeek, value: DotFace.compact(report.week.tokens))
                    Figure(label: s.averageSpeed, value: DotFace.measure(report.averageSpeed), unit: s.perSecond)
                    Figure(label: s.averageWait, value: DotFace.measure(report.averageWait), unit: s.secondsUnit)
                }
                DaysChart(report: report)
                if app.historyLoaded, app.history.isEmpty {
                    Text(s.noChatsYet(HotKeyName.describe(app.settings.hotKey))).pixelText().foregroundStyle(colors.ink2)
                } else {
                    HStack(alignment: .top, spacing: 40) {
                        Personas(report: report).frame(maxWidth: .infinity, alignment: .leading)
                        Latest().frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
            }
            .padding(.bottom, 32)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .scrollIndicators(.never)
        .boardClip("body")
    }
}

/// Shown while no service is set up (a first launch without Hermes, say): a line and a key to the
/// settings, on a plate of lit cells.
private struct SetUpLine: View {
    @Environment(MainModel.self) private var model
    @Environment(AppModel.self) private var app

    var body: some View {
        let s = app.strings
        HStack(spacing: 16) {
            Text(s.setUpService).pixelText().foregroundStyle(app.colors.ink)
            TextKey(id: "home-set-up", title: s.goSetUp, place: .main("body")) {
                withAnimation(.easeOut(duration: 0.28)) { model.go(to: .settings) }
            }
        }
        .padding(.leading, 12)
        .padding(.trailing, 4)
        .padding(.vertical, 6)
        .boardPlate("home-set-up-plate", page: "main", clip: "body")
    }
}

/// A figure on the home page: a pixel label over a dot-display number.
private struct Figure: View {
    @Environment(AppModel.self) private var app
    let label: String
    let value: String
    var unit: String?

    var body: some View {
        let colors = app.colors
        VStack(alignment: .leading, spacing: 12) {
            Text(label).pixelText().foregroundStyle(colors.ink2).lineLimit(1)
            HStack(alignment: .bottom, spacing: 6) {
                DotFigure(text: value)
                if let unit { Text(unit).pixelText().foregroundStyle(colors.ink2).offset(y: 3) }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// The last fourteen days as a dot chart, by questions or by tokens; the pointer reads a day.
private struct DaysChart: View {
    @Environment(MainModel.self) private var model
    @Environment(AppModel.self) private var app
    let report: UsageReport
    @State private var hovered: Int?

    var body: some View {
        @Bindable var model = model
        let s = app.strings
        let colors = app.colors
        let days = report.days
        let values = days.map { Double(model.chartTokens ? $0.tokens : $0.questions) }
        let shown = hovered.flatMap { days.indices.contains($0) ? days[$0] : nil } ?? report.today
        let reading = model.chartTokens ? s.tokens(DotFace.compact(shown.tokens)) : s.questions(shown.questions)
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Text(s.lastDays).pixelText().foregroundStyle(colors.ink2)
                Spacer(minLength: 16)
                Choice(id: "chart-questions", title: s.questionsLabel, selected: !model.chartTokens) { model.chartTokens = false }
                Choice(id: "chart-tokens", title: s.tokensLabel, selected: model.chartTokens) { model.chartTokens = true }
            }
            .frame(maxWidth: 439)
            Text(s.dayValue(shown.date, reading)).pixelText().foregroundStyle(colors.ink)
            DotBars(
                values: values,
                marked: [hovered ?? days.count - 1],
                rows: 12, barWidth: 6, gap: 2,
                colors: colors,
                onHover: { hovered = $0 }
            )
            HStack {
                Text(days.first.map { s.shortDate($0.date) } ?? "").pixelText()
                Spacer()
                Text(s.today).pixelText()
            }
            .foregroundStyle(colors.ink2)
            .frame(width: 439)
        }
    }
}

/// Who answered, most questions first, each with a row of dots.
private struct Personas: View {
    @Environment(AppModel.self) private var app
    let report: UsageReport

    var body: some View {
        let s = app.strings
        let colors = app.colors
        let top = Double(report.personas.first?.questions ?? 1)
        VStack(alignment: .leading, spacing: 0) {
            Text(s.personasLabel).pixelText().foregroundStyle(colors.ink2).padding(.bottom, 12)
            ForEach(report.personas.prefix(6), id: \.name) { persona in
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Text(persona.name).pixelText().lineLimit(1)
                        Spacer(minLength: 8)
                        Text("\(persona.questions)").pixelText().foregroundStyle(colors.ink2)
                    }
                    DotMeter(fraction: Double(persona.questions) / top, colors: colors)
                }
                .frame(width: 199)
                .padding(.bottom, 14)
            }
        }
    }
}

/// A row of dots lit in proportion to `fraction`.
private struct DotMeter: View {
    let fraction: Double
    let colors: PanelColors
    var length = 50

    var body: some View {
        let lit = max(1, Int((fraction * Double(length)).rounded()))
        Canvas { context, _ in
            var on = Path()
            var off = Path()
            for i in 0..<length {
                let rect = CGRect(x: CGFloat(i) * 4, y: 0, width: 3, height: 3)
                if i < lit { on.addRect(rect) } else { off.addRect(rect) }
            }
            context.fill(off, with: .color(colors.ink.opacity(0.09)))
            context.fill(on, with: .color(colors.accent.opacity(0.85)))
        }
        .frame(width: CGFloat(length) * 4 - 1, height: 3)
    }
}

/// The latest conversations; picking one opens it in history.
private struct Latest: View {
    @Environment(MainModel.self) private var model
    @Environment(AppModel.self) private var app

    var body: some View {
        let s = app.strings
        let colors = app.colors
        VStack(alignment: .leading, spacing: 0) {
            Text(s.recentChats).pixelText().foregroundStyle(colors.ink2).padding(.bottom, 4)
            ForEach(app.history.prefix(5)) { conversation in
                ConversationRow(conversation: conversation, place: .main("body"), compact: true) {
                    model.selected = conversation.id
                    withAnimation(.easeOut(duration: 0.28)) { model.go(to: .history) }
                }
                .padding(.horizontal, -12)
            }
        }
    }
}

/// A conversation in a list: its first question, and when it was and who answered.
struct ConversationRow: View {
    @Environment(AppModel.self) private var app
    let conversation: Conversation
    let place: LightRegistry.Place
    var selected = false
    /// One line (time on the right) instead of two.
    var compact = false
    /// Room kept free at the right for a key laid over the row (history's delete key).
    var trailingRoom: CGFloat = 0
    /// A warning in place of the second line (about to be deleted).
    var warning: String?
    let action: () -> Void
    @State private var hot = false

    var body: some View {
        let s = app.strings
        let colors = app.colors
        let title = conversation.title.isEmpty ? s.image : conversation.title
        Button(action: action) {
            Group {
                if compact {
                    HStack(spacing: 16) {
                        Text(title).font(Typeface.message).lineLimit(1)
                        Spacer(minLength: 0)
                        Text(when).pixelText().foregroundStyle(colors.ink2).fixedSize()
                    }
                    .frame(height: 36)
                } else {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(title).font(Typeface.message).lineLimit(1)
                        Text(warning ?? meta).pixelText().foregroundStyle(warning == nil ? colors.ink2 : colors.rose).lineLimit(1)
                    }
                    .padding(.vertical, 10)
                }
            }
            .foregroundStyle(selected || hot ? colors.ink : colors.ink.opacity(0.85))
            .padding(.leading, 12)
            .padding(.trailing, 12 + trailingRoom)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hot = $0 }
        .modifier(SelectedPlate(id: "row-\(conversation.id)", on: selected, clip: place.clip))
        .boardLight("row-\(conversation.id)", .segment, in: place, pressed: selected)
    }

    private var when: String {
        let s = app.strings
        let date = conversation.updatedAt
        return s.day(date) == s.today ? s.time(date) : s.day(date)
    }

    private var meta: String {
        let s = app.strings
        var parts = [s.time(conversation.updatedAt), s.questions(conversation.questionCount)]
        if let persona = conversation.persona, !persona.isEmpty { parts.insert(persona, at: 0) }
        return parts.joined(separator: " · ")
    }
}
