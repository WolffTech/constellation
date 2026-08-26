// SPDX-FileCopyrightText: 2026 Nick Wolff <nick@wolff.tech>
// SPDX-License-Identifier: GPL-3.0-only

import ConstellationCore
import Foundation
import Observation

/// The app's view of the Machine Library: one snapshot, reloaded after every
/// save. Secrets go to the vault; only their references live in the snapshot.
@MainActor
@Observable
final class MachineStore {
    private(set) var snapshot: MachineLibrarySnapshot = .empty
    private(set) var loadError: String?
    var presentedError: String?

    let library: any MachineLibrary
    let vault: any CredentialVault

    init(library: any MachineLibrary, vault: any CredentialVault) {
        self.library = library
        self.vault = vault
    }

    func reload() async {
        do {
            snapshot = try await library.snapshot()
            loadError = nil
        } catch {
            loadError = error.localizedDescription
        }
    }

    /// Applies a change and reloads. Errors surface through `presentedError`.
    @discardableResult
    func save(_ change: MachineLibraryChange) async -> Bool {
        do {
            try await library.save(change)
            await reload()
            return true
        } catch {
            presentedError = error.localizedDescription
            return false
        }
    }

    /// Saves an editor draft: library change first, then vault writes, so a
    /// rejected draft leaves no stray Keychain items.
    func save(_ draft: MachineDraft) async -> Bool {
        let change: MachineLibraryChange
        do {
            change = try draft.change()
        } catch {
            presentedError = error.localizedDescription
            return false
        }
        guard await save(change) else { return false }
        do {
            for pending in draft.pendingSecrets {
                try vault.store(pending.secret, for: pending.credentialID)
            }
            for id in draft.removedCredentialIDs where snapshot.credential(id) == nil {
                try vault.remove(id: id)
            }
        } catch {
            presentedError = error.localizedDescription
            return false
        }
        return true
    }

    /// Deletes the machine and returns credentials that no remaining profile
    /// uses, so the caller can confirm removing them from the Keychain.
    func deleteMachine(_ id: MachineID) async -> [CredentialReference] {
        guard await save(.deleteMachine(id)) else { return [] }
        return snapshot.orphanedCredentials
    }

    func removeCredentials(_ credentials: [CredentialReference]) async {
        guard await save(.batch(credentials.map { .deleteCredential($0.id) })) else { return }
        for credential in credentials {
            try? vault.remove(id: credential.id)
        }
    }

    func exportData() throws -> Data {
        try MachineExport.encode(MachineExport.document(from: snapshot))
    }

    func importData(_ data: Data) async {
        do {
            let document = try MachineExport.decode(data)
            await save(MachineExport.importChange(for: document))
        } catch {
            presentedError = error.localizedDescription
        }
    }
}
