import Foundation
import Observation

/// Where a reply in progress stands.
public enum ReplyPhase: Sendable, Equatable {
    /// Sent; nothing has come back yet.
    case waiting
    /// The model is working on its way to the answer: thinking, searching, reading, a tool.
    case working(Activity)
    /// The backend waits for the reader's OK.
    case attention(Approval)
    /// The answer is streaming.
    case writing
}

/// The conversation currently shown in the panel, and everything that changes it: the draft,
/// pending attachments, sending, streaming the reply, stopping, retrying, starting over.
///
/// Views observe it; the app feeds it a backend and a repository.
@MainActor
@Observable
public final class ConversationSession {
    public private(set) var conversation: Conversation
    public var draft: String = ""
    public private(set) var pendingAttachments: [Attachment] = []
    /// The reply in progress, or nil.
    public private(set) var phase: ReplyPhase?
    /// When the current phase began (the status line counts seconds from here).
    public private(set) var phaseSince: Date
    /// When the current kind of activity began (thinking that goes on becomes deep thinking).
    public private(set) var activitySince: Date
    /// The latest reply failed because the backend is not set up or refused the key: the fix is in
    /// settings, not in trying again. Cleared by the next reply.
    public private(set) var failureNeedsSettings = false
    /// A problem outside any single message (for example, an attachment that could not be stored,
    /// or an answer to an approval that did not get through).
    public private(set) var notice: String? {
        didSet { if let notice { onNotice?(notice) } }
    }
    /// Told of each notice as it is set, the same one again included (the panel shows it a while).
    @ObservationIgnored public var onNotice: (@MainActor (String) -> Void)?

    /// Summoning within this window of the last activity continues the conversation.
    public var continueWindow: Duration
    /// The backend for the next reply. A reply in progress finishes with the one it started with.
    @ObservationIgnored public var backend: any ChatBackend
    /// Who answers the next question (the Hermes profile, the persona or the model), kept with the
    /// conversation.
    @ObservationIgnored public var persona: String?
    /// The persona's instructions for the next reply (the system prompt), if any.
    @ObservationIgnored public var instructions: String?
    /// Turns an error into the sentence stored on a failed reply. The panel sets a localised one.
    @ObservationIgnored public var describeError: @MainActor (any Error) -> String = { $0.localizedDescription }

    @ObservationIgnored private let repository: any ConversationRepository
    @ObservationIgnored private let now: () -> Date
    @ObservationIgnored private var lastActivity: Date
    @ObservationIgnored private var responseTask: Task<Void, Never>?
    /// The backend of the reply in progress, which its approvals are answered through.
    @ObservationIgnored private var replyBackend: (any ChatBackend)?
    @ObservationIgnored private var reply = ReplyClock()

    public init(
        backend: any ChatBackend,
        repository: any ConversationRepository,
        continueWindow: Duration,
        restoring conversation: Conversation? = nil,
        now: @escaping () -> Date = Date.init
    ) {
        self.backend = backend
        self.repository = repository
        self.continueWindow = continueWindow
        self.now = now
        let restored = conversation ?? Conversation(createdAt: now())
        self.conversation = restored
        self.lastActivity = restored.updatedAt
        self.phaseSince = now()
        self.activitySince = now()
    }

    public var isResponding: Bool { phase != nil }

    /// True when there is nothing the user could lose: no messages, no draft, no attachments.
    /// An empty panel may close on its own; a non-empty one stays.
    public var isEmpty: Bool {
        conversation.isEmpty && draftIsEmpty
    }

    /// No text typed and nothing attached.
    public var draftIsEmpty: Bool {
        draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && pendingAttachments.isEmpty
    }

    public var canSend: Bool { !isResponding && !draftIsEmpty }

    /// The latest assistant message.
    public var lastReply: Message? {
        conversation.messages.last { $0.role == .assistant }
    }

    // MARK: - Lifecycle

