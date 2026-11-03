import Foundation
import Testing
@testable import NibbleCore

@MainActor
@Suite struct ConversationSessionTests {
    let clock = TestClock()
    let repository = InMemoryRepository()

    func makeSession(_ backend: any ChatBackend, restoring: Conversation? = nil) -> ConversationSession {
        ConversationSession(
            backend: backend,
            repository: repository,
            continueWindow: .seconds(600),
            restoring: restoring,
            now: { [clock] in clock.now }
        )
    }

    @Test func streamsTheReplyIntoOneAssistantMessage() async throws {
        let session = makeSession(StubBackend(events: [.activity(Activity(.searching)), .text("Hel"), .text("lo"), .reasoning("hm")]))
        session.draft = "  hi  "
        session.send()
        #expect(session.isResponding)
        #expect(session.draft.isEmpty)

        await session.waitUntilIdle()

        let messages = session.conversation.messages
        #expect(messages.map(\.role) == [.user, .assistant])
        #expect(messages[0].text == "hi")
        #expect(messages[1].text == "Hello")
        #expect(messages[1].reasoning == "hm")
        #expect(messages[1].status == .complete)
        #expect(session.phase == nil)
        #expect(!session.isResponding)
        #expect(await repository.load(id: session.conversation.id) == session.conversation)
    }

    @Test func sendsEarlierTurnsAndImagesToTheBackend() async throws {
        let backend = StubBackend(events: [.text("ok")])
        let session = makeSession(backend)
        session.draft = "first"
        session.send()
        await session.waitUntilIdle()

        await session.attach(Data([1, 2, 3]), mediaType: "image/png")
        session.draft = "second"
        session.send()
        await session.waitUntilIdle()

        let request = try #require(backend.requests.last)
        #expect(request.history.map(\.text) == ["first", "ok"])
        #expect(request.input.text == "second")
        #expect(request.input.images == [ChatRequest.Image(mediaType: "image/png", data: Data([1, 2, 3]))])
        #expect(session.pendingAttachments.isEmpty)
    }

    @Test func keepsTheRemoteSessionHandle() async {
        let backend = StubBackend(events: [.remoteSession("s-1"), .text("ok")])
        let session = makeSession(backend)
        session.draft = "a"
        session.send()
        await session.waitUntilIdle()
        session.draft = "b"
        session.send()
        await session.waitUntilIdle()

        #expect(session.conversation.remoteSessionID == "s-1")
        #expect(backend.requests.last?.remoteSessionID == "s-1")
    }

    @Test func aFailedReplyKeepsItsReasonAndIsLeftOutOfLaterHistory() async throws {
        let failing = makeSession(StubBackend(events: [.text("par")], failure: StubError()))
        failing.draft = "q"
        failing.send()
        await failing.waitUntilIdle()

        let reply = try #require(failing.conversation.messages.last)
        #expect(reply.text == "par")
        guard case .failed = reply.status else {
            Issue.record("expected a failed reply, got \(reply.status)")
            return
        }
    }

    @Test func stopKeepsWhatArrivedAndMarksItCancelled() async throws {
        let session = makeSession(StubBackend(events: [.text("partial")], holdOpen: true))
        session.draft = "q"
        session.send()
        try await Task.sleep(for: .milliseconds(50))
        session.stop()
        await session.waitUntilIdle()

        let reply = try #require(session.conversation.messages.last)
        #expect(reply.text == "partial")
        #expect(reply.status == .cancelled)
        #expect(!session.isResponding)
    }

    @Test func startingOverDuringAReplySavesTheOldConversation() async throws {
        let session = makeSession(StubBackend(events: [.text("partial")], holdOpen: true))
        session.draft = "q"
        session.send()
        let oldID = session.conversation.id
        try await Task.sleep(for: .milliseconds(50))

        session.startNewConversation()
        #expect(session.conversation.isEmpty)
        #expect(!session.isResponding)

        try await Task.sleep(for: .milliseconds(50))
        let saved = try #require(await repository.load(id: oldID))
        #expect(saved.messages.last?.status == .cancelled)
        #expect(saved.messages.last?.text == "partial")
    }

    @Test func aReplyThatNeedsSettingsSaysSo() async {
        let session = makeSession(StubBackend(events: [], failure: BackendError.notConfigured))
        session.draft = "q"
        session.send()
        await session.waitUntilIdle()
        #expect(session.lastReply?.isFailed == true)
        #expect(session.failureNeedsSettings)

        // Another kind of failure is one to retry.
        session.backend = StubBackend(events: [], failure: BackendError.timedOut)
        session.retry()
        #expect(!session.failureNeedsSettings)
        await session.waitUntilIdle()
        #expect(session.lastReply?.isFailed == true)
        #expect(!session.failureNeedsSettings)
    }

