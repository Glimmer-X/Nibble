import Foundation

/// Where secrets are kept (the Keychain in the app, memory in tests).
public protocol SecretStore: Sendable {
    func secret(for account: String) -> String?
    func setSecret(_ value: String?, for account: String) throws
}