    /// Call when the panel is summoned. Starts a new conversation if the current one has been
    /// idle for longer than `continueWindow`; a reply in progress always continues.
    public func prepareForSummon() {
        guard !isResponding, !conversation.isEmpty else { return }
        if now().timeIntervalSince(lastActivity) > continueWindow.timeInterval {
            startNewConversation()
        }
    }

    /// Leaves the current conversation (it stays in the repository) and starts an empty one.
    public func startNewConversation() {
        if isResponding { abandonReply() }
        clear()
    }

    /// Drops the current conversation without saving it, because it is being deleted, and starts
    /// an empty one. A reply in progress stops.
    public func discardConversation() {
        if isResponding { abandonReply(saving: false) }
        clear()
    }

    private func clear() {
        failureNeedsSettings = false
        conversation = Conversation(createdAt: now())
        draft = ""
        pendingAttachments = []
        notice = nil
        lastActivity = now()
    }

    /// Shows a saved conversation in place of the current one.
    public func open(_ saved: Conversation) {
        if isResponding { abandonReply() }
        conversation = saved
        notice = nil
        lastActivity = now()
    }

    // MARK: - Composing

    /// Stores attachment bytes with the conversation and queues the attachment for the next message.
    public func attach(_ data: Data, mediaType: String, name: String? = nil, source: Attachment.Source = .file) async {
        do {
            var attachment = try await repository.storeAttachment(data, mediaType: mediaType, for: conversation.id)
            attachment.name = name
            attachment.source = source
            attachment.createdAt = now()
            pendingAttachments.append(attachment)
            touch()
        } catch {
            notice = error.localizedDescription
        }
    }

    public func removePendingAttachment(_ id: Attachment.ID) {
        pendingAttachments.removeAll { $0.id == id }
    }

    /// The bytes of an attachment in this conversation (for thumbnails).
    public func data(for attachment: Attachment) async -> Data? {
        try? await repository.attachmentData(attachment, in: conversation.id)
    }

    // MARK: - Sending

    public func send() {
        guard canSend else { return }
        let userMessage = Message(
            role: .user,
            text: draft.trimmingCharacters(in: .whitespacesAndNewlines),
            attachments: pendingAttachments,
            createdAt: now()
        )
        let earlier = conversation.messages
        conversation.messages.append(userMessage)
        if let persona { conversation.persona = persona }
        draft = ""
        pendingAttachments = []
        startReply(earlier: earlier, input: userMessage)
    }

    /// Sends the last question again after its reply failed.
    public func retry() {
        guard !isResponding,
              let last = conversation.messages.last, last.role == .assistant, last.isFailed,
              let inputIndex = conversation.messages.lastIndex(where: { $0.role == .user })
        else { return }
        conversation.messages.removeLast()
        startReply(earlier: Array(conversation.messages[..<inputIndex]), input: conversation.messages[inputIndex])
    }

    /// Stops the reply in progress, keeping what has arrived.
    public func stop() {
        responseTask?.cancel()
    }

    /// Answers the backend's request for the reader's OK, through the backend the reply started
    /// with. If the answer does not get through, the request comes back to be answered again, with
    /// the reason, unless the reply has moved on meanwhile.
    public func answer(_ answer: ApprovalAnswer) {
        guard case .attention(let approval) = phase, let backend = replyBackend else { return }
        guard answer != .allowForConversation || approval.canAllowForConversation else { return }
        let next = ReplyPhase.working(answer.allows ? Activity(.tool, detail: approval.summary) : .thinking)
        setPhase(next)
        let answeredAt = phaseSince
        Task { [weak self] in
            do {
                try await backend.answer(approval, with: answer)
            } catch {
                guard let self else { return }
                self.notice = self.describeError(error)
                if self.phase == next, self.phaseSince == answeredAt { self.setPhase(.attention(approval)) }
            }
        }
    }

    /// Waits until the reply in progress (if any) has finished and been saved.
    public func waitUntilIdle() async {
        await responseTask?.value
    }

