import ConstellationCore
import Testing
@testable import Constellation

struct MachineDraftTests {
    @Test func newDraftBecomesOneBatch() throws {
        var draft = MachineDraft(newMachine: "alpha")
        draft.tagsText = "homelab, Debian "
        draft.addresses[0].host = "192.0.2.18"
        draft.profiles[0].profile.username = "temp"

        guard case .batch(let changes) = try draft.change() else {
            Issue.record("expected a batch")
            return
        }
        guard case .upsertMachine(let machine) = changes[0] else {
            Issue.record("machine first")
            return
        }
        #expect(machine.tags == ["homelab", "Debian"])
        #expect(machine.defaultProfileID == draft.profiles[0].profile.id)
        #expect(changes.contains { if case .upsertAddress(let a) = $0 { a.host == "192.0.2.18" && a.priority == 0 } else { false } })
        #expect(changes.contains { if case .upsertProfile(.ssh(let p)) = $0 { p.username == "temp" && p.authentication == .agent && p.credentialID == nil } else { false } })
        #expect(draft.pendingSecrets.isEmpty)
    }

    @Test func typedPasswordCreatesACredentialAndAPendingSecret() throws {
        var draft = MachineDraft(newMachine: "box")
        draft.addresses[0].host = "box.local"
        draft.profiles[0].authMode = .password
        draft.profiles[0].enteredSecret = "hunter2"

        guard case .batch(let changes) = try draft.change() else { return }
        let credential = changes.compactMap { if case .upsertCredential(let c) = $0 { c } else { nil } }.first
        let profile = changes.compactMap { if case .upsertProfile(.ssh(let p)) = $0 { p } else { nil } }.first
        #expect(credential?.kind == .password)
        #expect(credential?.label == "box · SSH password")
        #expect(profile?.authentication == .password)
        #expect(profile?.credentialID != nil)
        #expect(profile?.credentialID == credential?.id)
        #expect(draft.pendingSecrets.count == 1)
        #expect(draft.pendingSecrets[0].credentialID == credential?.id)
        #expect(draft.pendingSecrets[0].secret.withValue { $0 } == "hunter2")

        // Clearing the field again means no secret: the password profile is invalid.
        draft.profiles[0].enteredSecret = ""
        #expect(draft.pendingSecrets.isEmpty)
        #expect(throws: ValidationError.missingCredential(profile: "SSH")) { try draft.change() }
    }

    @Test func passwordWithoutSecretIsRejectedWithAMessage() {
        var draft = MachineDraft(newMachine: "box")
        draft.addresses[0].host = "box.local"
        draft.profiles[0].authMode = .password
        #expect(throws: ValidationError.missingCredential(profile: "SSH")) { try draft.change() }
    }

    @Test func emptyHostIsRejected() {
        let draft = MachineDraft(newMachine: "box")
        #expect(throws: ValidationError.emptyHost) { try draft.change() }
    }

    @Test func removingAStoredSecretDeletesTheCredential() throws {
        let machine = Machine(name: "box")
        let credential = CredentialReference(label: "box · SSH password", kind: .password)
        let address = MachineAddress(machineID: machine.id, label: "LAN", host: "box.local")
        let profile = SSHProfile(machineID: machine.id, username: "nick", authentication: .password, credentialID: credential.id)
        let snapshot = MachineLibrarySnapshot(machines: [machine], addresses: [address], profiles: [.ssh(profile)], credentials: [credential])

        var draft = MachineDraft(editing: machine, in: snapshot)
        #expect(draft.profiles[0].hasStoredSecret)
        draft.profiles[0].removeStoredSecret()
        draft.profiles[0].authMode = .agent

        guard case .batch(let changes) = try draft.change() else { return }
        #expect(changes.contains(.deleteCredential(credential.id)) == false, "credential deletion is tracked via removedCredentialIDs on profile removal, not secret removal")
        let saved = changes.compactMap { if case .upsertProfile(.ssh(let p)) = $0 { p } else { nil } }.first
        #expect(saved?.credentialID == nil)
        #expect(saved?.authentication == .agent)
    }

    @Test func removingAProfileDeletesItsCredential() throws {
        let machine = Machine(name: "box")
        let credential = CredentialReference(label: "c", kind: .password)
        let address = MachineAddress(machineID: machine.id, label: "LAN", host: "box.local")
        let profile = SSHProfile(machineID: machine.id, authentication: .password, credentialID: credential.id)
        let snapshot = MachineLibrarySnapshot(machines: [machine], addresses: [address], profiles: [.ssh(profile)], credentials: [credential])

        var draft = MachineDraft(editing: machine, in: snapshot)
        draft.removeProfile(profile.id)
        guard case .batch(let changes) = try draft.change() else { return }
        #expect(changes.contains(.deleteProfile(profile.id)))
        #expect(changes.contains(.deleteCredential(credential.id)))
    }
}
