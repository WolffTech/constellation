import ConstellationCore
import Foundation
import Security

/// Stores secrets as generic-password items keyed by credential id. Uses the
/// login keychain; moving to the data-protection keychain with an access
/// group is a Milestone 5 signing decision.
public struct KeychainCredentialVault: CredentialVault, Sendable {
    public let service: String

    public init(service: String = "tech.wolff.Constellation") {
        self.service = service
    }

    public func store(_ secret: Secret, for id: CredentialID) throws {
        let data = secret.withValue { Data($0.utf8) }
        let update = SecItemUpdate(query(for: id) as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if update == errSecSuccess { return }
        guard update == errSecItemNotFound else {
            throw CredentialVaultError.keychain(status: update, operation: "update")
        }
        var attributes = query(for: id)
        attributes[kSecValueData as String] = data
        attributes[kSecAttrLabel as String] = "Constellation credential"
        let add = SecItemAdd(attributes as CFDictionary, nil)
        guard add == errSecSuccess else {
            throw CredentialVaultError.keychain(status: add, operation: "add")
        }
    }

    public func retrieve(id: CredentialID) throws -> Secret {
        var query = query(for: id)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        switch status {
        case errSecSuccess:
            guard let data = result as? Data, let value = String(data: data, encoding: .utf8) else {
                throw CredentialVaultError.keychain(status: errSecDecode, operation: "decode")
            }
            return Secret(value)
        case errSecItemNotFound:
            throw CredentialVaultError.notFound(id)
        default:
            throw CredentialVaultError.keychain(status: status, operation: "read")
        }
    }

    public func remove(id: CredentialID) throws {
        let status = SecItemDelete(query(for: id) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw CredentialVaultError.keychain(status: status, operation: "delete")
        }
    }

    public func contains(id: CredentialID) -> Bool {
        var query = query(for: id)
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        return SecItemCopyMatching(query as CFDictionary, nil) == errSecSuccess
    }

    private func query(for id: CredentialID) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: id.description,
        ]
    }
}
