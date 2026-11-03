import Foundation
import NibbleCore

/// Hermes Agent through its API server (Hermes 0.22; see docs/research/hermes-backend.md).
///
/// Nibble uses the server's chat completions route with a session of its own
/// (`X-Hermes-Session-Id`): Hermes keeps the conversation on its side, so each turn sends only the
/// new message. Of the server's routes this is the one that streams everything the panel shows:
/// the model's reasoning, tool calls (`hermes.tool.progress`), waits and retries
/// (`hermes.status`), approvals (`approval.request`) and token usage. A profile (its own
/// personality, model and memory) is reached under `/p/<profile>/`, each with its own key.
/// Stopping closes the stream, which interrupts the run.
public struct HermesBackend: ChatBackend {
    public let address: String
    public let profile: String
    public let apiKey: String?

    public init(address: String, profile: String, apiKey: String?) {
        self.address = address
        self.profile = profile
        self.apiKey = apiKey
    }

    /// Hermes keeps each conversation in its own session; its API server has no way to take a
    /// turn back.
    public var keepsConversation: Bool { true }

    public func respond(to request: ChatRequest) -> AsyncThrowingStream<ChatEvent, any Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    try await stream(request, into: continuation)
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    public func answer(_ approval: Approval, with answer: ApprovalAnswer) async throws {
        guard let handle = ApprovalHandle(approval.id), let url = endpoint("/v1/runs/\(handle.run)/approval") else {
            throw BackendError.unsupported
        }
        _ = try await HTTP.json(try HTTP.request(url, method: "POST", key: apiKey, json: handle.body(answer)))
    }

    /// Which request an approval answers: the run, the request, and the run's execution generation
    /// when Hermes gave one. Kept in `Approval.id` as `run|request` or `run|request|generation`.
    struct ApprovalHandle: Equatable {
        let run: String
        let request: String
        /// Hermes's session authority fences answers to the run's execution generation: the answer
        /// must carry the one the request came with, and exactly these fields, or Hermes refuses it
        /// (HTTP 400). Without the authority the request has none and the answer leaves it out.
        let generation: Int?

        init(run: String, request: String, generation: Int?) {
            self.run = run
            self.request = request
            self.generation = generation
        }

        init?(_ id: String) {
            let parts = id.split(separator: "|", omittingEmptySubsequences: false).map(String.init)
            guard parts.count == 2 || parts.count == 3, !parts[0].isEmpty, !parts[1].isEmpty else { return nil }
            run = parts[0]
            request = parts[1]
            generation = parts.count == 3 ? Int(parts[2]) : nil
        }

        var id: String { [run, request, generation.map(String.init)].compactMap { $0 }.joined(separator: "|") }

        /// The body of `POST /v1/runs/{run}/approval`. Allowing for the conversation is Hermes's
        /// `session` choice: it allows this kind of command for the rest of the session.
        func body(_ answer: ApprovalAnswer) -> [String: Any] {
            let choice = switch answer {
            case .allow: "once"
            case .allowForConversation: "session"
            case .deny: "deny"
            }
            var body: [String: Any] = ["choice": choice, "request_id": request]
            if let generation { body["execution_generation"] = generation }
            return body
        }
    }

    // MARK: - A turn

    private func stream(_ chat: ChatRequest, into continuation: AsyncThrowingStream<ChatEvent, any Error>.Continuation) async throws {
        guard let url = endpoint("/v1/chat/completions"), hasKey else { throw BackendError.notConfigured }
        let session = sessionID(for: chat)
        continuation.yield(.remoteSession(Self.handle(profile: profile, session: session)))
        let body: [String: Any] = [
            "messages": [["role": "user", "content": Self.content(chat.input)]],
            "stream": true,
        ]
        var request = try HTTP.request(url, method: "POST", key: apiKey, json: body, accept: "text/event-stream")
        request.setValue(session, forHTTPHeaderField: "X-Hermes-Session-Id")
        let bytes = try await HTTP.stream(request)

        var reader = TurnReader()
        var parser = ServerSentEventParser()
        do {
            for try await byte in bytes {
                guard let event = parser.feed(byte) else { continue }
                let (events, done) = try reader.read(event)
                for e in events { continuation.yield(e) }
                if done { return }
            }
            if let event = parser.finish() {
                for e in try reader.read(event).events { continuation.yield(e) }
            }
        } catch let error as URLError {
            throw HTTP.map(error)
        }
    }

    /// The Hermes session for this conversation: the one it already has with this profile, or a
    /// new one. Switching persona starts a new session with the new profile.
    private func sessionID(for chat: ChatRequest) -> String {
        if let handle = chat.remoteSessionID.flatMap(Self.parse(handle:)), handle.profile == profile {
            return handle.session
        }
        return "nibble-" + UUID().uuidString.lowercased().replacingOccurrences(of: "-", with: "").prefix(20)
    }

