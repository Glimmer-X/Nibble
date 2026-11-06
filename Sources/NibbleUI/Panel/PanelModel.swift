import AppKit
import NibbleCore
import Observation
import SwiftUI

/// The panel's state as the views see it, and what the reader can do in it. The controller owns
/// the window and the board and reads this every frame.
@MainActor
@Observable
final class PanelModel {
    /// The empty bar (the composer alone) or the chat it unfolds into.
    enum ViewMode {
        case bar
        case chat
    }

    /// The chat, or the conversation's own page behind the menu key (its numbers and the recent
    /// conversations).
    enum Page {
        case chat
        case sheet
    }

    /// Pages cross-fade with a slight slide while a band of light sweeps across the board.
    struct PageChange {
        var from: Page
        var to: Page
        /// +1 toward the conversation page, −1 back.
        var direction: Double
        var start: Date
        var progress = 0.0
    }

    let app: AppModel
    var session: ConversationSession { app.session }
    @ObservationIgnored let registry = LightRegistry()
    @ObservationIgnored weak var controller: PanelController?

    var view: ViewMode = .bar
    var page: Page = .chat
    var pageChange: PageChange?

    // What the whole app shares, as the panel's views read it.
    var settings: NibbleCore.Settings {
        get { app.settings }
        set { app.settings = newValue }
    }

    var strings: Strings { app.strings }
    var appearance: Appearance { app.appearance }
    var palette: Palette { app.palette }
    var colors: PanelColors { app.colors }

    var menuOpen = false
    /// The chat folded into its strip at its top right corner (`PanelStrip`): what the reply is
    /// doing, out of the way of what is underneath.
    var mini = false
    /// How far the panel is from the chat (0) toward the strip (1) while it folds or unfolds.
    var mininess = 0.0
    /// The chat's size while it folds, unfolds or waits as the strip: its page keeps this size,
    /// held at the top right corner, so nothing in it reflows.
    var chatSize = CGSize(width: 480, height: 560)
    /// The chat folds back into the bar (new chat) or the whole panel closes.
    var collapsing = false
    var closing = false
    /// The reader acted after this failure, so the board lets go of its error light.
    var settledFailure: Message.ID?
    var copied: Message.ID?
    var sendHot = false
    /// A short note under the conversation (a capture that needs permission, say).
    var notice: String?
    /// The composer's height, measured; the bar is exactly this tall (rounded up to whole cells).
    var composerHeight: CGFloat = 64
    /// The send key's picture, when it began, and its dots now.
    @ObservationIgnored var keyDisplay: KeyDisplay = .send
    @ObservationIgnored var keyDisplaySince = Date()
    var keyDots = KeyDisplay.send.frame(0)
    /// Thumbnails of attachments, loaded once.
    var thumbnails: [Attachment.ID: NSImage] = [:]
    /// Asks the input to take focus (the value changes each time).
    var focusRequest = 0

    @ObservationIgnored private var noticeTask: Task<Void, Never>?

    init(app: AppModel) {
        self.app = app
        if !app.session.conversation.isEmpty { view = .chat }
        app.session.onNotice = { [weak self] in self?.show(notice: $0) }
    }

    // MARK: - What the reader sees

    /// What the send key does: send something, or stop the reply in progress.
    var sendLit: Bool { session.isResponding || !session.draftIsEmpty }

    var personaLabel: String { app.personaLabel }
    var sourceName: String { app.sourceName }
    var currentPersona: String { app.currentPersona }

    /// How visible the chat and the strip are as one folds into the other: the chat goes first and
    /// the strip comes last (the other way round as the chat unfolds), so they never show together.
    var chatFade: Double { 1 - smooth(0, 0.7, mininess) }
    var stripFade: Double { smooth(0.75, 1, mininess) }

    /// The failed reply whose error light is still on, if any.
    var unsettledFailure: Message? {
        guard view == .chat, !collapsing, let reply = session.lastReply, reply.isFailed, settledFailure != reply.id else { return nil }
        return reply
    }

