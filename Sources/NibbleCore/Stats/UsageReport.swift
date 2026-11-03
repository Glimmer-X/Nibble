import Foundation

/// What the home page shows: how much Nibble was used lately, how fast the answers came, and who
/// answered. Worked out from the saved conversations (so it covers what retention keeps).
public struct UsageReport: Sendable, Equatable {
    public struct Day: Sendable, Equatable {
        /// The start of the day.
        public var date: Date
        public var questions: Int
        /// Tokens written by the answers (reported by the backend, or estimated from the text).
        public var tokens: Int
    }

    public struct Persona: Sendable, Equatable {
        public var name: String
        public var questions: Int
    }

    /// The last `dayCount` days, oldest first; the last one is today.
    public var days: [Day]
    public var conversations: Int
    public var questions: Int
    /// Mean speed of the answers, in tokens per second.
    public var averageSpeed: Double?
    /// Mean seconds from sending a question until its answer began.
    public var averageWait: Double?
    /// Who answered, most questions first.
    public var personas: [Persona]

    public var today: Day { days.last ?? Day(date: Date(), questions: 0, tokens: 0) }
    /// The last seven days together.
    public var week: Day {
        let recent = days.suffix(7)
        return Day(date: recent.first?.date ?? Date(), questions: recent.reduce(0) { $0 + $1.questions }, tokens: recent.reduce(0) { $0 + $1.tokens })
    }

    public init(_ conversations: [Conversation], now: Date = Date(), calendar: Calendar = .current, dayCount: Int = 14) {
        let today = calendar.startOfDay(for: now)
        let starts = (0..<dayCount).reversed().compactMap { calendar.date(byAdding: .day, value: -$0, to: today) }
        var days = starts.map { Day(date: $0, questions: 0, tokens: 0) }
        func index(_ date: Date) -> Int? {
            let start = calendar.startOfDay(for: date)
            return starts.firstIndex(of: start)
        }

        var questions = 0
        var byPersona: [String: Int] = [:]
        var speeds: [Double] = []
        var waits: [Double] = []
        for conversation in conversations {
            for message in conversation.messages {
                switch message.role {
                case .user:
                    questions += 1
                    if let persona = conversation.persona, !persona.isEmpty { byPersona[persona, default: 0] += 1 }
                    if let i = index(message.createdAt) { days[i].questions += 1 }
                case .assistant:
                    guard message.status == .complete || message.status == .cancelled else { continue }
                    if let i = index(message.createdAt) { days[i].tokens += Tokens.written(by: message) }
                    guard message.status == .complete, let stats = message.stats else { continue }
                    if let speed = stats.tokensPerSecond, speed > 0 { speeds.append(speed) }
                    if let wait = ReplyMeasure.wait(stats) { waits.append(wait) }
                }
            }
        }
        self.days = days
        self.conversations = conversations.count
        self.questions = questions
        averageSpeed = speeds.isEmpty ? nil : speeds.reduce(0, +) / Double(speeds.count)
        averageWait = waits.isEmpty ? nil : waits.reduce(0, +) / Double(waits.count)
        personas = byPersona.map { Persona(name: $0.key, questions: $0.value) }
            .sorted { $0.questions != $1.questions ? $0.questions > $1.questions : $0.name < $1.name }
    }
}

/// One conversation in numbers, for the panel's conversation page.
public struct ConversationReport: Sendable, Equatable {
    public var questions: Int
    /// Answers that finished.
    public var answers: Int
    /// Replies that failed.
    public var failures: Int
    /// Tokens written by the answers.
    public var tokens: Int
    /// The prompt of the latest answer, in tokens: how much of the context window the
    /// conversation now takes, when the backend reports it.
    public var context: Int?
    public var averageSpeed: Double?
    public var averageWait: Double?
    /// Each finished answer's speed, oldest first.
    public var speeds: [Double]

    public init(_ conversation: Conversation) {
        let replies = conversation.messages.filter { $0.role == .assistant && $0.status != .streaming }
        questions = conversation.questionCount
        answers = replies.count { $0.status == .complete }
        failures = replies.count(where: \.isFailed)
        tokens = replies.filter { !$0.isFailed }.reduce(0) { $0 + Tokens.written(by: $1) }
        context = replies.last { $0.stats?.usage?.inputTokens != nil }?.stats?.usage?.inputTokens
        let finished = replies.filter { $0.status == .complete }
        speeds = finished.compactMap { $0.stats?.tokensPerSecond }.filter { $0 > 0 }
        let waits = finished.compactMap { $0.stats.flatMap(ReplyMeasure.wait) }
        averageSpeed = speeds.isEmpty ? nil : speeds.reduce(0, +) / Double(speeds.count)
        averageWait = waits.isEmpty ? nil : waits.reduce(0, +) / Double(waits.count)
    }
}

enum ReplyMeasure {
    /// Seconds from sending until the answer began: the wait for the backend plus the model's work.
    static func wait(_ stats: ReplyStats) -> Double? {
        guard let wait = stats.waitSeconds else { return nil }
        return wait + (stats.workSeconds ?? 0)
    }
}
