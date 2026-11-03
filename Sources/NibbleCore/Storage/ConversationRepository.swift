import Foundation

/// Where conversations and their attachments live. NibbleStore provides the file-backed
/// implementation; tests use an in-memory one.
public protocol ConversationRepository: Sendable {
    func save(_ conversation: Conversation) async throws
    func load(id: Conversation.ID) async throws -> Conversation?
    /// The most recently updated conversation, if any.
    func latest() async throws -> Conversation?
    /// Every saved conversation, the most recently updated first.
    func all() async throws -> [Conversation]
    func delete(id: Conversation.ID) async throws

    /// Stores the bytes of a new attachment for `conversationID` and returns its metadata.
    func storeAttachment(_ data: Data, mediaType: String, for conversationID: Conversation.ID) async throws -> Attachment
    func attachmentData(_ attachment: Attachment, in conversationID: Conversation.ID) async throws -> Data

    /// Deletes what the policy no longer allows to keep. Returns how many conversations were removed.
    @discardableResult
    func prune(_ policy: RetentionPolicy, now: Date) async throws -> Int
}