    /// Which state's light the board should show now.
    func lightState(at date: Date) -> LightState {
        if unsettledFailure != nil { return .error }
        guard let phase = session.phase else { return .idle }
        switch phase {
        case .waiting: return .waiting
        case .attention: return .attention
        case .writing: return .writing
        case .working(let activity):
            switch activity.kind {
            case .thinking:
                return date.timeIntervalSince(session.activitySince) > LightLanguage.deepAfter ? .deep : .think
            case .searching: return .search
            case .reading: return .read
            case .looking: return .look
            case .tool: return .tool
            }
        }
    }

    /// What the send key's display shows: the arrow with something to send; while the model works
    /// on an empty composer, what it is doing (stop under the pointer, or once the reader types);
    /// after an answer a tick until the reader types; after a failure an exclamation mark.
    func keyDisplay(at date: Date) -> KeyDisplay {
        if mini { return stripDisplay(at: date) }
        let empty = session.draftIsEmpty
        if session.isResponding {
            if sendHot || !empty { return .stop }
            return working(at: date)
        }
        guard empty, view == .chat, !collapsing, let reply = session.lastReply else { return .send }
        if reply.isFailed { return .error }
        if reply.status == .complete { return .done }
        return .send
    }

    /// The strip's display: what the reply is doing, or how it ended (a tick, an exclamation mark,
    /// the stop square).
    private func stripDisplay(at date: Date) -> KeyDisplay {
        if session.isResponding { return working(at: date) }
        guard let reply = session.lastReply else { return .done }
        if reply.isFailed { return .error }
        return reply.status == .cancelled ? .stop : .done
    }

    /// The display for what the reply in progress is doing.
    private func working(at date: Date) -> KeyDisplay {
        switch lightState(at: date) {
        case .waiting: .waiting
        case .think: .think
        case .deep: .deep
        case .search: .search
        case .read: .read
        case .look: .look
        case .tool: .tool
        case .attention: .attention
        case .writing: .writing
        case .idle, .error: .stop
        }
    }

    /// The status line's words for what the reply in progress is doing, with its seconds.
    func phaseLine(_ phase: ReplyPhase, at date: Date) -> String {
        let s = strings
        let seconds = max(0, Int(date.timeIntervalSince(session.phaseSince)))
        switch phase {
        case .waiting:
            return s.working(s.waiting, seconds: seconds)
        case .working(let activity):
            let since = activity.kind == .thinking ? session.activitySince : session.phaseSince
            return s.working(s.activity(activity), seconds: max(0, Int(date.timeIntervalSince(since))))
        case .attention(let approval):
            return s.attention(approval.summary)
        case .writing:
            return s.writing(tokensPerSecond: Int(controller?.shownSpeed ?? 0))
        }
    }

    /// The strip's line: what the reply is doing with its seconds (a short line while it asks, the
    /// keys beside it), or how it ended.
    func stripLine(at date: Date) -> String {
        let s = strings
        if let phase = session.phase {
            if case .attention = phase { return s.needsOK }
            return phaseLine(phase, at: date)
        }
        guard let reply = session.lastReply else { return sourceName }
        switch reply.status {
        case .failed: return s.failed
        case .cancelled: return s.stopped
        case .streaming: return ""
        case .complete:
            let work = reply.stats?.workSeconds ?? 0
            return s.done(thoughtFor: work >= 1 ? Int(work.rounded()) : nil)
        }
    }

    // MARK: - Actions

    func sendOrStop() {
        settleFailure()
        if session.isResponding {
            session.stop()
        } else {
            send()
        }
    }

    func send() {
        guard session.canSend else { return }
        menuOpen = false
        session.send()
        controller?.messageSent()
        view = .chat
    }

    func retry() {
        settleFailure()
        session.retry()
        controller?.messageSent()
    }

    /// The latest question goes back into the composer, which takes the keyboard.
    func editLastQuestion() {
        session.editLastQuestion()
        controller?.focusComposer()
    }

    func cancelEditing() {
        session.cancelEditing()
    }

    func answer(_ answer: ApprovalAnswer) {
        session.answer(answer)
    }