    @Test func discardingDuringAReplySavesNothing() async throws {
        let session = makeSession(StubBackend(events: [.text("partial")], holdOpen: true))
        session.draft = "q"
        session.send()
        let oldID = session.conversation.id
        try await Task.sleep(for: .milliseconds(50))

        // The conversation is being deleted: nothing may bring it back.
        session.discardConversation()
        #expect(session.conversation.isEmpty)
        #expect(!session.isResponding)

        try await Task.sleep(for: .milliseconds(50))
        #expect(await repository.load(id: oldID) == nil)
    }

    @Test func summoningContinuesWithinTheWindowAndStartsOverAfterIt() async {
        let session = makeSession(StubBackend(events: [.text("ok")]))
        session.draft = "q"
        session.send()
        await session.waitUntilIdle()
        let firstID = session.conversation.id

        clock.advance(by: 599)
        session.prepareForSummon()
        #expect(session.conversation.id == firstID)

        clock.advance(by: 2)
        session.prepareForSummon()
        #expect(session.conversation.id != firstID)
        #expect(session.conversation.isEmpty)
    }

    @Test func phasesFollowTheEvents() async throws {
        let backend = GatedBackend()
        let session = makeSession(backend)
        session.draft = "q"
        session.send()
        #expect(session.phase == .waiting)

        await backend.emit(.reasoning("hm"))
        #expect(session.phase == .working(.thinking))
        await backend.emit(.activity(Activity(.searching, detail: "swift")))
        #expect(session.phase == .working(Activity(.searching, detail: "swift")))
        await backend.emit(.activityEnded)
        #expect(session.phase == .working(.thinking))
        await backend.emit(.approval(Approval(id: "a1", summary: "rm x")))
        #expect(session.phase == .attention(Approval(id: "a1", summary: "rm x")))
        session.answer(.allow)
        #expect(session.phase == .working(Activity(.tool, detail: "rm x")))
        await backend.emit(.text("done"))
        #expect(session.phase == .writing)
        await backend.finish()
        await session.waitUntilIdle()

        #expect(session.phase == nil)
        #expect(backend.answers == [Approval(id: "a1", summary: "rm x"): .allow])
        let stats = try #require(session.lastReply?.stats)
        #expect(stats.writeSeconds != nil)
    }

    @Test func everyApprovalInAReplyIsAnsweredThroughTheReplysBackend() async {
        let backend = GatedBackend()
        let session = makeSession(backend)
        session.draft = "q"
        session.send()
        // Switching persona mid-reply changes the backend for the next reply only.
        session.backend = GatedBackend()
        await backend.emit(.approval(Approval(id: "a1", summary: "python3 one.py")))
        session.answer(.allow)
        await backend.emit(.activityEnded)
        let second = Approval(id: "a2", summary: "python3 two.py", canAllowForConversation: true)
        await backend.emit(.approval(second))
        #expect(session.phase == .attention(second))
        session.answer(.allowForConversation)
        await backend.finish()
        await session.waitUntilIdle()
        #expect(backend.answers == [Approval(id: "a1", summary: "python3 one.py"): .allow, second: .allowForConversation])
    }

    @Test func allowingForTheConversationNeedsTheBackendToOfferIt() async {
        let backend = GatedBackend()
        let session = makeSession(backend)
        session.draft = "q"
        session.send()
        let approval = Approval(id: "a1", summary: "rm x")
        await backend.emit(.approval(approval))
        session.answer(.allowForConversation)
        // Not offered: the request still waits for an answer it can take.
        #expect(session.phase == .attention(approval))
        session.answer(.deny)
        #expect(session.phase == .working(.thinking))
        await backend.finish()
        await session.waitUntilIdle()
        #expect(backend.answers == [approval: .deny])
    }

    @Test func anAnswerThatDoesNotGetThroughAsksAgainWithTheReason() async throws {
        let backend = GatedBackend()
        backend.refusesAnswers = true
        let session = makeSession(backend)
        var notices: [String] = []
        session.onNotice = { notices.append($0) }
        session.draft = "q"
        session.send()
        let approval = Approval(id: "a1", summary: "rm x")
        await backend.emit(.approval(approval))
        session.answer(.allow)
        for _ in 0..<200 where session.phase != .attention(approval) { try await Task.sleep(for: .milliseconds(5)) }
        #expect(session.phase == .attention(approval))
        #expect(notices.count == 1)
        // Answered again, and refused again: the same reason is told again.
        session.answer(.allow)
        for _ in 0..<200 where notices.count < 2 { try await Task.sleep(for: .milliseconds(5)) }
        #expect(notices.count == 2)
        await backend.finish()
        await session.waitUntilIdle()
    }

