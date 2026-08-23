import ConstellationCore
import Foundation

/// Lets the AskPass service answer password and passphrase prompts from the
/// Credential Vault. Unknown or malformed ids yield `nil`, which sends the
/// prompt to the user instead.
public struct VaultSecretProvider: AskPassSecretProvider {
    private let vault: any CredentialVault

    public init(vault: any CredentialVault) {
        self.vault = vault
    }

    public func secret(for credentialID: String) -> String? {
        guard let id = CredentialID(uuidString: credentialID), let secret = try? vault.retrieve(id: id) else { return nil }
        return secret.withValue { $0 }
    }
}
