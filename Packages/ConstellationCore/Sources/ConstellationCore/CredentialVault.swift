import Foundation

/// A password or passphrase in memory. Not `Codable`, and its printed form is
/// redacted so logging or interpolating one cannot leak it.
public struct Secret: Sendable, CustomStringConvertible, CustomDebugStringConvertible, CustomReflectable {
    private let value: String

    public init(_ value: String) {
        self.value = value
    }

    public var isEmpty: Bool { value.isEmpty }

    /// Scoped access; keep the returned value short-lived.
    public func withValue<T>(_ body: (String) throws -> T) rethrows -> T {
        try body(value)
    }

    public var description: String { "Secret(••••)" }
    public var debugDescription: String { description }
    public var customMirror: Mirror { Mirror(self, children: []) }
}

/// Keychain in the app, a dictionary in tests. Synchronous because the
/// AskPass message-port callback must answer inline.
public protocol CredentialVault: Sendable {
    func store(_ secret: Secret, for id: CredentialID) throws
    func retrieve(id: CredentialID) throws -> Secret
    func remove(id: CredentialID) throws
    func contains(id: CredentialID) -> Bool
}

public enum CredentialVaultError: Error, Hashable, Sendable, LocalizedError {
    case notFound(CredentialID)
    case keychain(status: Int32, operation: String)

    public var errorDescription: String? {
        switch self {
        case .notFound(let id): "No saved secret for credential \(id)."
        case .keychain(let status, let operation): "Keychain \(operation) failed (\(status))."
        }
    }
}

public final class InMemoryCredentialVault: CredentialVault, @unchecked Sendable {
    private let lock = NSLock()
    private var secrets: [CredentialID: Secret] = [:]

    public init() {}

    public func store(_ secret: Secret, for id: CredentialID) throws {
        lock.withLock { secrets[id] = secret }
    }

    public func retrieve(id: CredentialID) throws -> Secret {
        guard let secret = lock.withLock({ secrets[id] }) else { throw CredentialVaultError.notFound(id) }
        return secret
    }

    public func remove(id: CredentialID) throws {
        lock.withLock { secrets[id] = nil }
    }

    public func contains(id: CredentialID) -> Bool {
        lock.withLock { secrets[id] != nil }
    }
}
