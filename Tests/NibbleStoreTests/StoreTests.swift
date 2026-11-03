import Foundation
import NibbleCore
import Testing
@testable import NibbleStore

@Suite struct StoreTests {
    /// A fresh data directory per test, removed when the test ends.
    final class Sandbox {
        let paths: AppPaths

        init() throws {
            let url = FileManager.default.temporaryDirectory
                .appending(path: "nibble-store-tests-\(UUID().uuidString)", directoryHint: .isDirectory)
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
            paths = AppPaths(dataDirectory: url)
        }

        deinit { try? FileManager.default.removeItem(at: paths.dataDirectory) }

        func setModificationDate(_ date: Date, of url: URL) throws {
            try FileManager.default.setAttributes([.modificationDate: date], ofItemAtPath: url.path(percentEncoded: false))
        }

        func folder(of id: UUID) -> URL {
            paths.conversationsDirectory.appending(path: id.uuidString, directoryHint: .isDirectory)
        }
    }

    @Test func conversationsRoundTripAndLatestIsTheNewest() async throws {
        let sandbox = try Sandbox()
        let repository = FileConversationRepository(paths: sandbox.paths)
        // Stored dates keep milliseconds, so use timestamps that have no finer part.
        let time = Date(timeIntervalSince1970: 1_793_000_000.125)
        let older = Conversation(createdAt: time, messages: [Message(role: .user, text: "old", createdAt: time)])
        let newer = Conversation(
            createdAt: time,
            messages: [Message(role: .user, text: "new", createdAt: time, status: .failed(reason: "x"))]
        )
        try await repository.save(older)
        try await repository.save(newer)
        try sandbox.setModificationDate(Date(timeIntervalSinceNow: -60), of: sandbox.folder(of: older.id).appending(path: "conversation.json"))

        #expect(try await repository.load(id: older.id) == older)
        #expect(try await repository.latest() == newer)

        try await repository.delete(id: newer.id)
        #expect(try await repository.load(id: newer.id) == nil)
        #expect(!FileManager.default.fileExists(atPath: sandbox.folder(of: newer.id).path(percentEncoded: false)))
    }

    @Test func attachmentsLiveInTheirConversationFolder() async throws {
        let sandbox = try Sandbox()
        let repository = FileConversationRepository(paths: sandbox.paths)
        let conversation = Conversation()
        let attachment = try await repository.storeAttachment(Data([9, 8, 7]), mediaType: "image/png", for: conversation.id)

        #expect(attachment.byteCount == 3)
        #expect(try await repository.attachmentData(attachment, in: conversation.id) == Data([9, 8, 7]))
        let file = sandbox.folder(of: conversation.id).appending(path: "attachments/\(attachment.id.uuidString).png")
        #expect(FileManager.default.fileExists(atPath: file.path(percentEncoded: false)))
    }

    @Test func pruningEnforcesAgeCountAndSweepsUnreferencedFiles() async throws {
        let sandbox = try Sandbox()
        let repository = FileConversationRepository(paths: sandbox.paths)
        let now = Date()

        // Three saved conversations: one too old, two recent.
        var ids: [UUID] = []
        for (index, age) in [40.0, 2.0, 1.0].enumerated() {
            let conversation = Conversation(messages: [Message(role: .user, text: "\(index)")])
            try await repository.save(conversation)
            let file = sandbox.folder(of: conversation.id).appending(path: "conversation.json")
            try sandbox.setModificationDate(now.addingTimeInterval(-age * 86_400), of: file)
            ids.append(conversation.id)
        }

        // A kept conversation with one referenced and one stale unreferenced attachment.
        let used = try await repository.storeAttachment(Data([1]), mediaType: "image/png", for: ids[2])
        let unused = try await repository.storeAttachment(Data([2]), mediaType: "image/png", for: ids[2])
        var kept = try #require(try await repository.load(id: ids[2]))
        kept.messages[0].attachments = [used]
        try await repository.save(kept)
        let unusedFile = sandbox.folder(of: ids[2]).appending(path: "attachments/\(unused.id.uuidString).png")
        try sandbox.setModificationDate(now.addingTimeInterval(-2 * 86_400), of: unusedFile)

        // A folder from a conversation that was never sent.
        let orphan = Conversation()
        _ = try await repository.storeAttachment(Data([3]), mediaType: "image/png", for: orphan.id)
        try sandbox.setModificationDate(now.addingTimeInterval(-2 * 86_400), of: sandbox.folder(of: orphan.id))

        let removed = try await repository.prune(RetentionPolicy(maxAgeDays: 30, maxConversations: 1), now: now)

        #expect(removed == 2)
        #expect(try await repository.load(id: ids[0]) == nil)
        #expect(try await repository.load(id: ids[1]) == nil)
        #expect(try await repository.load(id: ids[2]) != nil)
        #expect(try await repository.attachmentData(used, in: ids[2]) == Data([1]))
        #expect(!FileManager.default.fileExists(atPath: unusedFile.path(percentEncoded: false)))
        #expect(!FileManager.default.fileExists(atPath: sandbox.folder(of: orphan.id).path(percentEncoded: false)))
    }

    @Test func settingsDefaultWhenMissingAndToleratePartialFiles() throws {
        let sandbox = try Sandbox()
        let store = SettingsStore(paths: sandbox.paths)
        #expect(try store.load() == Settings())

        try Data(#"{"continueWindowMinutes": 3, "sendKey": "somethingNew"}"#.utf8).write(to: sandbox.paths.settingsFile)
        let partial = try store.load()
        #expect(partial.continueWindowMinutes == 3)
        #expect(partial.hotKey == .optionSpace)
        #expect(partial.sendKey == .return)
        #expect(partial.showInDock)
        #expect(partial.colorTheme == .violet)
        #expect(partial.background == .lava)

        var changed = partial
        changed.retention = RetentionPolicy(maxAgeDays: 7, maxConversations: 50)
        try store.save(changed)
        #expect(try store.load() == changed)
    }

    @Test func aFileFromBeforeGeminiAndPersonasKeepsItsBackend() throws {
        let sandbox = try Sandbox()
        let store = SettingsStore(paths: sandbox.paths)
        try Data(#"{"backend": {"kind": "openAI", "openAI": {"address": "https://api.deepseek.com", "model": "deepseek-flash"}}}"#.utf8)
            .write(to: sandbox.paths.settingsFile)
        var settings = try store.load()
        #expect(settings.backend.kind == .openAI)
        #expect(settings.backend[api: .openAI].model == "deepseek-flash")
        #expect(settings.backend.address(.gemini) == "https://generativelanguage.googleapis.com")
        #expect(settings.personas.isEmpty && settings.currentPersona == nil)

        let persona = Persona(name: "翻译", prompt: "把问题译成英文。")
        settings.personas = [persona]
        settings.persona = persona.id
        settings.backend.gemini.model = "gemini-2.5-flash"
        try store.save(settings)
        let loaded = try store.load()
        #expect(loaded.currentPersona == persona)
        #expect(loaded.backend.gemini.model == "gemini-2.5-flash")
    }

    @Test func dataDirectoryCanBeOverridden() {
        let paths = AppPaths.standard(bundleIdentifier: "x", environment: ["NIBBLE_DATA_DIR": "/tmp/nibble-elsewhere"])
        #expect(paths.dataDirectory.path(percentEncoded: false).hasPrefix("/tmp/nibble-elsewhere"))
        let standard = AppPaths.standard(bundleIdentifier: "com.example.app", environment: [:])
        #expect(standard.dataDirectory.path(percentEncoded: false).hasSuffix("Application Support/com.example.app/"))
    }
}
