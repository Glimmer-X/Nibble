import Foundation

/// A file the user attached to a message. Only metadata lives here; the bytes are owned by a
/// `ConversationRepository`, stored next to the conversation they belong to.
public struct Attachment: Identifiable, Codable, Sendable, Equatable {
    /// Where an attachment came from.
    public enum Source: String, Codable, Sendable {
        /// Nibble captured the screen.
        case screenshot
        /// Dropped or pasted.
        case file
    }

    public let id: UUID
    /// MIME type, for example `image/png`.
    public let mediaType: String
    public let byteCount: Int
    /// The file's name, for dropped or pasted files that have one.
    public var name: String?
    public var source: Source?
    public var createdAt: Date?

    public init(
        id: UUID = UUID(),
        mediaType: String,
        byteCount: Int,
        name: String? = nil,
        source: Source? = nil,
        createdAt: Date? = nil
    ) {
        self.id = id
        self.mediaType = mediaType
        self.byteCount = byteCount
        self.name = name
        self.source = source
        self.createdAt = createdAt
    }

    public var isImage: Bool { mediaType.hasPrefix("image/") }
}
