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

    /// Saves an editor draft. Secrets are written before the library refers to
    /// them, and put back as they were if the vault or the library fails, so a
    /// profile is never saved without the password it was given and a rejected
    /// draft leaves no stray Keychain items. Secrets the draft dropped are
    /// removed only once the library no longer refers to them.
    func save(_ draft: MachineDraft) async -> Bool {
        let change: MachineLibraryChange
        do {
            change = try draft.change()
        } catch {
            presentedError = error.localizedDescription
            return false
        }
        var replaced: [(id: CredentialID, previous: Secret?)] = []
        do {
            for pending in draft.pendingSecrets {
                let previous = try existingSecret(pending.credentialID)
                try vault.store(pending.secret, for: pending.credentialID)
                replaced.append((pending.credentialID, previous))
            }
        } catch {
            presentedError = error.localizedDescription + restoreNote(restore(replaced))
            return false
        }
        let before = snapshot
        guard await save(change) else {
            presentedError = (presentedError ?? "") + restoreNote(restore(replaced))
            return false
        }
        var kept: [CredentialReference] = []
        var failure: (any Error)?
        for id in draft.removedCredentialIDs where snapshot.credential(id) == nil {
            do {
                try vault.remove(id: id)
            } catch {
                failure = failure ?? error
                if let reference = before.credential(id) { kept.append(reference) }
            }
        }
        if let failure {
            // Restoring the reference leaves it orphaned, so it is offered for
            // removal again rather than lingering unseen in the Keychain.
            if !kept.isEmpty { await save(.batch(kept.map { .upsertCredential($0) })) }
            presentedError = "The machine was saved, but a password it no longer uses couldn’t be removed from the Keychain. \(failure.localizedDescription)"
        }
        return true
    }

    /// `nil` when the vault has nothing for `id`; any other failure throws so a
    /// rollback never deletes a secret it could not read.
    private func existingSecret(_ id: CredentialID) throws -> Secret? {
        do {
            return try vault.retrieve(id: id)
        } catch CredentialVaultError.notFound {
            return nil
        }
    }

    /// Puts back what `save(_ draft:)` replaced, newest first. Returns whether
    /// every secret was restored.
    private func restore(_ replaced: [(id: CredentialID, previous: Secret?)]) -> Bool {
        var restored = true
        for (id, previous) in replaced.reversed() {
            do {
                if let previous { try vault.store(previous, for: id) } else { try vault.remove(id: id) }
            } catch {
                restored = false
            }
        }
        return restored
    }

    private func restoreNote(_ restored: Bool) -> String {
        restored ? "" : " The Keychain could not be returned to its previous state; re-enter the passwords for this machine."
    }

    /// Deletes the machine and returns credentials that no remaining profile
    /// uses, so the caller can confirm removing them from the Keychain.
    func deleteMachine(_ id: MachineID) async -> [CredentialReference] {
        guard await save(.deleteMachine(id)) else { return [] }
        return snapshot.orphanedCredentials
    }

    /// Removes secrets from the vault first and drops the library's reference
    /// only to those that are gone, so one the Keychain refused stays orphaned
    /// and is offered for removal again.
    func removeCredentials(_ credentials: [CredentialReference]) async {
        var removed: [CredentialID] = []
        var failure: (any Error)?
        for credential in credentials {
            do {
                try vault.remove(id: credential.id)
                removed.append(credential.id)
            } catch {
                failure = failure ?? error
            }
        }
        if !removed.isEmpty {
            guard await save(.batch(removed.map { .deleteCredential($0) })) else { return }
        }
        if let failure {
            presentedError = "Some passwords couldn’t be removed from the Keychain. \(failure.localizedDescription)"
        }
    }

    func exportData() throws -> Data {
        try MachineExport.encode(MachineExport.document(from: snapshot))
    }

    func importData(_ data: Data) async {
        do {
            let document = try MachineExport.decode(data)
            await save(MachineExport.importChange(for: document, into: snapshot))
        } catch {
            presentedError = error.localizedDescription
        }
    }
}
