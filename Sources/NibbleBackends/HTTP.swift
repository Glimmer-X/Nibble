import Foundation
import NibbleCore

/// One server-sent event: its name (`event:`, "message" when absent) and its data.
struct ServerSentEvent: Equatable {
    var name: String
    var data: String
}

/// Reads server-sent events from a byte stream (text/event-stream): `event:` and `data:` lines,
/// dispatched at a blank line; comments (`: keepalive`) are skipped.
struct ServerSentEventParser {
    private var name = ""
    private var data: [String] = []
    private var line: [UInt8] = []

    /// Feeds one byte; returns an event when one is complete.
    mutating func feed(_ byte: UInt8) -> ServerSentEvent? {
        guard byte == UInt8(ascii: "\n") else {
            line.append(byte)
            return nil
        }
        if line.last == UInt8(ascii: "\r") { line.removeLast() }
        let text = String(decoding: line, as: UTF8.self)
        line.removeAll(keepingCapacity: true)
        return take(text)
    }

    /// Ends the stream; returns a last event that had no blank line after it.
    mutating func finish() -> ServerSentEvent? {
        if !line.isEmpty {
            let text = String(decoding: line, as: UTF8.self)
            line.removeAll()
            if let event = take(text) { return event }
        }
        return dispatch()
    }

    private mutating func take(_ text: String) -> ServerSentEvent? {
        if text.isEmpty { return dispatch() }
        if text.hasPrefix(":") { return nil }
        let field: Substring
        var value: Substring
        if let colon = text.firstIndex(of: ":") {
            field = text[..<colon]
            value = text[text.index(after: colon)...]
            if value.first == " " { value = value.dropFirst() }
        } else {
            field = Substring(text)
            value = ""
        }
        switch field {
        case "event": name = String(value)
        case "data": data.append(String(value))
        default: break
        }
        return nil
    }

    private mutating func dispatch() -> ServerSentEvent? {
        defer {
            name = ""
            data = []
        }
        guard !data.isEmpty else { return nil }
        return ServerSentEvent(name: name.isEmpty ? "message" : name, data: data.joined(separator: "\n"))
    }
}