    /// The answer's speed over the last moments, in tokens per second (0 when it is not writing).
    public func tokensPerSecond(at date: Date) -> Double {
        guard phase == .writing else { return 0 }
        return reply.speed(at: date)
    }

    // MARK: - The reply

    private func startReply(earlier: [Message], input: Message) {
        let reply = Message(role: .assistant, text: "", createdAt: now(), status: .streaming)
        conversation.messages.append(reply)
        notice = nil
        failureNeedsSettings = false
        self.reply = ReplyClock(sent: now())
        setPhase(.waiting)
        touch()
        let backend = self.backend
        replyBackend = backend
        responseTask = Task { [weak self] in
            await self?.respond(backend: backend, earlier: earlier, input: input, replyID: reply.id)
        }
    }

    private func respond(backend: any ChatBackend, earlier: [Message], input: Message, replyID: Message.ID) async {
        let conversationID = conversation.id
        var status = Message.Status.complete
        var settingsError = false
        do {
            let request = try await makeRequest(earlier: earlier, input: input, conversationID: conversationID)
            for try await event in backend.respond(to: request) {
                guard conversation.id == conversationID else { break }
                apply(event, to: replyID)
            }
            if Task.isCancelled { status = .cancelled }
        } catch is CancellationError {
            status = .cancelled
        } catch {
            status = Task.isCancelled ? .cancelled : .failed(reason: describeError(error))
            if let error = error as? BackendError { settingsError = error == .notConfigured || error == .unauthorized }
        }

        // The user moved on to a new conversation while this reply was streaming;
        // `abandonReply()` already finished and saved the old one.
        guard conversation.id == conversationID else { return }
        failureNeedsSettings = settingsError && status != .cancelled

        let stats = reply.finish(at: now(), text: message(replyID)?.text ?? "")
        updateMessage(replyID) {
            $0.status = status
            $0.stats = stats
        }
        phase = nil
        responseTask = nil
        replyBackend = nil
        touch()
        await persist()
    }

    private func makeRequest(earlier: [Message], input: Message, conversationID: Conversation.ID) async throws -> ChatRequest {
        var history: [ChatRequest.Turn] = []
        for message in earlier where message.status != .streaming && !message.isFailed {
            history.append(try await turn(for: message, conversationID: conversationID))
        }
        return ChatRequest(
            history: history,
            input: try await turn(for: input, conversationID: conversationID),
            remoteSessionID: conversation.remoteSessionID,
            instructions: instructions.flatMap { $0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : $0 }
        )
    }

    private func turn(for message: Message, conversationID: Conversation.ID) async throws -> ChatRequest.Turn {
        var images: [ChatRequest.Image] = []
        for attachment in message.attachments where attachment.isImage {
            let data = try await repository.attachmentData(attachment, in: conversationID)
            images.append(ChatRequest.Image(mediaType: attachment.mediaType, data: data))
        }
        return ChatRequest.Turn(role: message.role, text: message.text, images: images)
    }

    private func apply(_ event: ChatEvent, to replyID: Message.ID) {
        let date = now()
        switch event {
        case .text(let piece):
            reply.wrote(piece, at: date)
            if phase != .writing { setPhase(.writing) }
            updateMessage(replyID) { $0.text += piece }
        case .reasoning(let piece):
            reply.answered(at: date)
            if phase != .working(.thinking) { setPhase(.working(.thinking)) }
            updateMessage(replyID) { $0.reasoning += piece }
        case .activity(let activity):
            reply.answered(at: date)
            if phase != .working(activity) { setPhase(.working(activity)) }
        case .activityEnded:
            if case .working = phase { setPhase(.working(.thinking)) }
        case .waiting:
            if phase != .waiting { setPhase(.waiting) }
        case .approval(let approval):
            reply.answered(at: date)
            setPhase(.attention(approval))
        case .replaceAnswer(let text):
            updateMessage(replyID) { $0.text = text }
        case .usage(let usage):
            reply.usage = usage
        case .model(let name):
            reply.model = name
        case .remoteSession(let id):
            conversation.remoteSessionID = id
        }
    }

