import Foundation

/// Something that answers chat turns: Hermes, an OpenAI-compatible endpoint, a scripted stub.
///
/// A backend receives the conversation so far plus the new user turn and streams events back.
/// Backends that keep their own history (see `ChatRequest.remoteSessionID`) may ignore
/// `history`; stateless ones must send it.
public protocol ChatBackend: Sendable {
    func respond(to request: ChatRequest) -> AsyncThrowingStream<ChatEvent, any Error>
    /// Answers an approval the backend asked for during a reply (`ChatEvent.approval`).
    func answer(_ approval: Approval, with answer: ApprovalAnswer) async throws
    /// The backend keeps the conversation on its side (Hermes) rather than taking it whole with
    /// every request, so a question it has answered cannot be taken back and asked differently.
    var keepsConversation: Bool { get }
}

extension ChatBackend {
    public var keepsConversation: Bool { false }

    public func answer(_ approval: Approval, with answer: ApprovalAnswer) async throws {
        throw BackendError.unsupported
    }
}

public struct ChatRequest: Sendable, Equatable {
    public struct Image: Sendable, Equatable {
        public let mediaType: String
        public let data: Data

        public init(mediaType: String, data: Data) {
            self.mediaType = mediaType
            self.data = data
        }
    }

    public struct Turn: Sendable, Equatable {
        public let role: Message.Role
        public let text: String
        public let images: [Image]

        public init(role: Message.Role, text: String, images: [Image] = []) {
            self.role = role
            self.text = text
            self.images = images
        }
    }

    /// Earlier turns, oldest first. Only completed or cancelled turns are included.
    public let history: [Turn]
    /// The turn being answered.
    public let input: Turn
    /// The handle a previous response issued through `ChatEvent.remoteSession`, if any.
    public let remoteSessionID: String?
    /// The persona's instructions, sent as the system prompt by backends that take one.
    public let instructions: String?

    public init(history: [Turn], input: Turn, remoteSessionID: String? = nil, instructions: String? = nil) {
        self.history = history
        self.input = input
        self.remoteSessionID = remoteSessionID
        self.instructions = instructions
    }
}

public enum ChatEvent: Sendable, Equatable {
    /// A piece of the answer.
    case text(String)
    /// A piece of the model's reasoning.
    case reasoning(String)
    /// The backend started doing something on its way to the answer (searching the web, running a
    /// tool). Transient: shown while it is the latest activity, never stored.
    case activity(Activity)
    /// The current activity finished; the model is working with its result.
    case activityEnded
    /// The backend is waiting before it can go on (a provider busy, a retry's countdown).
    case waiting(String?)
    /// The backend waits for the reader's OK before it goes on.
    case approval(Approval)
    /// The whole answer as the backend finally has it, replacing what streamed (a backend that
    /// streamed commentary on its way, say).
    case replaceAnswer(String)
    /// Token counts for this reply so far.
    case usage(Usage)
    /// The model that answered.
    case model(String)
    /// The backend's handle for continuing this conversation on its side.
    case remoteSession(String)
}

/// What a backend is doing while it works on an answer.
public struct Activity: Sendable, Equatable {
    public enum Kind: String, Sendable, Codable, CaseIterable {
        /// Reasoning, or working with what a tool returned.
        case thinking
        case searching
        /// Reading a page or a file.
        case reading
        /// Looking at an image.
        case looking
        /// Running a command or any other tool.
        case tool
    }

    public let kind: Kind
    /// A short, plain description from the backend ("git status", a search query), if it has one.
    public let detail: String?

    public init(_ kind: Kind, detail: String? = nil) {
        self.kind = kind
        self.detail = detail
    }

    public static let thinking = Activity(.thinking)
}

/// Something the backend wants the reader to allow (a command it wants to run).
public struct Approval: Sendable, Hashable {
    /// The backend's handle for the request.
    public let id: String
    /// What is to be allowed, in the backend's words ("python3 -m pip install requests").
    public let summary: String
    /// The backend can allow requests like this one for the rest of the conversation (Hermes
    /// offers it unless its own check refused the command).
    public let canAllowForConversation: Bool

    public init(id: String, summary: String, canAllowForConversation: Bool = false) {
        self.id = id
        self.summary = summary
        self.canAllowForConversation = canAllowForConversation
    }
}

/// The reader's answer to an approval.
public enum ApprovalAnswer: Sendable, Hashable {
    /// This request, this once.
    case allow
    /// This request, and requests like it for the rest of the conversation.
    case allowForConversation
    case deny

    public var allows: Bool { self != .deny }
}

/// Token counts reported by a backend.
public struct Usage: Sendable, Equatable, Codable {
    public var inputTokens: Int?
    public var outputTokens: Int?
    /// Part of the output spent on reasoning, when the backend says.
    public var reasoningTokens: Int?

    public init(inputTokens: Int? = nil, outputTokens: Int? = nil, reasoningTokens: Int? = nil) {
        self.inputTokens = inputTokens
        self.outputTokens = outputTokens
        self.reasoningTokens = reasoningTokens
    }
}

/// Why a backend could not answer. The panel turns these into plain sentences.
public enum BackendError: Error, Sendable, Equatable {
    /// No backend is set up yet.
    case notConfigured
    /// Nothing answered at the address.
    case cannotConnect(address: String)
    /// The key was refused.
    case unauthorized
    /// Too many requests; try again later.
    case rateLimited
    /// The backend answered with an error.
    case server(status: Int, message: String?)
    /// The backend stopped answering.
    case timedOut
    /// The backend sent something Nibble could not read.
    case invalidResponse(String)
    /// The backend failed the run and said why.
    case failed(String)
    /// The backend cannot do what was asked (answering an approval, say).
    case unsupported
}
