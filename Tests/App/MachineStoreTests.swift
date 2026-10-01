// SPDX-FileCopyrightText: 2026 Nick Wolff <nick@wolff.tech>
// SPDX-License-Identifier: GPL-3.0-only

import ConstellationCore
import ConstellationStorage
import Foundation
import Testing
@testable import Constellation

@MainActor
struct MachineStoreTests {
    @Test func savingADraftWritesLibraryThenVault() async throws {
        let vault = InMemoryCredentialVault()
        let store = MachineStore(library: try GRDBMachineLibrary.inMemory(), vault: vault)

        var draft = MachineDraft(newMachine: "alpha")
        draft.addresses[0].host = "192.0.2.18"
        draft.profiles[0].profile.username = "temp"
        draft.profiles[0].authMode = .password
        draft.profiles[0].enteredSecret = "maymaymay"

        #expect(await store.save(draft))
        let machine = try #require(store.snapshot.machines.first)
        let profile = try #require(store.snapshot.profiles(for: machine.id).first)
        let credentialID = try #require(profile.credentialID)
        #expect(vault.contains(id: credentialID))
        #expect(try vault.retrieve(id: credentialID).withValue { $0 } == "maymaymay")
        #expect(store.snapshot.credential(credentialID)?.kind == .password)

        // Re-editing without touching the secret keeps it.
        var edit = MachineDraft(editing: machine, in: store.snapshot)
        edit.machine.notes = "temp box"
        #expect(await store.save(edit))
        #expect(vault.contains(id: credentialID))
        #expect(store.snapshot.machine(machine.id)?.notes == "temp box")

        // Deleting the machine leaves the credential for the user to confirm.
        let orphans = await store.deleteMachine(machine.id)
        #expect(orphans.map(\.id) == [credentialID])
        #expect(vault.contains(id: credentialID))
        await store.removeCredentials(orphans)
        #expect(!vault.contains(id: credentialID))
        #expect(store.snapshot == .empty)
    }

    @Test func invalidDraftsSurfaceAMessageAndWriteNothing() async throws {
        let vault = InMemoryCredentialVault()
        let store = MachineStore(library: try GRDBMachineLibrary.inMemory(), vault: vault)
        var draft = MachineDraft(newMachine: "bad")
        draft.addresses[0].host = "not a host"
        draft.profiles[0].authMode = .password
        draft.profiles[0].enteredSecret = "x"
        #expect(await store.save(draft) == false)
        #expect(store.presentedError?.contains("not a valid hostname") == true)
        #expect(store.snapshot == .empty)
        #expect(draft.pendingSecrets.allSatisfy { !vault.contains(id: $0.credentialID) })
    }

    @Test func keychainFailureLeavesTheLibraryUntouched() async throws {
        let vault = ScriptedVault()
        vault.failsStore = true
        let store = MachineStore(library: try GRDBMachineLibrary.inMemory(), vault: vault)
        #expect(await store.save(passwordDraft("maymaymay")) == false)
        #expect(store.presentedError != nil)
        #expect(store.snapshot == .empty)
    }

    @Test func rejectedLibraryChangeRestoresTheOldPassword() async throws {
        let vault = ScriptedVault()
        let library = ScriptedLibrary(try GRDBMachineLibrary.inMemory())
        let store = MachineStore(library: library, vault: vault)
        #expect(await store.save(passwordDraft("old")))
        let machine = try #require(store.snapshot.machines.first)
        let credentialID = try #require(store.snapshot.profiles(for: machine.id).first?.credentialID)

        var edit = MachineDraft(editing: machine, in: store.snapshot)
        edit.profiles[0].enteredSecret = "new"
        library.failsSave = true
        #expect(await store.save(edit) == false)
        #expect(try vault.retrieve(id: credentialID).withValue { $0 } == "old")

        // A new profile's secret is removed instead.
        var draft = passwordDraft("fresh")
        let freshID = try #require(draft.pendingSecrets.first?.credentialID)
        #expect(await store.save(draft) == false)
        #expect(!vault.contains(id: freshID))
    }

    @Test func refusedKeychainRemovalKeepsTheCredentialOffered() async throws {
        let vault = ScriptedVault()
        let store = MachineStore(library: try GRDBMachineLibrary.inMemory(), vault: vault)
        #expect(await store.save(passwordDraft("maymaymay")))
        let machine = try #require(store.snapshot.machines.first)
        let orphans = await store.deleteMachine(machine.id)
        let credentialID = try #require(orphans.first?.id)

        vault.failsRemove = true
        await store.removeCredentials(orphans)
        #expect(store.presentedError != nil)
        #expect(vault.contains(id: credentialID))
        #expect(store.snapshot.orphanedCredentials.map(\.id) == [credentialID])

        vault.failsRemove = false
        store.presentedError = nil
        await store.removeCredentials(store.snapshot.orphanedCredentials)
        #expect(store.presentedError == nil)
        #expect(!vault.contains(id: credentialID))
        #expect(store.snapshot.credentials.isEmpty)
    }

    @Test func refusedRemovalOfADroppedPasswordKeepsItOrphaned() async throws {
        let vault = ScriptedVault()
        let store = MachineStore(library: try GRDBMachineLibrary.inMemory(), vault: vault)
        var draft = passwordDraft("maymaymay")
        draft.addVNCProfile()
        #expect(await store.save(draft))
        let machine = try #require(store.snapshot.machines.first)
        let credentialID = try #require(draft.pendingSecrets.first?.credentialID)

        var edit = MachineDraft(editing: machine, in: store.snapshot)
        edit.removeProfile(edit.profiles[0].id)
        vault.failsRemove = true
        #expect(await store.save(edit), "the library change itself succeeded")
        #expect(store.presentedError != nil)
        #expect(store.snapshot.orphanedCredentials.map(\.id) == [credentialID])
    }

    private func passwordDraft(_ secret: String) -> MachineDraft {
        var draft = MachineDraft(newMachine: "alpha")
        draft.addresses[0].host = "192.0.2.18"
        draft.profiles[0].profile.username = "temp"
        draft.profiles[0].authMode = .password
        draft.profiles[0].enteredSecret = secret
        return draft
    }
}

/// An in-memory vault whose writes and deletes can be made to fail like a
/// locked or denied Keychain.
private final class ScriptedVault: CredentialVault, @unchecked Sendable {
    private let inner = InMemoryCredentialVault()
    var failsStore = false
    var failsRemove = false

    func store(_ secret: Secret, for id: CredentialID) throws {
        if failsStore { throw CredentialVaultError.keychain(status: -25308, operation: "add") }
        try inner.store(secret, for: id)
    }

    func retrieve(id: CredentialID) throws -> Secret { try inner.retrieve(id: id) }

    func remove(id: CredentialID) throws {
        if failsRemove { throw CredentialVaultError.keychain(status: -25308, operation: "delete") }
        try inner.remove(id: id)
    }

    func contains(id: CredentialID) -> Bool { inner.contains(id: id) }
}

private final class ScriptedLibrary: MachineLibrary, @unchecked Sendable {
    struct Refused: Error {}
    private let inner: any MachineLibrary
    var failsSave = false

    init(_ inner: any MachineLibrary) { self.inner = inner }

    func snapshot() async throws -> MachineLibrarySnapshot { try await inner.snapshot() }

    func save(_ change: MachineLibraryChange) async throws {
        if failsSave { throw Refused() }
        try await inner.save(change)
    }
}