    /// What Nibble keeps of a Hermes session (`Conversation.remoteSessionID`): the profile and the
    /// session's id, as `profile/session`.
    static func handle(profile: String, session: String) -> String {
        "\(profile)/\(session)"
    }

    /// The profile and session of a handle from `handle(profile:session:)`.
    public static func parse(handle: String) -> (profile: String, session: String)? {
        guard let slash = handle.firstIndex(of: "/") else { return nil }
        let profile = String(handle[..<slash])
        let session = String(handle[handle.index(after: slash)...])
        return profile.isEmpty || session.isEmpty ? nil : (profile, session)
    }

    /// The new message: plain text, or text and images as parts.
    static func content(_ turn: ChatRequest.Turn) -> Any {
        guard !turn.images.isEmpty else { return turn.text }
        var parts: [[String: Any]] = []
        if !turn.text.isEmpty { parts.append(["type": "text", "text": turn.text]) }
        for image in turn.images {
            parts.append(["type": "image_url", "image_url": ["url": HTTP.dataURL(image), "detail": "high"]])
        }
        return parts
    }

    /// The API server takes no request without a key, even on this Mac: without one Hermes is not
    /// set up for Nibble yet (no Hermes here, or no `API_SERVER_KEY` in the profile's `.env`).
    private var hasKey: Bool { !(apiKey ?? "").isEmpty }

    /// The default profile lives at the root; the others under `/p/<profile>`.
    private func endpoint(_ path: String) -> URL? {
        let prefix = profile.isEmpty || profile == "default" ? "" : "/p/\(profile)"
        return HTTP.url(address, prefix + path)
    }

    // MARK: - Deleting a conversation

    /// Deletes the session `id` from Hermes, with what Hermes keeps for it: its messages, the
    /// transcript and request dumps in the profile's `sessions` folder, and the images sent with
    /// it. When Hermes compressed the conversation, it carries on in a new session; those go too.
    /// A session Hermes no longer has counts as deleted.
    ///
    /// Files the agent wrote while answering are not tied to a session. Hermes keeps them in the
    /// profile's `cache/scratch` folder and removes them a day after the last write.
    public func forget(session id: String) async throws {
        let sessions = try await Self.lineage(of: id, live: liveSession, parent: parentSession)
        for session in sessions { try await delete(session) }
    }

    /// The sessions of the conversation that started as `id`, newest first: the one holding its
    /// latest messages (`live`), then each one it continued from (`parent`), back to `id`. Empty
    /// when Hermes has no session `id`. A chain that does not lead back to `id` gives only the
    /// live session and `id`, so nothing outside the conversation is touched.
    static func lineage(
        of id: String,
        live: (String) async throws -> String?,
        parent: (String) async throws -> String?
    ) async throws -> [String] {
        guard let tip = try await live(id) else { return [] }
        var chain = [tip]
        var current = tip
        while current != id {
            guard chain.count < 32, let previous = try await parent(current), !chain.contains(previous) else {
                return [tip, id]
            }
            chain.append(previous)
            current = previous
        }
        return chain
    }

    /// The session holding the latest messages of the conversation that started as `id` (`id`
    /// itself unless Hermes compressed it), or nil when Hermes has no session `id`.
    private func liveSession(_ id: String) async throws -> String? {
        guard let url = endpoint("/api/sessions/\(Self.pathSafe(id))/messages?limit=0") else { throw BackendError.notConfigured }
        do {
            let body = try await HTTP.json(try HTTP.request(url, key: apiKey)) as? [String: Any]
            return body?["session_id"] as? String ?? id
        } catch BackendError.server(status: 404, _) {
            return nil
        }
    }

    /// The session `id` continued from, if any.
    private func parentSession(_ id: String) async throws -> String? {
        guard let url = endpoint("/api/sessions/\(Self.pathSafe(id))") else { throw BackendError.notConfigured }
        do {
            let body = try await HTTP.json(try HTTP.request(url, key: apiKey)) as? [String: Any]
            return (body?["session"] as? [String: Any])?["parent_session_id"] as? String
        } catch BackendError.server(status: 404, _) {
            return nil
        }
    }

    /// Deletes one session. A run that was just stopped holds its session for a moment, and Hermes
    /// refuses to delete it meanwhile (409); then it is tried again for up to ten seconds.
    private func delete(_ id: String) async throws {
        guard let url = endpoint("/api/sessions/\(Self.pathSafe(id))") else { throw BackendError.notConfigured }
        let request = try HTTP.request(url, method: "DELETE", key: apiKey)
        var attempts = 0
        while true {
            do {
                _ = try await HTTP.json(request)
                return
            } catch BackendError.server(status: 404, _) {
                return
            } catch BackendError.server(status: 409, _) where attempts < 20 {
                attempts += 1
                try await Task.sleep(for: .milliseconds(500))
            }
        }
    }

