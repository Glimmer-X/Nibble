import Foundation

/// A persona of the reader's for the model APIs: a name, and instructions sent with every request
/// as the system prompt (the tone of the answers, what to focus on). Hermes answers as its own
/// profiles instead.
public struct Persona: Codable, Sendable, Equatable, Identifiable, Hashable {
    public let id: UUID
    public var name: String
    public var prompt: String

    public init(id: UUID = UUID(), name: String, prompt: String = "") {
        self.id = id
        self.name = name
        self.prompt = prompt
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        name = try c.decodeIfPresent(String.self, forKey: .name) ?? ""
        prompt = try c.decodeIfPresent(String.self, forKey: .prompt) ?? ""
    }
}