/// Shared HTTP plumbing for the backends.
enum HTTP {
    /// One session for every backend: no cache, no cookies, a generous wait for the first byte
    /// (models can think for a while) and no limit on a whole streamed reply.
    static let session: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 180
        configuration.timeoutIntervalForResource = 60 * 60
        configuration.waitsForConnectivity = false
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        return URLSession(configuration: configuration)
    }()

    /// A request with the key as a bearer token, or in `keyHeader` for APIs that want it there;
    /// `headers` adds any others.
    static func request(
        _ url: URL, method: String = "GET", key: String?, keyHeader: String? = nil, headers: [String: String] = [:],
        json: Any? = nil, accept: String = "application/json"
    ) throws -> URLRequest {
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.setValue(accept, forHTTPHeaderField: "Accept")
        if let key, !key.isEmpty {
            if let keyHeader {
                request.setValue(key, forHTTPHeaderField: keyHeader)
            } else {
                request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
            }
        }
        for (name, value) in headers { request.setValue(value, forHTTPHeaderField: name) }
        if let json {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try JSONSerialization.data(withJSONObject: json)
        }
        return request
    }

    /// Sends a request and returns the JSON body, mapping failures to `BackendError`.
    static func json(_ request: URLRequest) async throws -> Any {
        let (data, response) = try await perform { try await session.data(for: request) }
        try check(response, body: data, address: request.url)
        do {
            return try JSONSerialization.jsonObject(with: data)
        } catch {
            throw BackendError.invalidResponse("not JSON")
        }
    }

    /// Opens a streamed response, mapping failures to `BackendError`. The body of a failed
    /// response is read so its message can be shown.
    static func stream(_ request: URLRequest) async throws -> URLSession.AsyncBytes {
        let (bytes, response) = try await perform { try await session.bytes(for: request) }
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            var body = Data()
            for try await byte in bytes {
                body.append(byte)
                if body.count > 64_000 { break }
            }
            try check(response, body: body, address: request.url)
        }
        return bytes
    }

    /// Runs a network call, turning URL errors into `BackendError`.
    static func perform<T>(_ call: () async throws -> T) async throws -> T {
        do {
            return try await call()
        } catch let error as URLError {
            throw map(error)
        }
    }

    static func map(_ error: URLError) -> any Error {
        switch error.code {
        case .cancelled:
            return CancellationError()
        case .timedOut:
            return BackendError.timedOut
        case .cannotConnectToHost, .cannotFindHost, .networkConnectionLost, .notConnectedToInternet,
             .dnsLookupFailed, .secureConnectionFailed, .appTransportSecurityRequiresSecureConnection:
            return BackendError.cannotConnect(address: address(error.failingURL))
        default:
            return BackendError.cannotConnect(address: address(error.failingURL))
        }
    }

    static func check(_ response: URLResponse, body: Data, address url: URL?) throws {
        guard let http = response as? HTTPURLResponse else { return }
        guard !(200..<300).contains(http.statusCode) else { return }
        let message = errorMessage(in: body)
        // Gemini refuses a bad key with 400 and the reason in the body.
        if http.statusCode == 400, String(decoding: body.prefix(4000), as: UTF8.self).contains("API_KEY_INVALID") {
            throw BackendError.unauthorized
        }
        switch http.statusCode {
        case 401, 403: throw BackendError.unauthorized
        case 429: throw BackendError.rateLimited
        default: throw BackendError.server(status: http.statusCode, message: message)
        }
    }

    /// The message in an error body: `{"error": {"message": …}}`, `{"error": "…"}` or `{"message": …}`.
    static func errorMessage(in body: Data) -> String? {
        guard let object = try? JSONSerialization.jsonObject(with: body) as? [String: Any] else {
            let text = String(decoding: body.prefix(400), as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
            return text.isEmpty ? nil : text
        }
        if let error = object["error"] as? [String: Any], let message = error["message"] as? String { return message }
        if let error = object["error"] as? String { return error }
        if let message = object["message"] as? String { return message }
        if let detail = object["detail"] as? String { return detail }
        return nil
    }

    /// host:port of a URL, as shown to the reader.
    static func address(_ url: URL?) -> String {
        guard let url, let host = url.host() else { return url?.absoluteString ?? "" }
        if let port = url.port { return "\(host):\(port)" }
        return host
    }

    /// A data URL for an image.
    static func dataURL(_ image: ChatRequest.Image) -> String {
        "data:\(image.mediaType);base64,\(image.data.base64EncodedString())"
    }

    /// Streams the reply to `request` with `send`, which yields the events of one attempt. A model
    /// that takes no system prompt refuses the request before anything arrives; then it is sent
    /// once more with the persona's instructions in front of the first question.
    static func reply(
        to request: ChatRequest,
        _ send: @escaping @Sendable (ChatRequest, AsyncThrowingStream<ChatEvent, any Error>.Continuation) async throws -> Void
    ) -> AsyncThrowingStream<ChatEvent, any Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    do {
                        try await send(request, continuation)
                    } catch let error as BackendError where request.instructions != nil && refusesInstructions(error) {
                        try await send(request.foldingInstructions, continuation)
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    /// Whether an error says the model takes no system prompt ("Developer instruction is not
    /// enabled", "does not support 'system'").
    static func refusesInstructions(_ error: BackendError) -> Bool {
        guard case .server(400, let message?) = error else { return false }
        let text = message.lowercased()
        return text.contains("system") || text.contains("instruction") || text.contains("developer")
    }

    /// Joins a base address and a path, tolerating a trailing slash on the base.
    static func url(_ base: String, _ path: String) -> URL? {
        var trimmed = base.trimmingCharacters(in: .whitespacesAndNewlines)
        while trimmed.hasSuffix("/") { trimmed.removeLast() }
        guard !trimmed.isEmpty else { return nil }
        if !trimmed.contains("://") { trimmed = "https://" + trimmed }
        return URL(string: trimmed + path)
    }
}

extension ChatRequest {
    /// The same request with the instructions in front of the first question, for models that
    /// take no system prompt.
    var foldingInstructions: ChatRequest {
        guard let instructions else { return self }
        func folded(_ turn: Turn) -> Turn {
            Turn(role: turn.role, text: turn.text.isEmpty ? instructions : "\(instructions)\n\n\(turn.text)", images: turn.images)
        }
        if let first = history.firstIndex(where: { $0.role == .user }) {
            var turns = history
            turns[first] = folded(turns[first])
            return ChatRequest(history: turns, input: input, remoteSessionID: remoteSessionID)
        }
        return ChatRequest(history: history, input: folded(input), remoteSessionID: remoteSessionID)
    }
}
