import Foundation

/// Token counts when the backend reports none.
public enum Tokens {
    /// A rough count: a Chinese, Japanese or Korean character is about one token, other text about
    /// four characters to a token.
    public static func estimate(_ text: String) -> Double {
        var wide = 0.0
        var narrow = 0.0
        for scalar in text.unicodeScalars {
            switch scalar.value {
            case 0x3000...0x9FFF, 0xAC00...0xD7AF, 0xF900...0xFAFF, 0xFF00...0xFFEF, 0x20000...0x2FFFF:
                wide += 1
            default:
                narrow += 1
            }
        }
        return wide + narrow / 4
    }

    /// The tokens a reply wrote: what the backend reported, or an estimate from its text.
    public static func written(by reply: Message) -> Int {
        if let output = reply.stats?.usage?.outputTokens { return output }
        return Int(estimate(reply.text).rounded())
    }
}