    func copy(_ message: Message) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(message.text, forType: .string)
        copied = message.id
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(1.2))
            if self?.copied == message.id { self?.copied = nil }
        }
    }

    /// The header's collapse key and ⌘M: the chat folds into its strip.
    func collapse() {
        controller?.collapse()
    }

    /// A click on the strip, its unfold key or the hotkey: the chat unfolds from the strip.
    func expand() {
        controller?.expand()
    }

    /// Starts over: a chat folds back into the bar, then the conversation is put away.
    func newChat() {
        menuOpen = false
        if session.isResponding { session.stop() }
        if view == .bar {
            session.startNewConversation()
            thumbnails = [:]
        } else {
            collapsing = true
        }
        focusRequest += 1
    }

    /// The fold of a new chat reached the bar.
    func finishCollapse() {
        collapsing = false
        view = .bar
        session.startNewConversation()
        thumbnails = [:]
    }

    func toggleMenu() {
        menuOpen.toggle()
    }

    /// The source menu closed: typing goes on in the composer.
    func closeMenu() {
        menuOpen = false
        focusRequest += 1
    }

    /// The menu key: the conversation's page, or back to the chat.
    func toggleSheet() {
        if page == .sheet { closeSheet() } else { openSheet() }
    }

    func openSheet() {
        guard page == .chat, pageChange == nil else { return }
        menuOpen = false
        page = .sheet
        pageChange = PageChange(from: .chat, to: .sheet, direction: 1, start: Date())
        app.reloadHistory()
    }

    func closeSheet() {
        guard page == .sheet, pageChange == nil else { return }
        page = .chat
        pageChange = PageChange(from: .sheet, to: .chat, direction: -1, start: Date())
        focusRequest += 1
    }

    /// Opens a saved conversation from the conversation page, back in the chat.
    func open(_ conversation: Conversation) {
        if session.isResponding { session.stop() }
        session.open(conversation)
        thumbnails = [:]
        settledFailure = conversation.messages.last { $0.role == .assistant }?.id
        view = .chat
        closeSheet()
    }

    /// Opens the main window on a page (the conversation page's keys).
    func openMain(_ page: MainPage) {
        app.openMain(page)
    }

    /// The reader did something: an error's light lets go (the error itself stays in the thread).
    func settleFailure() {
        if let reply = session.lastReply, reply.isFailed { settledFailure = reply.id }
    }

    // MARK: - Attachments

    func capture() {
        let services = app.services
        guard services.canCaptureScreen(ask: true) else {
            show(notice: strings.capturePermission)
            return
        }
        controller?.play(.scan)
        let point = controller?.screenPoint ?? NSEvent.mouseLocation
        Task {
            do {
                let image = try await services.captureScreen(at: point)
                await session.attach(image.data, mediaType: image.mediaType, source: .screenshot)
                loadThumbnails()
                focusRequest += 1
            } catch {
                show(notice: error.localizedDescription)
            }
        }
    }

    /// An image dropped on the panel or pasted into the input (see `ImageIntake`).
    func attach(data: Data, name: String?) {
        guard let image = app.services.prepareImage(data) else { return }
        Task {
            await session.attach(image.data, mediaType: image.mediaType, name: name, source: .file)
            loadThumbnails()
        }
        focusRequest += 1
    }

    func remove(_ attachment: Attachment) {
        session.removePendingAttachment(attachment.id)
    }

    func attachmentName(_ attachment: Attachment) -> String {
        if attachment.source == .screenshot { return strings.screenshot(attachment.createdAt ?? Date()) }
        return attachment.name ?? ""
    }

    /// Loads thumbnails for attachments that have none yet.
    func loadThumbnails() {
        let all = session.pendingAttachments + session.conversation.messages.flatMap(\.attachments)
        for attachment in all where attachment.isImage && thumbnails[attachment.id] == nil {
            Task {
                guard let data = await session.data(for: attachment), let image = NSImage(data: data) else { return }
                thumbnails[attachment.id] = image
            }
        }
    }

    func show(notice text: String) {
        notice = text
        noticeTask?.cancel()
        noticeTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(8))
            if !Task.isCancelled { self?.notice = nil }
        }
    }
}