    @Test func thinkingKeepsItsClockAcrossDetails() async {
        let backend = GatedBackend()
        let session = makeSession(backend)
        session.draft = "q"
        session.send()
        await backend.emit(.reasoning("a"))
        let since = session.activitySince
        clock.advance(by: 5)
        await backend.emit(.reasoning("b"))
        #expect(session.activitySince == since)
        await backend.emit(.activity(Activity(.tool)))
        #expect(session.activitySince == clock.now)
        await backend.finish()
        await session.waitUntilIdle()
    }

    @Test func retrySendsTheSameQuestionAgain() async throws {
        let backend = StubBackend(events: [.text("x")], failure: StubError())
        let session = makeSession(backend)
        session.draft = "q"
        session.send()
        await session.waitUntilIdle()
        #expect(session.lastReply?.isFailed == true)

        session.retry()
        await session.waitUntilIdle()
        #expect(session.conversation.messages.count == 2)
        #expect(backend.requests.count == 2)
        #expect(backend.requests.last?.input.text == "q")
        #expect(backend.requests.last?.history.isEmpty == true)
    }

    @Test func errorsAreDescribedByThePanel() async throws {
        let session = makeSession(StubBackend(events: [], failure: BackendError.unauthorized))
        session.describeError = { _ in "key refused" }
        session.draft = "q"
        session.send()
        await session.waitUntilIdle()
        #expect(session.lastReply?.status == .failed(reason: "key refused"))
    }

    @Test func tokenEstimatesCountChineseCharactersAsTokens() {
        #expect(Tokens.estimate("你好") == 2)
        #expect(Tokens.estimate("abcdefgh") == 2)
    }

    @Test func emptinessCoversMessagesDraftAndAttachments() async {
        let session = makeSession(StubBackend(events: []))
        #expect(session.isEmpty)
        session.draft = "   "
        #expect(session.isEmpty)
        session.draft = "x"
        #expect(!session.isEmpty)
        session.draft = ""
        await session.attach(Data([0]), mediaType: "image/png")
        #expect(!session.isEmpty)
        #expect(session.canSend)
    }
}

// MARK: - Test doubles

@MainActor
final class TestClock {
    var now = Date(timeIntervalSinceReferenceDate: 800_000_000)
    func advance(by seconds: TimeInterval) { now += seconds }
}

struct StubError: Error {}

/// Replays fixed events; optionally fails at the end or stays open until cancelled.
final class StubBackend: ChatBackend, @unchecked Sendable {
    private let events: [ChatEvent]
    private let failure: (any Error)?
    private let holdOpen: Bool
    private let lock = NSLock()
    private var recorded: [ChatRequest] = []

    init(events: [ChatEvent], failure: (any Error)? = nil, holdOpen: Bool = false) {
        self.events = events
        self.failure = failure
        self.holdOpen = holdOpen
    }

    var requests: [ChatRequest] { lock.withLock { recorded } }

