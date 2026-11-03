import Foundation
import NibbleCore

/// A backend that needs no network: it waits, works through a few activities, then streams a
/// fixed reply with the pacing of a real model. Used while designing the UI, in tests, and as the
/// stand-in before any backend is set up.
public struct ScriptedBackend: ChatBackend {
    /// One step of the script.
    public enum Step: Sendable {
        case wait(Duration)
        case think(Duration)
        case activity(Activity, Duration)
        /// Streams the reply at about this many tokens a second.
        case write(tokensPerSecond: Double)
        case fail(BackendError)
        /// Asks for the reader's OK, waits for the answer, then runs the command for `run`.
        case ask(String, run: Duration = .seconds(2))
    }

    public var steps: [Step]
    private let approvals = ApprovalGate()
    public var reply: @Sendable (ChatRequest) -> String

    public init(
        steps: [Step] = ScriptedBackend.sampleSteps,
        reply: @escaping @Sendable (ChatRequest) -> String = ScriptedBackend.sampleReply
    ) {
        self.steps = steps
        self.reply = reply
    }

    public func respond(to request: ChatRequest) -> AsyncThrowingStream<ChatEvent, any Error> {
        let text = reply(request)
        let steps = self.steps
        return AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    for step in steps {
                        switch step {
                        case .wait(let duration):
                            try await Task.sleep(for: duration)
                        case .think(let duration):
                            continuation.yield(.reasoning(""))
                            try await Task.sleep(for: duration)
                        case .activity(let activity, let duration):
                            continuation.yield(.activity(activity))
                            try await Task.sleep(for: duration)
                            continuation.yield(.activityEnded)
                        case .write(let speed):
                            for piece in Self.pieces(of: text) {
                                try await Task.sleep(for: .seconds(1 / max(1, speed)))
                                continuation.yield(.text(piece))
                            }
                        case .fail(let error):
                            throw error
                        case .ask(let summary, let run):
                            let approval = Approval(id: UUID().uuidString, summary: summary, canAllowForConversation: true)
                            continuation.yield(.approval(approval))
                            guard await approvals.wait(for: approval.id) else {
                                continuation.yield(.text("好的，不运行这条命令。"))
                                continuation.finish()
                                return
                            }
                            continuation.yield(.activity(Activity(.tool, detail: summary)))
                            try await Task.sleep(for: run)
                            continuation.yield(.activityEnded)
                        }
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    public func answer(_ approval: Approval, with answer: ApprovalAnswer) async throws {
        await approvals.answer(approval.id, allow: answer.allows)
    }

    /// Scripts for trying the panel: `sample` (the default), `fail`, `ask`, and for recordings, in
    /// English at a pace that shows each light: `demo` (thinks long, searches, reads, answers),
    /// `demo-tool` (asks to run a command, runs it), `demo-fail` (cannot connect) and `demo-retry`.
    public static func named(_ name: String) -> ScriptedBackend {
        switch name {
        case "demo":
            ScriptedBackend(steps: demoSteps, reply: { _ in demoReply })
        case "demo-tool":
            ScriptedBackend(
                steps: [.wait(.milliseconds(600)), .think(.seconds(1)), .ask("python3 -m pip install requests", run: .seconds(6)), .write(tokensPerSecond: 44)],
                reply: { _ in "Installed `requests` 2.32.3. You can `import requests` in your script now." }
            )
        case "demo-fail":
            ScriptedBackend(steps: [.wait(.milliseconds(800)), .think(.seconds(1.2)), .fail(.cannotConnect(address: "127.0.0.1:8642"))])
        case "demo-retry":
            ScriptedBackend(
                steps: [.wait(.milliseconds(600)), .think(.seconds(1)), .write(tokensPerSecond: 50)],
                reply: { _ in "Hi all,\n\nTwo quick changes this week:\n\n- Standup moves to **10:00**.\n- The demo is on **Friday**.\n\nThanks!" }
            )
        case "fail":
            ScriptedBackend(steps: [.wait(.milliseconds(1200)), .think(.seconds(2)), .fail(.cannotConnect(address: "127.0.0.1:8642"))])
        case "ask":
            ScriptedBackend(steps: [.wait(.milliseconds(800)), .think(.seconds(1.5)), .ask("python3 -m pip install requests"), .write(tokensPerSecond: 40)])
        default:
            ScriptedBackend()
        }
    }

    /// Splits text into pieces of about one token: a Chinese character, or up to four other
    /// characters.
    static func pieces(of text: String) -> [String] {
        var result: [String] = []
        var current = ""
        for character in text {
            let wide = character.unicodeScalars.first.map { $0.value >= 0x3000 } ?? false
            if wide {
                if !current.isEmpty { result.append(current) }
                result.append(String(character))
                current = ""
                continue
            }
            current.append(character)
            if current.count == 4 || character.isNewline {
                result.append(current)
                current = ""
            }
        }
        if !current.isEmpty { result.append(current) }
        return result
    }

    public static let sampleSteps: [Step] = [
        .wait(.milliseconds(1400)),
        .think(.seconds(2)),
        .activity(Activity(.searching), .seconds(2)),
        .activity(Activity(.reading), .seconds(2)),
        .write(tokensPerSecond: 60),
    ]

    /// The recording's pace: long enough in each state for its light to read, thinking long
    /// enough for the tunnel to gather pace.
    public static let demoSteps: [Step] = [
        .wait(.milliseconds(900)),
        .think(.seconds(8)),
        .activity(Activity(.searching), .seconds(2)),
        .activity(Activity(.reading), .seconds(3.2)),
        .write(tokensPerSecond: 48),
    ]

    public static let demoReply = """
    For a jammy yolk, boil a large egg straight from the fridge for **6½ minutes**.

    1. Bring a pan of water to a rolling boil.
    2. Lower the eggs in gently with a spoon.
    3. After 6½ minutes, move them to iced water for 2 minutes.

    | Time | Yolk |
    |---|---|
    | 6 min | runny |
    | 6½ min | jammy |
    | 8 min | just set |

    Smaller eggs need about 30 seconds less.
    """

    /// A reply that exercises the things the chat surface has to render.
    public static let sampleReply: @Sendable (ChatRequest) -> String = { request in
        let asked = request.input.text.isEmpty ? "（没有文字）" : request.input.text
        let images = request.input.images.count
        return """
        这是 **Nibble** 的示例回答，还没有接上真正的模型。你说的是：

        > \(asked)

        \(images == 0 ? "没有附图。" : "附了 \(images) 张图。")

        ### 能显示的东西

        1. 列表、`行内代码`和代码块
        2. 引用和表格

        ```swift
        let answer = 42
        ```

        | 命令 | 用途 |
        |---|---|
        | `pip list` | 看已经装了哪些库 |
        | `pip show requests` | 看版本和安装位置 |

        更多见 [pip 文档](https://pip.pypa.io/)。
        """
    }
}

/// Holds a scripted approval until the reader answers it.
private actor ApprovalGate {
    private var waiting: [String: CheckedContinuation<Bool, Never>] = [:]
    private var answered: [String: Bool] = [:]

    func wait(for id: String) async -> Bool {
        if let answer = answered.removeValue(forKey: id) { return answer }
        return await withCheckedContinuation { waiting[id] = $0 }
    }

    func answer(_ id: String, allow: Bool) {
        if let continuation = waiting.removeValue(forKey: id) {
            continuation.resume(returning: allow)
        } else {
            answered[id] = allow
        }
    }
}
