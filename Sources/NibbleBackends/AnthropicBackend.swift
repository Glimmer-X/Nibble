import Foundation
import NibbleCore

/// Anthropic's Claude API (`/v1/messages`, streamed as server-sent events).
///
/// Stateless: every request carries the whole conversation, the persona's instructions as
/// `system`, images inline. The key goes in `x-api-key` with the API version. Token counts arrive
/// at the start (input) and end (output) of the stream. A thinking level turns on adaptive
/// thinking, shown as a summary, at that effort; off asks for no thinking at the lowest effort. A
/// model that refuses either answers at its default. With search on, Anthropic's web search tool
/// is offered (the version with filtering first, then the basic one, then none, as the model
/// accepts); a search shows as its own activity, and the pages the answer cites become its sources.
public struct AnthropicBackend: ChatBackend {
    /// The API's base address, `https://api.anthropic.com` unless a proxy is used.
    public let address: String
    public let model: String
    public let apiKey: String?
    public let thinking: ThinkingLevel
    /// Whether the model may search the web.
    public let search: Bool

    static let version = "2023-06-01"
    /// The longest answer asked for; every current model allows at least this much.
    static let maxTokens = 8192
    /// With thinking asked for: room for the thinking and the answer (current models allow more).
    static let maxTokensThinking = 32_000

    /// The most searches one answer may make.
    static let maxSearches = 5
    /// The web search tool's versions, newest first: with dynamic filtering (current models), then
    /// the basic one.
    static let searchTools = ["web_search_20260209", "web_search_20250305"]

    public init(address: String, model: String, apiKey: String?, thinking: ThinkingLevel = .standard, search: Bool = false) {
        self.address = address
        self.model = model
        self.apiKey = apiKey
        self.thinking = thinking
        self.search = search
    }

    public func respond(to request: ChatRequest) -> AsyncThrowingStream<ChatEvent, any Error> {
        HTTP.reply(to: request) { request, continuation in
            try await HTTP.withSearch(search ? Self.searchTools.map(Optional.some) + [nil] : [nil]) { tool in
                try await HTTP.withThinking(thinking) { level in
                    try await stream(request, level: level, searchTool: tool, into: continuation)
                }
            }
        }
    }

    /// The `tools` field offering web search in this version.
    static func tools(searching version: String) -> [[String: Any]] {
        [["type": version, "name": "web_search", "max_uses": maxSearches]]
    }

    /// The `thinking` and `output_config` fields for a level (none for the model's default).
    static func thinkingFields(_ level: ThinkingLevel) -> [String: Any] {
        switch level {
        case .standard:
            [:]
        case .off:
            ["thinking": ["type": "disabled"], "output_config": ["effort": "low"]]
        case .low, .medium, .high:
            ["thinking": ["type": "adaptive", "display": "summarized"], "output_config": ["effort": level.rawValue]]
        }
    }

    private func stream(_ chat: ChatRequest, level: ThinkingLevel, searchTool: String?, into continuation: AsyncThrowingStream<ChatEvent, any Error>.Continuation) async throws {
        guard !model.isEmpty, let url = HTTP.url(address, "/v1/messages") else { throw BackendError.notConfigured }
        var body: [String: Any] = [
            "model": model,
            "max_tokens": level == .standard ? Self.maxTokens : Self.maxTokensThinking,
            "stream": true,
            "messages": Self.messages(chat),
        ]
        body.merge(Self.thinkingFields(level)) { $1 }
        if let instructions = chat.instructions { body["system"] = instructions }
        if let searchTool { body["tools"] = Self.tools(searching: searchTool) }
        let request = try HTTP.request(url, method: "POST", key: apiKey, keyHeader: "x-api-key",
                                       headers: ["anthropic-version": Self.version], json: body, accept: "text/event-stream")
        let bytes = try await HTTP.stream(request)
        continuation.yield(.model(model))

        var parser = ServerSentEventParser()
        var state = StreamState()
        func handle(_ event: ServerSentEvent) throws -> Bool {
            guard let object = try? JSONSerialization.jsonObject(with: Data(event.data.utf8)) as? [String: Any] else { return true }
            switch object["type"] as? String {
            case "error":
                let error = object["error"] as? [String: Any]
                throw BackendError.failed(error?["message"] as? String ?? "error")
            case "message_stop":
                return false
            default:
                for e in Self.events(in: object, state: &state) { continuation.yield(e) }
                return true
            }
        }
        do {
            for try await byte in bytes {
                if let event = parser.feed(byte), try !handle(event) { return }
            }
            if let event = parser.finish() { _ = try handle(event) }
        } catch let error as URLError {
            throw HTTP.map(error)
        }
    }

