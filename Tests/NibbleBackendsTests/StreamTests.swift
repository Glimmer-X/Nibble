import Foundation
import Testing
@testable import NibbleBackends
@testable import NibbleCore

@Suite struct StreamTests {
    private func events(_ text: String) -> [ServerSentEvent] {
        var parser = ServerSentEventParser()
        var out: [ServerSentEvent] = []
        for byte in Array(text.utf8) {
            if let event = parser.feed(byte) { out.append(event) }
        }
        if let event = parser.finish() { out.append(event) }
        return out
    }

    @Test func serverSentEventsAreSplitAtBlankLines() {
        let parsed = events("event: hermes.status\ndata: {\"a\":1}\n\n: keepalive\n\ndata: x\r\ndata: y\n\ndata: [DONE]")
        #expect(parsed == [
            ServerSentEvent(name: "hermes.status", data: "{\"a\":1}"),
            ServerSentEvent(name: "message", data: "x\ny"),
            ServerSentEvent(name: "message", data: "[DONE]"),
        ])
    }

    @Test func openAIChunksCarryReasoningTextAndUsage() throws {
        let chunk: [String: Any] = [
            "choices": [["delta": ["reasoning_content": "hm", "content": "Hi"]]],
            "usage": ["prompt_tokens": 10, "completion_tokens": 4, "completion_tokens_details": ["reasoning_tokens": 2]],
        ]
        #expect(OpenAICompatibleBackend.events(in: chunk) == [
            .reasoning("hm"), .text("Hi"), .usage(Usage(inputTokens: 10, outputTokens: 4, reasoningTokens: 2)),
        ])
        // Ollama and OpenRouter call it `reasoning`.
        #expect(OpenAICompatibleBackend.events(in: ["choices": [["delta": ["reasoning": "x"]]]]) == [.reasoning("x")])
    }

    @Test func imagesGoInUserTurnsAsDataURLs() throws {
        let request = ChatRequest(
            history: [.init(role: .assistant, text: "a")],
            input: .init(role: .user, text: "look", images: [.init(mediaType: "image/png", data: Data([1]))])
        )
        let messages = OpenAICompatibleBackend.messages(request)
        #expect(messages.count == 2)
        let parts = try #require(messages[1]["content"] as? [[String: Any]])
        #expect(parts[0]["text"] as? String == "look")
        #expect((parts[1]["image_url"] as? [String: Any])?["url"] as? String == "data:image/png;base64,AQ==")
    }

    @Test func aHermesTurnMapsToolsWaitsAndApprovals() throws {
        var reader = HermesBackend.TurnReader()
        func read(_ name: String, _ json: String) throws -> [ChatEvent] {
            try reader.read(ServerSentEvent(name: name, data: json)).events
        }
        #expect(try read("message", #"{"id":"chatcmpl-1","choices":[{"delta":{"role":"assistant"}}]}"#) == [.activity(.thinking)])
        #expect(try read("hermes.status", #"{"kind":"lifecycle","text":"⏳ Rate limited, retrying in 4s"}"#) == [.waiting("⏳ Rate limited, retrying in 4s")])
        #expect(try read("hermes.status", #"{"kind":"compacted","text":"Context compacted"}"#).isEmpty)
        #expect(try read("message", #"{"choices":[{"delta":{"reasoning_content":"Let me look."}}]}"#) == [.reasoning("Let me look.")])
        // Text before a tool call was the model talking on its way: it leaves the answer.
        #expect(try read("message", #"{"choices":[{"delta":{"content":"Searching…"}}]}"#) == [.text("Searching…")])
        #expect(try read("hermes.tool.progress", #"{"tool":"web_search","label":"swift actors","toolCallId":"t1","status":"running"}"#) == [
            .replaceAnswer(""), .reasoning("Searching…\n"), .activity(Activity(.searching, detail: "swift actors")),
        ])
        #expect(try read("hermes.tool.progress", #"{"tool":"web_search","toolCallId":"t1","status":"completed"}"#) == [.activityEnded])
        #expect(try read("approval.request", #"{"run_id":"chatcmpl-1","request_id":"r9","command":"rm -rf build","choices":["once","session","always","deny"]}"#) == [
            .approval(Approval(id: "chatcmpl-1|r9", summary: "rm -rf build", canAllowForConversation: true)),
        ])
        // After Hermes's own check refused the command it offers only this once or no.
        #expect(try read("approval.request", #"{"run_id":"chatcmpl-1","request_id":"r10","command":"rm -rf /","choices":["once","deny"]}"#) == [
            .approval(Approval(id: "chatcmpl-1|r10", summary: "rm -rf /")),
        ])
        #expect(try read("message", #"{"choices":[{"delta":{"content":"Done."}}]}"#) == [.text("Done.")])
        #expect(try read("message", #"{"choices":[{"delta":{},"finish_reason":"stop"}],"usage":{"prompt_tokens":900,"completion_tokens":30}}"#) == [
            .usage(Usage(inputTokens: 900, outputTokens: 30)),
        ])
        #expect(try reader.read(ServerSentEvent(name: "message", data: "[DONE]")).done)
    }

    @Test func aHermesApprovalIsAnsweredWithTheGenerationItCameWith() throws {
        var reader = HermesBackend.TurnReader()
        // Under Hermes's session authority the request carries the run's execution generation, and
        // the answer must carry it back with exactly these fields (anything else is HTTP 400).
        let fenced = try reader.read(ServerSentEvent(
            name: "approval.request",
            data: #"{"run_id":"chatcmpl-7","request_id":"p1","execution_generation":3,"command":"python3 a.py"}"#
        )).events
        #expect(fenced == [.approval(Approval(id: "chatcmpl-7|p1|3", summary: "python3 a.py"))])
        let handle = try #require(HermesBackend.ApprovalHandle("chatcmpl-7|p1|3"))
        #expect(handle == HermesBackend.ApprovalHandle(run: "chatcmpl-7", request: "p1", generation: 3))
        let body = handle.body(.allow)
        #expect(Set(body.keys) == ["choice", "request_id", "execution_generation"])
        #expect(body["choice"] as? String == "once" && body["request_id"] as? String == "p1" && body["execution_generation"] as? Int == 3)
        #expect(handle.body(.allowForConversation)["choice"] as? String == "session")
        // Without the authority there is no generation, and the answer leaves it out.
        let plain = try #require(HermesBackend.ApprovalHandle("chatcmpl-7|p2"))
        #expect(Set(plain.body(.deny).keys) == ["choice", "request_id"])
        #expect(plain.body(.deny)["choice"] as? String == "deny")
        #expect(HermesBackend.ApprovalHandle("chatcmpl-7|") == nil)
    }

    @Test func hermesHandlesNameTheProfileAndTheSession() throws {
        let handle = HermesBackend.handle(profile: "writer", session: "nibble-abc")
        let parsed = try #require(HermesBackend.parse(handle: handle))
        #expect(parsed.profile == "writer" && parsed.session == "nibble-abc")
        #expect(HermesBackend.parse(handle: "nibble-abc") == nil)
        #expect(HermesBackend.parse(handle: "/nibble-abc") == nil)
        #expect(HermesBackend.parse(handle: "default/") == nil)
    }

    @Test func aHermesConversationIsDeletedWithItsContinuations() async throws {
        // a was compressed into b, b into c; x continued from somewhere else.
        let parents = ["c": "b", "b": "a", "x": "elsewhere"]
        func lineage(_ id: String, live: String?) async throws -> [String] {
            try await HermesBackend.lineage(of: id, live: { _ in live }, parent: { parents[$0] })
        }
        #expect(try await lineage("a", live: nil) == [])
        #expect(try await lineage("a", live: "a") == ["a"])
        #expect(try await lineage("a", live: "c") == ["c", "b", "a"])
        // A chain that does not lead back stops at the live session: nothing else is touched.
        #expect(try await lineage("a", live: "x") == ["x", "a"])
    }

    @Test func aFailedHermesRunThrowsItsMessage() {
        var reader = HermesBackend.TurnReader()
        #expect(throws: BackendError.failed("provider down")) {
            try reader.read(ServerSentEvent(name: "message", data: #"{"choices":[{"delta":{},"finish_reason":"error"}],"error":{"message":"provider down"}}"#))
        }
    }

    @Test func toolNamesMapToKinds() {
        #expect(HermesBackend.TurnReader.kind(ofTool: "web_search") == .searching)
        #expect(HermesBackend.TurnReader.kind(ofTool: "web_extract") == .reading)
        #expect(HermesBackend.TurnReader.kind(ofTool: "vision_analyze") == .looking)
        #expect(HermesBackend.TurnReader.kind(ofTool: "terminal") == .tool)
    }

    @Test func dotenvValuesAreRead() {
        let text = """
        # comment
        OTHER=1
        export API_SERVER_KEY="abc def"
        """
        #expect(HermesDirectory.value(of: "API_SERVER_KEY", in: text) == "abc def")
        #expect(HermesDirectory.value(of: "OTHER", in: "OTHER=2 # note") == "2")
        #expect(HermesDirectory.value(of: "MISSING", in: text) == nil)
    }

    @Test func addressesJoinWithoutDoubleSlashes() {
        #expect(HTTP.url("https://api.deepseek.com/", "/models")?.absoluteString == "https://api.deepseek.com/models")
        #expect(HTTP.url("api.deepseek.com", "/models")?.absoluteString == "https://api.deepseek.com/models")
        #expect(HTTP.url("", "/models") == nil)
    }

    // MARK: - Personas and the other APIs

    @Test func instructionsLeadAsASystemMessage() {
        let request = ChatRequest(history: [], input: .init(role: .user, text: "hi"), instructions: "Be brief.")
        let messages = OpenAICompatibleBackend.messages(request)
        #expect(messages.count == 2)
        #expect(messages[0]["role"] as? String == "system")
        #expect(messages[0]["content"] as? String == "Be brief.")
    }

    @Test func aModelWithoutSystemPromptsGetsTheInstructionsInFrontOfTheFirstQuestion() {
        let request = ChatRequest(
            history: [.init(role: .user, text: "first"), .init(role: .assistant, text: "ok")],
            input: .init(role: .user, text: "second"),
            instructions: "Be brief."
        )
        let folded = request.foldingInstructions
        #expect(folded.instructions == nil)
        #expect(folded.history[0].text == "Be brief.\n\nfirst")
        #expect(folded.input.text == "second")
        #expect(HTTP.refusesInstructions(.server(status: 400, message: "Developer instruction is not enabled for models/gemma-3")))
        #expect(!HTTP.refusesInstructions(.server(status: 400, message: "max_tokens too large")))
        #expect(!HTTP.refusesInstructions(.server(status: 500, message: "system overloaded")))
    }

    @Test func geminiChunksSplitThoughtsFromTheAnswer() throws {
        let chunk: [String: Any] = [
            "candidates": [["content": ["parts": [["text": "hm", "thought": true], ["text": "Hi"]]]]],
            "usageMetadata": ["promptTokenCount": 10, "candidatesTokenCount": 4, "thoughtsTokenCount": 2],
        ]
        #expect(try GeminiBackend.events(in: chunk) == [
            .reasoning("hm"), .text("Hi"), .usage(Usage(inputTokens: 10, outputTokens: 6, reasoningTokens: 2)),
        ])
        #expect(throws: BackendError.self) { try GeminiBackend.events(in: ["promptFeedback": ["blockReason": "SAFETY"]]) }
    }

    @Test func geminiContentsUseItsRolesAndInlineImages() throws {
        let request = ChatRequest(
            history: [.init(role: .user, text: "a"), .init(role: .assistant, text: "")],
            input: .init(role: .user, text: "look", images: [.init(mediaType: "image/png", data: Data([1]))])
        )
        let contents = GeminiBackend.contents(request)
        // The empty answer is left out; Gemini refuses turns without parts.
        #expect(contents.map { $0["role"] as? String } == ["user", "user"])
        let parts = try #require(contents[1]["parts"] as? [[String: Any]])
        #expect((parts[1]["inline_data"] as? [String: Any])?["data"] as? String == "AQ==")
    }

    @Test func claudeEventsGatherUsageAcrossTheStream() {
        var usage = Usage()
        let start: [String: Any] = ["type": "message_start", "message": ["usage": ["input_tokens": 7, "cache_read_input_tokens": 3, "output_tokens": 1]]]
        #expect(AnthropicBackend.events(in: start, usage: &usage) == [.usage(Usage(inputTokens: 10, outputTokens: 1))])
        let text: [String: Any] = ["type": "content_block_delta", "delta": ["type": "text_delta", "text": "Hi"]]
        #expect(AnthropicBackend.events(in: text, usage: &usage) == [.text("Hi")])
        let thinking: [String: Any] = ["type": "content_block_delta", "delta": ["type": "thinking_delta", "thinking": "hm"]]
        #expect(AnthropicBackend.events(in: thinking, usage: &usage) == [.reasoning("hm")])
        let end: [String: Any] = ["type": "message_delta", "usage": ["output_tokens": 12]]
        #expect(AnthropicBackend.events(in: end, usage: &usage) == [.usage(Usage(inputTokens: 10, outputTokens: 12))])
    }

    @Test func claudeMessagesPutImagesBeforeText() throws {
        let request = ChatRequest(
            history: [],
            input: .init(role: .user, text: "look", images: [.init(mediaType: "image/jpeg", data: Data([1]))])
        )
        let content = try #require(AnthropicBackend.messages(request).first?["content"] as? [[String: Any]])
        #expect(content.map { $0["type"] as? String } == ["image", "text"])
        #expect((content[0]["source"] as? [String: Any])?["media_type"] as? String == "image/jpeg")
    }
}
