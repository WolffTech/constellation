import ConstellationCore
import Testing
@testable import ConstellationStorage

/// Talks to the real login keychain under a test-only service name.
struct KeychainCredentialVaultTests {
    private let vault = KeychainCredentialVault(service: "tech.wolff.Constellation.tests")

    @Test func storesUpdatesAndRemoves() throws {
        let id = CredentialID()
        defer { try? vault.remove(id: id) }

        #expect(!vault.contains(id: id))
        #expect(throws: CredentialVaultError.notFound(id)) { try vault.retrieve(id: id) }

        try vault.store(Secret("first"), for: id)
        #expect(vault.contains(id: id))
        #expect(try vault.retrieve(id: id).withValue { $0 } == "first")

        try vault.store(Secret("second"), for: id)
        #expect(try vault.retrieve(id: id).withValue { $0 } == "second")

        try vault.remove(id: id)
        #expect(!vault.contains(id: id))
        try vault.remove(id: id)
    }
}
