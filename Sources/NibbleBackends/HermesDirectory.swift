import Foundation

/// A Hermes installation on this Mac (`~/.hermes`): its profiles and the API server key each one
/// has in its `.env`. Read only; Nibble never writes there.
///
/// With Hermes on the same Mac, the reader does not have to copy keys around: the key of the
/// chosen profile is read from Hermes's own file.
public struct HermesDirectory: Sendable {
    public let home: URL

    public init(home: URL = FileManager.default.homeDirectoryForCurrentUser.appending(path: ".hermes", directoryHint: .isDirectory)) {
        self.home = home
    }

    public var exists: Bool {
        FileManager.default.fileExists(atPath: home.appending(path: "config.yaml").path(percentEncoded: false))
    }

    /// "default" first, then the other profiles by name.
    public func profiles() -> [String] {
        guard exists else { return [] }
        let folder = home.appending(path: "profiles", directoryHint: .isDirectory)
        let names = (try? FileManager.default.contentsOfDirectory(atPath: folder.path(percentEncoded: false))) ?? []
        let others = names.filter { name in
            !name.hasPrefix(".")
                && FileManager.default.fileExists(atPath: folder.appending(path: "\(name)/config.yaml").path(percentEncoded: false))
        }
        return ["default"] + others.sorted()
    }

    /// The profile's `API_SERVER_KEY`, if it has one.
    public func apiKey(for profile: String) -> String? {
        let folder = profile == "default" ? home : home.appending(path: "profiles/\(profile)", directoryHint: .isDirectory)
        guard let text = try? String(contentsOf: folder.appending(path: ".env"), encoding: .utf8) else { return nil }
        return Self.value(of: "API_SERVER_KEY", in: text)
    }

    /// A variable's value in a dotenv file: `KEY=value`, optionally `export`ed and quoted.
    static func value(of key: String, in text: String) -> String? {
        for raw in text.split(whereSeparator: \.isNewline) {
            var line = raw.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("#") { continue }
            if line.hasPrefix("export ") { line = String(line.dropFirst(7)).trimmingCharacters(in: .whitespaces) }
            guard let equals = line.firstIndex(of: "="),
                  line[..<equals].trimmingCharacters(in: .whitespaces) == key
            else { continue }
            var value = line[line.index(after: equals)...].trimmingCharacters(in: .whitespaces)
            if let quote = value.first, quote == "\"" || quote == "'", value.count >= 2, value.last == quote {
                value = String(value.dropFirst().dropLast())
            } else if let hash = value.range(of: " #") {
                value = String(value[..<hash.lowerBound]).trimmingCharacters(in: .whitespaces)
            }
            return value.isEmpty ? nil : value
        }
        return nil
    }
}