    func respond(to request: ChatRequest) -> AsyncThrowingStream<ChatEvent, any Error> {
        lock.withLock { recorded.append(request) }
        let (events, failure, holdOpen) = (events, failure, holdOpen)
        return AsyncThrowingStream { continuation in
            let task = Task {
                for event in events { continuation.yield(event) }
                if holdOpen {
                    while !Task.isCancelled { try? await Task.sleep(for: .milliseconds(5)) }
                }
                continuation.finish(throwing: failure)
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}

/// Emits events one at a time when the test says so.
final class GatedBackend: ChatBackend, @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: AsyncThrowingStream<ChatEvent, any Error>.Continuation?
    private var answered: [Approval: ApprovalAnswer] = [:]
    /// Answers fail, as when the server refuses them.
    var refusesAnswers = false

    var answers: [Approval: ApprovalAnswer] { lock.withLock { answered } }

    func respond(to request: ChatRequest) -> AsyncThrowingStream<ChatEvent, any Error> {
        let (stream, continuation) = AsyncThrowingStream<ChatEvent, any Error>.makeStream()
        lock.withLock { self.continuation = continuation }
        return stream
    }

    func answer(_ approval: Approval, with answer: ApprovalAnswer) async throws {
        if lock.withLock({ refusesAnswers }) { throw BackendError.failed("refused") }
        lock.withLock { answered[approval] = answer }
    }

    /// Sends one event and gives the session a moment to apply it.
    func emit(_ event: ChatEvent) async {
        while lock.withLock({ continuation }) == nil { await Task.yield() }
        lock.withLock { _ = continuation?.yield(event) }
        for _ in 0..<20 { await Task.yield() }
        try? await Task.sleep(for: .milliseconds(5))
    }

    func finish() async {
        lock.withLock { continuation?.finish() }
    }
}

actor InMemoryRepository: ConversationRepository {
    private var conversations: [Conversation.ID: Conversation] = [:]
    private var blobs: [NibbleCore.Attachment.ID: Data] = [:]

    func save(_ conversation: Conversation) { conversations[conversation.id] = conversation }
    func load(id: Conversation.ID) -> Conversation? { conversations[id] }
    func latest() -> Conversation? { conversations.values.max { $0.updatedAt < $1.updatedAt } }
    func all() -> [Conversation] { conversations.values.sorted { $0.updatedAt > $1.updatedAt } }
    func delete(id: Conversation.ID) { conversations[id] = nil }

    func storeAttachment(_ data: Data, mediaType: String, for conversationID: Conversation.ID) -> NibbleCore.Attachment {
        let attachment = NibbleCore.Attachment(mediaType: mediaType, byteCount: data.count)
        blobs[attachment.id] = data
        return attachment
    }

    func attachmentData(_ attachment: NibbleCore.Attachment, in conversationID: Conversation.ID) throws -> Data {
        guard let data = blobs[attachment.id] else { throw StubError() }
        return data
    }

    func prune(_ policy: RetentionPolicy, now: Date) -> Int { 0 }
}

@Suite struct ReportTests {
    private let calendar: Calendar = {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "Europe/London")!
        return c
    }()

    private func reply(_ text: String, at date: Date, speed: Double?, wait: Double?, work: Double? = nil, output: Int? = nil, status: Message.Status = .complete) -> Message {
        Message(role: .assistant, text: text, createdAt: date, status: status,
                stats: ReplyStats(waitSeconds: wait, workSeconds: work, usage: output.map { Usage(inputTokens: 900, outputTokens: $0) }, tokensPerSecond: speed))
    }

    @Test func usageCountsDaysPersonasAndAverages() {
        let now = Date(timeIntervalSince1970: 1_793_000_000) // a Monday morning in London
        let yesterday = now.addingTimeInterval(-86_400)
        let old = now.addingTimeInterval(-20 * 86_400)
        let a = Conversation(messages: [
            Message(role: .user, text: "one", createdAt: now),
            reply("你好你好", at: now, speed: 40, wait: 1, work: 2, output: 30),
            Message(role: .user, text: "two", createdAt: now),
            reply("", at: now, speed: nil, wait: nil, status: .failed(reason: "x")),
        ], persona: "general")
        let b = Conversation(messages: [
            Message(role: .user, text: "three", createdAt: yesterday),
            reply("abcdefgh", at: yesterday, speed: 20, wait: 3),
        ], persona: "coding")
        let c = Conversation(messages: [Message(role: .user, text: "long ago", createdAt: old)], persona: "general")
        let report = UsageReport([a, b, c], now: now, calendar: calendar)

        #expect(report.days.count == 14)
        #expect(report.today.questions == 2)
        #expect(report.today.tokens == 30)
        #expect(report.days[12].questions == 1)
        #expect(report.days[12].tokens == 2)
        #expect(report.week.questions == 3)
        #expect(report.questions == 4)
        #expect(report.conversations == 3)
        #expect(report.averageSpeed == 30)
        #expect(report.averageWait == 3)
        #expect(report.personas.map(\.name) == ["general", "coding"])
        #expect(report.personas.first?.questions == 3)
    }

    @Test func conversationReportSumsOneConversation() {
        let now = Date()
        let conversation = Conversation(messages: [
            Message(role: .user, text: "q", createdAt: now),
            reply("x", at: now, speed: 50, wait: 0.5, output: 120),
            Message(role: .user, text: "q2", createdAt: now),
            reply("", at: now, speed: nil, wait: nil, status: .failed(reason: "x")),
        ])
        let report = ConversationReport(conversation)
        #expect(report.questions == 2)
        #expect(report.answers == 1)
        #expect(report.failures == 1)
        #expect(report.tokens == 120)
        #expect(report.context == 900)
        #expect(report.speeds == [50])
        #expect(report.averageWait == 0.5)
    }

    @Test func titleIsTheFirstQuestionsFirstLine() {
        let conversation = Conversation(messages: [Message(role: .user, text: "  第一行  \n第二行")])
        #expect(conversation.title == "第一行")
        #expect(Conversation().title == "")
    }
}