    private func setPhase(_ next: ReplyPhase) {
        let date = now()
        if case .working(let a) = phase, case .working(let b) = next, a.kind == b.kind {
            // Same kind of work with a new detail: the clock for deep thinking keeps running.
        } else {
            activitySince = date
        }
        phase = next
        phaseSince = date
    }

    /// Ends the reply in progress as cancelled and saves the conversation as it stands (unless it
    /// is being deleted), so the caller can replace `conversation` right away.
    private func abandonReply(saving: Bool = true) {
        responseTask?.cancel()
        responseTask = nil
        replyBackend = nil
        phase = nil
        guard saving else { return }
        if let index = conversation.messages.lastIndex(where: { $0.status == .streaming }) {
            conversation.messages[index].status = .cancelled
            conversation.messages[index].stats = reply.finish(at: now(), text: conversation.messages[index].text)
        }
        let finished = conversation
        Task { [weak self, repository] in
            do {
                try await repository.save(finished)
            } catch {
                self?.notice = error.localizedDescription
            }
        }
    }

    // MARK: - Helpers

    private func message(_ id: Message.ID) -> Message? {
        conversation.messages.first { $0.id == id }
    }

    private func updateMessage(_ id: Message.ID, _ change: (inout Message) -> Void) {
        guard let index = conversation.messages.firstIndex(where: { $0.id == id }) else { return }
        change(&conversation.messages[index])
    }

    private func touch() {
        lastActivity = now()
        conversation.updatedAt = lastActivity
    }

    private func persist() async {
        do {
            try await repository.save(conversation)
        } catch {
            notice = error.localizedDescription
        }
    }
}

/// The timing of one reply: when it was sent, when anything came back, when the answer began, and
/// how fast the answer is arriving.
struct ReplyClock {
    var sent: Date?
    var firstEvent: Date?
    var firstText: Date?
    var usage: Usage?
    var model: String?
    /// (time, estimated tokens) of recent pieces of the answer.
    private var samples: [(Date, Double)] = []
    private var tokens = 0.0

    init(sent: Date? = nil) {
        self.sent = sent
    }

    mutating func answered(at date: Date) {
        if firstEvent == nil { firstEvent = date }
    }

    mutating func wrote(_ piece: String, at date: Date) {
        answered(at: date)
        if firstText == nil { firstText = date }
        let estimate = Tokens.estimate(piece)
        tokens += estimate
        samples.append((date, estimate))
        samples.removeAll { date.timeIntervalSince($0.0) > Self.window }
    }

    /// Tokens per second over the last `window` seconds.
    func speed(at date: Date) -> Double {
        guard let firstText else { return 0 }
        let span = min(Self.window, max(0.25, date.timeIntervalSince(firstText)))
        let recent = samples.filter { date.timeIntervalSince($0.0) <= Self.window }.reduce(0) { $0 + $1.1 }
        return recent / span
    }

    func finish(at date: Date, text: String) -> ReplyStats {
        var stats = ReplyStats(usage: usage, model: model)
        if let sent, let firstEvent { stats.waitSeconds = firstEvent.timeIntervalSince(sent) }
        if let firstEvent, let firstText, firstText > firstEvent { stats.workSeconds = firstText.timeIntervalSince(firstEvent) }
        if let firstText {
            let seconds = date.timeIntervalSince(firstText)
            stats.writeSeconds = seconds
            if seconds > 0.5 { stats.tokensPerSecond = Tokens.estimate(text) / seconds }
        }
        return stats
    }

    private static let window = 1.5
}

extension Duration {
    var timeInterval: TimeInterval {
        let parts = components
        return TimeInterval(parts.seconds) + TimeInterval(parts.attoseconds) / 1e18
    }
}