    private static func pathSafe(_ id: String) -> String {
        id.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed.subtracting(CharacterSet(charactersIn: "/"))) ?? id
    }

    // MARK: - Checking the connection

    /// Succeeds when the API server answers and accepts the key.
    public func check() async throws {
        guard let url = endpoint("/v1/capabilities"), hasKey else { throw BackendError.notConfigured }
        _ = try await HTTP.json(try HTTP.request(url, key: apiKey))
    }

    // MARK: - Reading a turn

    /// Turns the stream's chunks and Hermes's own events into `ChatEvent`s.
    struct TurnReader {
        /// The completion id, which is also the run's id for approvals.
        private(set) var runID: String?
        private var answer = ""
        /// Text streamed since the last tool call. If a tool call follows, it was the model
        /// talking on its way, not the answer.
        private var segment = ""
        private var started = false

        mutating func read(_ event: ServerSentEvent) throws -> (events: [ChatEvent], done: Bool) {
            if event.data == "[DONE]" { return ([], true) }
            guard let payload = (try? JSONSerialization.jsonObject(with: Data(event.data.utf8))) as? [String: Any] else {
                return ([], false)
            }
            switch event.name {
            case "hermes.tool.progress":
                return (tool(payload), false)
            case "hermes.status":
                let text = payload["text"] as? String ?? ""
                return (Self.isWait(text) ? [.waiting(Self.shorten(text))] : [], false)
            case "approval.request":
                let handle = ApprovalHandle(
                    run: payload["run_id"] as? String ?? runID ?? "",
                    request: payload["request_id"] as? String ?? "",
                    generation: (payload["execution_generation"] as? NSNumber)?.intValue
                )
                let summary = (payload["command"] as? String) ?? (payload["description"] as? String) ?? ""
                let choices = payload["choices"] as? [String] ?? []
                let approval = Approval(id: handle.id, summary: Self.shorten(summary), canAllowForConversation: choices.contains("session"))
                return ([.approval(approval)], false)
            default:
                return (try chunk(payload), false)
            }
        }

        private mutating func chunk(_ payload: [String: Any]) throws -> [ChatEvent] {
            var out: [ChatEvent] = []
            if runID == nil { runID = payload["id"] as? String }
            if !started {
                // The first chunk arrives as soon as the run starts: the agent is at work.
                started = true
                out.append(.activity(.thinking))
            }
            for e in OpenAICompatibleBackend.events(in: payload) {
                switch e {
                case .text(let piece):
                    answer += piece
                    segment += piece
                    out.append(e)
                case .usage(let usage):
                    // Hermes reports the turn's totals with the last chunk.
                    if (usage.outputTokens ?? 0) > 0 || (usage.inputTokens ?? 0) > 0 { out.append(e) }
                default:
                    out.append(e)
                }
            }
            if let choices = payload["choices"] as? [[String: Any]],
               let reason = choices.first?["finish_reason"] as? String, reason != "stop", reason != "tool_calls" {
                let message = (payload["error"] as? [String: Any])?["message"] as? String
                throw BackendError.failed(message ?? "Hermes stopped this run (\(reason)).")
            }
            return out
        }

        private mutating func tool(_ payload: [String: Any]) -> [ChatEvent] {
            let name = payload["tool"] as? String ?? ""
            guard payload["status"] as? String == "running" else { return [.activityEnded] }
            var out: [ChatEvent] = []
            if !segment.isEmpty, answer.hasSuffix(segment) {
                // What streamed before the tool call was the model talking on its way.
                answer.removeLast(segment.count)
                out.append(.replaceAnswer(answer))
                out.append(.reasoning(segment + "\n"))
            }
            segment = ""
            let label = (payload["label"] as? String).map(Self.shorten)
            out.append(.activity(Activity(Self.kind(ofTool: name), detail: label == name ? nil : label)))
            return out
        }

        /// Hermes's status lines that mean it is waiting (a provider wait, a retry's countdown).
        static func isWait(_ text: String) -> Bool {
            let lower = text.lowercased()
            return text.hasPrefix("⏳") || lower.contains("retry") || lower.contains("retrying") || lower.contains("waiting")
                || lower.contains("rate limit")
        }

        static func shorten(_ text: String) -> String {
            let line = text.split(whereSeparator: \.isNewline).first.map(String.init) ?? ""
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            return trimmed.count > 80 ? String(trimmed.prefix(79)) + "…" : trimmed
        }

        /// What kind of work a Hermes tool is, by its name.
        static func kind(ofTool name: String) -> Activity.Kind {
            switch name {
            case "web_search", "x_search", "search_files", "session_search", "skills_list":
                .searching
            case "web_extract", "read_file", "skill_view", "browser_navigate", "browser_snapshot",
                 "browser_console", "feishu_doc_read":
                .reading
            case "vision_analyze", "video_analyze", "browser_vision", "browser_get_images":
                .looking
            default:
                .tool
            }
        }
    }
}
