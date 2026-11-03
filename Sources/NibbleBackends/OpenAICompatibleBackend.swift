import Foundation
import NibbleCore

/// Any endpoint that speaks the OpenAI chat completions API: DeepSeek, Gemini's OpenAI endpoint,
/// Ollama, OpenAI, OpenRouter and the like.
///
/// Stateless: every request carries the whole conversation, after a system message with the
/// persona's instructions. Reasoning arrives as `delta.reasoning_content` (DeepSeek and most
/// others) or `delta.reasoning` (Ollama, OpenRouter); token counts come with the last chunk when
/// the server honours `stream_options.include_usage`.
public struct OpenAICompatibleBackend: ChatBackend {
    /// The API's base address, before `/chat/completions`.
    public let address: String
    public let model: String
    public let apiKey: String?

    public init(address: String, model: String, apiKey: String?) {
        self.address = address
        self.model = model
        self.apiKey = apiKey
    }

    public func respond(to request: ChatRequest) -> AsyncThrowingStream<ChatEvent, any Error> {
        HTTP.reply(to: request) { request, continuation in try await stream(request, into: continuation) }
    }

    private func stream(_ chat: ChatRequest, into continuation: AsyncThrowingStream<ChatEvent, any Error>.Continuation) async throws {
        guard !model.isEmpty, let url = endpoint("/chat/completions") else { throw BackendError.notConfigured }
        let body: [String: Any] = [
            "model": model,
            "messages": Self.messages(chat),
            "stream": true,
            "stream_options": ["include_usage": true],
        ]
        let request = try HTTP.request(url, method: "POST", key: apiKey, json: body, accept: "text/event-stream")
        let bytes = try await HTTP.stream(request)
        continuation.yield(.model(model))

        var parser = ServerSentEventParser()
        func handle(_ event: ServerSentEvent) throws -> Bool {
            if event.data == "[DONE]" { return false }
            guard let object = try? JSONSerialization.jsonObject(with: Data(event.data.utf8)) as? [String: Any] else {
                return true
            }
            if let message = Self.errorMessage(object) { throw BackendError.failed(message) }
            for e in Self.events(in: object) { continuation.yield(e) }
            return true
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

    /// The events in one streamed chunk.
    static func events(in chunk: [String: Any]) -> [ChatEvent] {
        var result: [ChatEvent] = []
        if let choices = chunk["choices"] as? [[String: Any]], let delta = choices.first?["delta"] as? [String: Any] {
            if let thought = (delta["reasoning_content"] as? String) ?? (delta["reasoning"] as? String), !thought.isEmpty {
                result.append(.reasoning(thought))
            }
            if let text = delta["content"] as? String, !text.isEmpty {
                result.append(.text(text))
            }
        }
        if let usage = chunk["usage"] as? [String: Any] {
            let details = usage["completion_tokens_details"] as? [String: Any]
            result.append(.usage(Usage(
                inputTokens: usage["prompt_tokens"] as? Int,
                outputTokens: usage["completion_tokens"] as? Int,
                reasoningTokens: details?["reasoning_tokens"] as? Int
            )))
        }
        return result
    }

    static func errorMessage(_ object: [String: Any]) -> String? {
        if let error = object["error"] as? [String: Any] { return error["message"] as? String ?? "error" }
        if let error = object["error"] as? String { return error }
        return nil
    }

    /// The conversation in the chat completions format, after the instructions as a system
    /// message; images go in user turns as data URLs.
    static func messages(_ chat: ChatRequest) -> [[String: Any]] {
        let system: [[String: Any]] = chat.instructions.map { [["role": "system", "content": $0]] } ?? []
        return system + (chat.history + [chat.input]).map { turn in
            let role = turn.role == .user ? "user" : "assistant"
            guard turn.role == .user, !turn.images.isEmpty else {
                return ["role": role, "content": turn.text]
            }
            var parts: [[String: Any]] = []
            if !turn.text.isEmpty { parts.append(["type": "text", "text": turn.text]) }
            for image in turn.images {
                parts.append(["type": "image_url", "image_url": ["url": HTTP.dataURL(image)]])
            }
            return ["role": role, "content": parts]
        }
    }

    // MARK: - Checking the connection

    /// The models the endpoint offers, sorted.
    public func models() async throws -> [String] {
        guard let url = endpoint("/models") else { throw BackendError.notConfigured }
        let object = try await HTTP.json(try HTTP.request(url, key: apiKey))
        guard let list = (object as? [String: Any])?["data"] as? [[String: Any]] else {
            throw BackendError.invalidResponse("no model list")
        }
        return list.compactMap { $0["id"] as? String }.sorted()
    }

    private func endpoint(_ path: String) -> URL? {
        var base = address.trimmingCharacters(in: .whitespacesAndNewlines)
        for suffix in ["/chat/completions", "/chat/completions/"] where base.hasSuffix(suffix) {
            base.removeLast(suffix.count)
        }
        return HTTP.url(base, path)
    }
}
