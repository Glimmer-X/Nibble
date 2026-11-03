import Foundation
import NibbleCore

/// Google's Gemini API (`generateContent`, streamed as server-sent events).
///
/// Stateless: every request carries the whole conversation as `contents` (the reader is "user",
/// answers are "model"), the persona's instructions as `systemInstruction`, images inline. The key
/// goes in `x-goog-api-key`. Thinking is shown when the model shares it (`includeThoughts`); a model
/// that cannot think gets the request again without asking. Token counts come with every chunk.
public struct GeminiBackend: ChatBackend {
    /// The API's base address, `https://generativelanguage.googleapis.com` unless a proxy is used.
    public let address: String
    public let model: String
    public let apiKey: String?

    public init(address: String, model: String, apiKey: String?) {
        self.address = address
        self.model = model
        self.apiKey = apiKey
    }

    public func respond(to request: ChatRequest) -> AsyncThrowingStream<ChatEvent, any Error> {
        HTTP.reply(to: request) { request, continuation in
            do {
                try await stream(request, thoughts: true, into: continuation)
            } catch let BackendError.server(400, message?) where message.lowercased().contains("think") {
                try await stream(request, thoughts: false, into: continuation)
            }
        }
    }

    private var modelID: String {
        model.hasPrefix("models/") ? String(model.dropFirst("models/".count)) : model
    }

    private func stream(_ chat: ChatRequest, thoughts: Bool, into continuation: AsyncThrowingStream<ChatEvent, any Error>.Continuation) async throws {
        guard !modelID.isEmpty, let url = HTTP.url(address, "/v1beta/models/\(modelID):streamGenerateContent?alt=sse") else {
            throw BackendError.notConfigured
        }
        var body: [String: Any] = ["contents": Self.contents(chat)]
        if let instructions = chat.instructions {
            body["systemInstruction"] = ["parts": [["text": instructions]]]
        }
        if thoughts {
            body["generationConfig"] = ["thinkingConfig": ["includeThoughts": true]]
        }
        let request = try HTTP.request(url, method: "POST", key: apiKey, keyHeader: "x-goog-api-key", json: body, accept: "text/event-stream")
        let bytes = try await HTTP.stream(request)
        continuation.yield(.model(modelID))

        var parser = ServerSentEventParser()
        func handle(_ event: ServerSentEvent) throws {
            guard let object = try? JSONSerialization.jsonObject(with: Data(event.data.utf8)) as? [String: Any] else { return }
            if let message = OpenAICompatibleBackend.errorMessage(object) { throw BackendError.failed(message) }
            for e in try Self.events(in: object) { continuation.yield(e) }
        }
        do {
            for try await byte in bytes {
                if let event = parser.feed(byte) { try handle(event) }
            }
            if let event = parser.finish() { try handle(event) }
        } catch let error as URLError {
            throw HTTP.map(error)
        }
    }

    /// The events in one streamed response.
    static func events(in chunk: [String: Any]) throws -> [ChatEvent] {
        var result: [ChatEvent] = []
        let candidates = chunk["candidates"] as? [[String: Any]] ?? []
        if candidates.isEmpty, let feedback = chunk["promptFeedback"] as? [String: Any], let reason = feedback["blockReason"] as? String {
            throw BackendError.failed("Gemini: \(reason)")
        }
        let content = candidates.first?["content"] as? [String: Any]
        for part in content?["parts"] as? [[String: Any]] ?? [] {
            guard let text = part["text"] as? String, !text.isEmpty else { continue }
            result.append(part["thought"] as? Bool == true ? .reasoning(text) : .text(text))
        }
        if let usage = chunk["usageMetadata"] as? [String: Any] {
            let answer = usage["candidatesTokenCount"] as? Int
            let thought = usage["thoughtsTokenCount"] as? Int
            result.append(.usage(Usage(
                inputTokens: usage["promptTokenCount"] as? Int,
                outputTokens: answer.map { $0 + (thought ?? 0) } ?? thought,
                reasoningTokens: thought
            )))
        }
        return result
    }

    /// The conversation as Gemini's `contents`; turns with nothing in them are left out.
    static func contents(_ chat: ChatRequest) -> [[String: Any]] {
        (chat.history + [chat.input]).compactMap { turn in
            var parts: [[String: Any]] = []
            if !turn.text.isEmpty { parts.append(["text": turn.text]) }
            if turn.role == .user {
                for image in turn.images {
                    parts.append(["inline_data": ["mime_type": image.mediaType, "data": image.data.base64EncodedString()]])
                }
            }
            guard !parts.isEmpty else { return nil }
            return ["role": turn.role == .user ? "user" : "model", "parts": parts]
        }
    }

    // MARK: - Checking the connection

    /// The models that can answer chat, sorted (also proves the key works).
    public func models() async throws -> [String] {
        guard let url = HTTP.url(address, "/v1beta/models?pageSize=1000") else { throw BackendError.notConfigured }
        let object = try await HTTP.json(try HTTP.request(url, key: apiKey, keyHeader: "x-goog-api-key"))
        guard let list = (object as? [String: Any])?["models"] as? [[String: Any]] else {
            throw BackendError.invalidResponse("no model list")
        }
        return list
            .filter { ($0["supportedGenerationMethods"] as? [String])?.contains("generateContent") ?? true }
            .compactMap { ($0["name"] as? String).map { $0.hasPrefix("models/") ? String($0.dropFirst(7)) : $0 } }
            .sorted()
    }
}
