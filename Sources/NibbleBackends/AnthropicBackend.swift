import Foundation
import NibbleCore

/// Anthropic's Claude API (`/v1/messages`, streamed as server-sent events).
///
/// Stateless: every request carries the whole conversation, the persona's instructions as
/// `system`, images inline. The key goes in `x-api-key` with the API version. Token counts arrive
/// at the start (input) and end (output) of the stream.
public struct AnthropicBackend: ChatBackend {
    /// The API's base address, `https://api.anthropic.com` unless a proxy is used.
    public let address: String
    public let model: String
    public let apiKey: String?

    static let version = "2023-06-01"
    /// The longest answer asked for; every current model allows at least this much.
    static let maxTokens = 8192

    public init(address: String, model: String, apiKey: String?) {
        self.address = address
        self.model = model
        self.apiKey = apiKey
    }

    public func respond(to request: ChatRequest) -> AsyncThrowingStream<ChatEvent, any Error> {
        HTTP.reply(to: request) { request, continuation in try await stream(request, into: continuation) }
    }

    private func stream(_ chat: ChatRequest, into continuation: AsyncThrowingStream<ChatEvent, any Error>.Continuation) async throws {
        guard !model.isEmpty, let url = HTTP.url(address, "/v1/messages") else { throw BackendError.notConfigured }
        var body: [String: Any] = [
            "model": model,
            "max_tokens": Self.maxTokens,
            "stream": true,
            "messages": Self.messages(chat),
        ]
        if let instructions = chat.instructions { body["system"] = instructions }
        let request = try HTTP.request(url, method: "POST", key: apiKey, keyHeader: "x-api-key",
                                       headers: ["anthropic-version": Self.version], json: body, accept: "text/event-stream")
        let bytes = try await HTTP.stream(request)
        continuation.yield(.model(model))

        var parser = ServerSentEventParser()
        var usage = Usage()
        func handle(_ event: ServerSentEvent) throws -> Bool {
            guard let object = try? JSONSerialization.jsonObject(with: Data(event.data.utf8)) as? [String: Any] else { return true }
            switch object["type"] as? String {
            case "error":
                let error = object["error"] as? [String: Any]
                throw BackendError.failed(error?["message"] as? String ?? "error")
            case "message_stop":
                return false
            default:
                for e in Self.events(in: object, usage: &usage) { continuation.yield(e) }
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

    /// The events in one streamed event; `usage` gathers the counts that arrive in parts.
    static func events(in event: [String: Any], usage: inout Usage) -> [ChatEvent] {
        switch event["type"] as? String {
        case "message_start":
            let counts = (event["message"] as? [String: Any])?["usage"] as? [String: Any]
            usage.inputTokens = Self.input(counts)
            usage.outputTokens = counts?["output_tokens"] as? Int
            return [.usage(usage)]
        case "content_block_delta":
            let delta = event["delta"] as? [String: Any]
            switch delta?["type"] as? String {
            case "text_delta":
                if let text = delta?["text"] as? String, !text.isEmpty { return [.text(text)] }
            case "thinking_delta":
                if let thought = delta?["thinking"] as? String, !thought.isEmpty { return [.reasoning(thought)] }
            default: break
            }
            return []
        case "message_delta":
            if let counts = event["usage"] as? [String: Any], let output = counts["output_tokens"] as? Int {
                usage.outputTokens = output
                return [.usage(usage)]
            }
            return []
        default:
            return []
        }
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
