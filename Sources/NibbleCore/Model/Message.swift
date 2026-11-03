import Foundation

/// One turn in a conversation.
public struct Message: Identifiable, Codable, Sendable, Equatable {
    public enum Role: String, Codable, Sendable {
        case user
        case assistant
    }

    public enum Status: Codable, Sendable, Equatable {
        /// The backend is still producing this message.
        case streaming
        case complete
        /// The user stopped the reply; the text received so far is kept.
        case cancelled
        /// The reply failed; `reason` is a sentence for the reader.
        case failed(reason: String)
    }

    public let id: UUID
    public let role: Role
    public var text: String
    /// Model reasoning ("thinking") streamed alongside the answer, when the backend exposes it.
    public var reasoning: String
    public var attachments: [Attachment]
    public let createdAt: Date
    public var status: Status
    /// How the reply went: how long the model worked before it answered, how fast it wrote.
    /// Assistant messages only; nil for older files.
    public var stats: ReplyStats?

    public init(
        id: UUID = UUID(),
        role: Role,
        text: String,
        reasoning: String = "",
        attachments: [Attachment] = [],
        createdAt: Date = Date(),
        status: Status = .complete,
        stats: ReplyStats? = nil
    ) {
        self.id = id
        self.role = role
        self.text = text
        self.reasoning = reasoning
        self.attachments = attachments
        self.createdAt = createdAt
        self.status = status
        self.stats = stats
    }

    public var isFailed: Bool {
        if case .failed = status { return true }
        return false
    }
}

/// Measurements of one reply, kept for the conversation's statistics.
public struct ReplyStats: Codable, Sendable, Equatable {
    /// Seconds from sending until the backend first answered anything.
    public var waitSeconds: Double?
    /// Seconds the model worked (thinking, tools) before the answer started.
    public var workSeconds: Double?
    /// Seconds the answer took to stream.
    public var writeSeconds: Double?
    /// Token counts the backend reported, if any.
    public var usage: Usage?
    /// The answer's average speed in tokens per second (estimated from the text).
    public var tokensPerSecond: Double?
    /// The model that answered, when the backend says.
    public var model: String?

    public init(
        waitSeconds: Double? = nil,
        workSeconds: Double? = nil,
        writeSeconds: Double? = nil,
        usage: Usage? = nil,
        tokensPerSecond: Double? = nil,
        model: String? = nil
    ) {
        self.waitSeconds = waitSeconds
        self.workSeconds = workSeconds
        self.writeSeconds = writeSeconds
        self.usage = usage
        self.tokensPerSecond = tokensPerSecond
        self.model = model
    }
}
