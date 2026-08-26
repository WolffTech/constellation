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
}
