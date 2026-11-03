import Foundation

public struct Conversation: Identifiable, Codable, Sendable, Equatable {
    public let id: UUID
    public let createdAt: Date
    public var updatedAt: Date
    public var messages: [Message]
    /// Continuation handle issued by a backend that keeps history on its side (Hermes sessions).
    /// Backends that need the full history on every request leave it nil.
    public var remoteSessionID: String?
    /// Who answered the latest question: the Hermes profile or the model. Nil for older files.
    public var persona: String?

    public init(
        id: UUID = UUID(),
        createdAt: Date = Date(),
        messages: [Message] = [],
        remoteSessionID: String? = nil,
        persona: String? = nil
    ) {
        self.id = id
        self.createdAt = createdAt
        self.updatedAt = createdAt
        self.messages = messages
        self.remoteSessionID = remoteSessionID
        self.persona = persona
    }

    public var isEmpty: Bool { messages.isEmpty }

    /// A one-line name for lists: the first question's first line. Empty when the first question
    /// was only an image.
    public var title: String {
        guard let first = messages.first(where: { $0.role == .user }) else { return "" }
        let line = first.text.split(whereSeparator: \.isNewline).first.map(String.init) ?? ""
        return line.trimmingCharacters(in: .whitespaces)
    }

    /// How many questions the reader asked.
    public var questionCount: Int { messages.count { $0.role == .user } }
}
