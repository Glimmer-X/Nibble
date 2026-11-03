import Foundation
import NibbleCore
import UniformTypeIdentifiers

/// Stores each conversation in its own folder: `conversation.json` plus an `attachments` folder.
/// Deleting a conversation deletes its folder, so nothing it owned is left behind.
public actor FileConversationRepository: ConversationRepository {
    private static let conversationFileName = "conversation.json"
    private static let attachmentsFolderName = "attachments"
    /// Files nobody refers to (an attachment the user removed before sending, a conversation
    /// that was never sent) are kept this long before pruning removes them, so a conversation
    /// that is still being written is never swept.
    private static let unreferencedGracePeriod: TimeInterval = 86_400

    private let root: URL

    public init(paths: AppPaths) {
        self.root = paths.conversationsDirectory
    }

    // MARK: - Conversations

    public func save(_ conversation: Conversation) throws {
        try JSONFile.write(conversation, to: conversationFile(conversation.id))
    }

    public func load(id: Conversation.ID) throws -> Conversation? {
        try JSONFile.read(Conversation.self, from: conversationFile(id))
    }

    public func latest() throws -> Conversation? {
        guard let newest = try savedConversations().max(by: { $0.modified < $1.modified }) else { return nil }
        return try load(id: newest.id)
    }

    public func all() throws -> [Conversation] {
        try savedConversations()
            .sorted { $0.modified > $1.modified }
            .compactMap { try? load(id: $0.id) }
    }

    public func delete(id: Conversation.ID) throws {
        let folder = folder(id)
        if FileManager.default.fileExists(atPath: folder.path(percentEncoded: false)) {
            try FileManager.default.removeItem(at: folder)
        }
    }

    // MARK: - Attachments

    public func storeAttachment(_ data: Data, mediaType: String, for conversationID: Conversation.ID) throws -> Attachment {
        let attachment = Attachment(mediaType: mediaType, byteCount: data.count)
        let file = attachmentFile(attachment, in: conversationID)
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: file, options: .atomic)
        return attachment
    }

    public func attachmentData(_ attachment: Attachment, in conversationID: Conversation.ID) throws -> Data {
        try Data(contentsOf: attachmentFile(attachment, in: conversationID))
    }

    // MARK: - Retention

    @discardableResult
    public func prune(_ policy: RetentionPolicy, now: Date) throws -> Int {
        let fileManager = FileManager.default
        var removed = 0

        // Folders without a conversation file hold attachments of a conversation that was never sent.
        for folder in try subfolders(of: root) where !exists(folder.appending(path: Self.conversationFileName)) {
            if now.timeIntervalSince(try modificationDate(folder)) > Self.unreferencedGracePeriod {
                try fileManager.removeItem(at: folder)
            }
        }

        let newestFirst = try savedConversations().sorted { $0.modified > $1.modified }
        for (index, entry) in newestFirst.enumerated() {
            let tooMany = index >= policy.maxConversations
            let tooOld = now.timeIntervalSince(entry.modified) > policy.maxAge
            if tooMany || tooOld {
                try delete(id: entry.id)
                removed += 1
            } else {
                try sweepUnreferencedAttachments(of: entry.id, now: now)
            }
        }
        return removed
    }

    private func sweepUnreferencedAttachments(of id: Conversation.ID, now: Date) throws {
        let folder = attachmentsFolder(id)
        guard exists(folder), let conversation = try load(id: id) else { return }
        let referenced = Set(conversation.messages.flatMap(\.attachments).map(\.id.uuidString))
        for file in try FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: [.contentModificationDateKey]) {
            let name = file.deletingPathExtension().lastPathComponent
            if !referenced.contains(name), now.timeIntervalSince(try modificationDate(file)) > Self.unreferencedGracePeriod {
                try FileManager.default.removeItem(at: file)
            }
        }
    }

    // MARK: - Layout

    private func folder(_ id: Conversation.ID) -> URL {
        root.appending(path: id.uuidString, directoryHint: .isDirectory)
    }

    private func conversationFile(_ id: Conversation.ID) -> URL {
        folder(id).appending(path: Self.conversationFileName, directoryHint: .notDirectory)
    }

    private func attachmentsFolder(_ id: Conversation.ID) -> URL {
        folder(id).appending(path: Self.attachmentsFolderName, directoryHint: .isDirectory)
    }

    private func attachmentFile(_ attachment: Attachment, in id: Conversation.ID) -> URL {
        let ext = UTType(mimeType: attachment.mediaType)?.preferredFilenameExtension ?? "bin"
        return attachmentsFolder(id).appending(path: "\(attachment.id.uuidString).\(ext)", directoryHint: .notDirectory)
    }

    private struct Entry {
        let id: Conversation.ID
        let modified: Date
    }

    private func savedConversations() throws -> [Entry] {
        try subfolders(of: root).compactMap { folder in
            guard let id = UUID(uuidString: folder.lastPathComponent) else { return nil }
            let file = folder.appending(path: Self.conversationFileName)
            guard exists(file) else { return nil }
            return Entry(id: id, modified: try modificationDate(file))
        }
    }

    private func subfolders(of url: URL) throws -> [URL] {
        guard exists(url) else { return [] }
        return try FileManager.default
            .contentsOfDirectory(at: url, includingPropertiesForKeys: [.isDirectoryKey, .contentModificationDateKey])
            .filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true }
    }

    private func exists(_ url: URL) -> Bool {
        FileManager.default.fileExists(atPath: url.path(percentEncoded: false))
    }

    private func modificationDate(_ url: URL) throws -> Date {
        try url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate ?? .distantPast
    }
}