    /// What one streamed reply has told so far: token counts that arrive in parts, and the input
    /// of each server tool call as it streams, by block index.
    struct StreamState {
        var usage = Usage()
        var toolInputs: [Int: String] = [:]
        /// Whether some answer has been written, and a tool used since: the text after a search
        /// starts a new paragraph (cited passages arrive as blocks of their own, joined as they come).
        var wroteText = false
        var usedTool = false
    }

    /// The events in one streamed event.
    static func events(in event: [String: Any], state: inout StreamState) -> [ChatEvent] {
        let index = event["index"] as? Int ?? 0
        switch event["type"] as? String {
        case "message_start":
            let counts = (event["message"] as? [String: Any])?["usage"] as? [String: Any]
            state.usage.inputTokens = Self.input(counts)
            state.usage.outputTokens = counts?["output_tokens"] as? Int
            return [.usage(state.usage)]
        case "content_block_start":
            let block = event["content_block"] as? [String: Any]
            switch block?["type"] as? String {
            case "text":
                defer { state.usedTool = false }
                return state.wroteText && state.usedTool ? [.text("\n\n")] : []
            case "server_tool_use":
                state.usedTool = true
                guard block?["name"] as? String == "web_search" else { return [.activity(Activity(.tool))] }
                state.toolInputs[index] = ""
                return [.activity(Activity(.searching))]
            case "web_search_tool_result":
                return [.activityEnded]
            default:
                return []
            }
        case "content_block_delta":
            let delta = event["delta"] as? [String: Any]
            switch delta?["type"] as? String {
            case "text_delta":
                if let text = delta?["text"] as? String, !text.isEmpty {
                    state.wroteText = true
                    return [.text(text)]
                }
            case "thinking_delta":
                if let thought = delta?["thinking"] as? String, !thought.isEmpty { return [.reasoning(thought)] }
            case "input_json_delta":
                if state.toolInputs[index] != nil, let piece = delta?["partial_json"] as? String {
                    state.toolInputs[index, default: ""] += piece
                }
            case "citations_delta":
                if let source = Self.source(delta?["citation"] as? [String: Any]) { return [.sources([source])] }
            default: break
            }
            return []
        case "content_block_stop":
            // A search's query is whole once its block ends: show what is being searched for.
            guard let input = state.toolInputs.removeValue(forKey: index),
                  let object = try? JSONSerialization.jsonObject(with: Data(input.utf8)) as? [String: Any],
                  let query = object["query"] as? String, !query.isEmpty else { return [] }
            return [.activity(Activity(.searching, detail: query))]
        case "message_delta":
            if let counts = event["usage"] as? [String: Any], let output = counts["output_tokens"] as? Int {
                state.usage.outputTokens = output
                return [.usage(state.usage)]
            }
            return []
        default:
            return []
        }
    }

    /// The page a citation points to, named by its site.
    static func source(_ citation: [String: Any]?) -> Source? {
        guard let citation, citation["type"] as? String == "web_search_result_location",
              let link = citation["url"] as? String, let url = URL(string: link), let site = Source.site(of: url) else { return nil }
        return Source(name: site, url: url)
    }

    /// Input tokens, counting those read from or written to the prompt cache.
    private static func input(_ counts: [String: Any]?) -> Int? {
        guard let counts, let base = counts["input_tokens"] as? Int else { return nil }
        return base + (counts["cache_read_input_tokens"] as? Int ?? 0) + (counts["cache_creation_input_tokens"] as? Int ?? 0)
    }

    /// The conversation as Messages API turns; turns with nothing in them are left out.
    static func messages(_ chat: ChatRequest) -> [[String: Any]] {
        (chat.history + [chat.input]).compactMap { turn in
            var content: [[String: Any]] = []
            if turn.role == .user {
                for image in turn.images {
                    content.append(["type": "image", "source": ["type": "base64", "media_type": image.mediaType, "data": image.data.base64EncodedString()]])
                }
            }
            if !turn.text.isEmpty { content.append(["type": "text", "text": turn.text]) }
            guard !content.isEmpty else { return nil }
            return ["role": turn.role == .user ? "user" : "assistant", "content": content]
        }
    }

    // MARK: - Checking the connection

    /// The models the key can use, sorted (also proves the key works).
    public func models() async throws -> [String] {
        guard let url = HTTP.url(address, "/v1/models?limit=1000") else { throw BackendError.notConfigured }
        let request = try HTTP.request(url, key: apiKey, keyHeader: "x-api-key", headers: ["anthropic-version": Self.version])
        let object = try await HTTP.json(request)
        guard let list = (object as? [String: Any])?["data"] as? [[String: Any]] else {
            throw BackendError.invalidResponse("no model list")
        }
        return list.compactMap { $0["id"] as? String }.sorted()
    }
}
