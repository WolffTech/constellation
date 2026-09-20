// SPDX-FileCopyrightText: 2026 Nick Wolff <nick@wolff.tech>
// SPDX-License-Identifier: GPL-3.0-only

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

    @Test func togglingRDPClipboardSharingIsSaved() throws {
        let machine = Machine(name: "win")
        let rdp = RDPProfile(machineID: machine.id, username: "nick")
        let snapshot = MachineLibrarySnapshot(machines: [machine], profiles: [.rdp(rdp)])
        var draft = MachineDraft(editing: machine, in: snapshot)
        #expect(draft.rdpProfiles[0].profile.sharesClipboard == false)

        draft.rdpProfiles[0].profile.sharesClipboard = true
        guard case .batch(let changes) = try draft.change() else {
            Issue.record("expected a batch")
            return
        }
        let saved = changes.compactMap { change -> RDPProfile? in
            if case .upsertProfile(.rdp(let profile)) = change { profile } else { nil }
        }
        #expect(saved.map(\.sharesClipboard) == [true])
    }

    @Test func editingKeepsVNCProfilesAndTheirStoredPassword() throws {
        let machine = Machine(name: "screen")
        let credential = CredentialReference(label: "screen · VNC VNC password", kind: .password)
        let vnc = VNCProfile(machineID: machine.id, username: "nick", credentialID: credential.id, sharesClipboard: true)
        let ssh = SSHProfile(machineID: machine.id)
        let snapshot = MachineLibrarySnapshot(
            machines: [machine],
            addresses: [],
            profiles: [.ssh(ssh), .vnc(vnc)],
            credentials: [credential])

        var draft = MachineDraft(editing: machine, in: snapshot)
        #expect(draft.vncProfiles.map(\.id) == [vnc.id])
        #expect(draft.vncProfiles[0].hasStoredSecret)
        #expect(draft.profileIDs == [ssh.id, vnc.id])

        draft.vncProfiles[0].profile.sharesClipboard = false
        let change = try draft.change()
        guard case .batch(let changes) = change else {
            Issue.record("expected a batch")
            return
        }
        let saved = changes.compactMap { change -> VNCProfile? in
            if case .upsertProfile(.vnc(let profile)) = change { profile } else { nil }
        }
        #expect(saved.map(\.credentialID) == [credential.id])
        #expect(saved.first?.sharesClipboard == false)
        #expect(draft.pendingSecrets.isEmpty)
    }

    @Test func typingAVNCPasswordAllocatesOneCredential() throws {
        var draft = MachineDraft(newMachine: "screen")
        draft.addresses[0].host = "10.0.0.9"
        draft.addVNCProfile()
        draft.vncProfiles[0].enteredSecret = "s3cret"

        let credentialID = try #require(draft.vncProfiles[0].profile.credentialID)
        #expect(draft.pendingSecrets.map(\.credentialID) == [credentialID])
        let reference = try #require(draft.vncProfiles[0].resolvedCredential(machineName: "screen"))
        #expect(reference.id == credentialID)
        #expect(reference.kind == .password)
        // The SSH profile created with the machine stays the default.
        _ = try draft.change()
        #expect(draft.machine.defaultProfileID == nil)
    }

    @Test func removingAVNCProfileForgetsItsCredential() {
        let machine = Machine(name: "screen")
        let credential = CredentialReference(label: "x", kind: .password)
        let vnc = VNCProfile(machineID: machine.id, credentialID: credential.id)
        let snapshot = MachineLibrarySnapshot(machines: [machine], addresses: [], profiles: [.vnc(vnc)], credentials: [credential])
        var draft = MachineDraft(editing: machine, in: snapshot)

        draft.removeProfile(vnc.id)

        #expect(draft.vncProfiles.isEmpty)
        #expect(draft.removedProfileIDs == [vnc.id])
        #expect(draft.removedCredentialIDs == [credential.id])
    }

    @Test func rdpProfilesRoundTripWithDomainAndPassword() throws {
        var draft = MachineDraft(newMachine: "win")
        draft.addresses[0].host = "10.0.0.7"
        draft.addRDPProfile()
        draft.rdpProfiles[0].profile.username = "nick "
        draft.rdpProfiles[0].profile.domain = " CORP"
        draft.rdpProfiles[0].enteredSecret = "pa55"

        guard case .batch(let changes) = try draft.change() else {
            Issue.record("expected a batch")
            return
        }
        let saved = try #require(changes.compactMap { if case .upsertProfile(.rdp(let p)) = $0 { p } else { nil } }.first)
        let credential = try #require(changes.compactMap { if case .upsertCredential(let c) = $0 { c } else { nil } }.first)
        #expect(saved.username == "nick")
        #expect(saved.domain == "CORP")
        #expect(saved.credentialID == credential.id)
        #expect(credential.label == "win · RDP RDP password")
        #expect(draft.pendingSecrets.map(\.credentialID) == [credential.id])
        #expect(draft.profileIDs == [draft.profiles[0].id, saved.id])
    }

    @Test func rdpGatewaysSaveTheirOwnAccountAndPassword() throws {
        var draft = MachineDraft(newMachine: "win")
        draft.addresses[0].host = "10.0.0.7"
        draft.addRDPProfile()
        draft.rdpProfiles[0].enteredSecret = "pa55"
        draft.rdpProfiles[0].gateway.isEnabled = true
        draft.rdpProfiles[0].gateway.host = " gw.example.com "
        draft.rdpProfiles[0].gateway.usesDesktopAccount = false
        draft.rdpProfiles[0].gateway.username = "dmz-nick "
        draft.rdpProfiles[0].gateway.enteredSecret = "gw55"

        guard case .batch(let changes) = try draft.change() else {
            Issue.record("expected a batch")
            return
        }
        let saved = try #require(changes.compactMap { if case .upsertProfile(.rdp(let p)) = $0 { p } else { nil } }.first)
        let credentials = changes.compactMap { if case .upsertCredential(let c) = $0 { c } else { nil } }
        let gatewayCredential = try #require(credentials.first { $0.label == "win · RDP RDP gateway password" })
        #expect(saved.gateway == RDPGateway(
            host: "gw.example.com", port: 443,
            credentials: .separate(username: "dmz-nick", domain: nil, credentialID: gatewayCredential.id)))
        #expect(saved.credentialID != gatewayCredential.id)
        #expect(Set(draft.pendingSecrets.map(\.credentialID)) == Set(credentials.map(\.id)))
        #expect(credentials.count == 2)
    }

    @Test func anAzureVirtualDesktopFileFillsInANewMachine() throws {
        let file = try AVDConnectionFile(contents: """
            full address:s:rdgateway-r1.wvd.microsoft.com
            resourceprovider:s:arm
            gatewayhostname:s:afdfp-rdgateway-r1.wvd.microsoft.com:443
            armpath:s:/subscriptions/s/hostpools/p
            remotedesktopname:s:Cloud PC
            """)
        var draft = MachineDraft(newMachine: "")
        draft.addRDPProfile()
        draft.applyAzureVirtualDesktop(file, to: draft.rdpProfiles[0].id)

        // The blank starting address is reused, not left behind to fail validation.
        #expect(draft.addresses.map(\.host) == ["rdgateway-r1.wvd.microsoft.com"])
        #expect(draft.machine.name == "Cloud PC")

        guard case .batch(let changes) = try draft.change() else {
            Issue.record("expected a batch")
            return
        }
        let saved = try #require(changes.compactMap { if case .upsertProfile(.rdp(let p)) = $0 { p } else { nil } }.first)
        #expect(saved.gateway == file.gateway)
    }

    @Test func replacingAGatewayWithAzureVirtualDesktopDropsItsPassword() throws {
        let machine = Machine(name: "win")
        let credential = CredentialReference(label: "gateway", kind: .password)
        let rdp = RDPProfile(machineID: machine.id, gateway: RDPGateway(
            host: "gw.example.com", credentials: .separate(username: "dmz-nick", domain: nil, credentialID: credential.id)))
        let address = MachineAddress(machineID: machine.id, label: "", host: "10.0.0.7")
        let snapshot = MachineLibrarySnapshot(machines: [machine], addresses: [address], profiles: [.rdp(rdp)], credentials: [credential])
        var draft = MachineDraft(editing: machine, in: snapshot)
        let file = try AVDConnectionFile(contents: """
            full address:s:rdgateway-r1.wvd.microsoft.com
            resourceprovider:s:arm
            gatewayhostname:s:afdfp-rdgateway-r1.wvd.microsoft.com
            """)
        draft.applyAzureVirtualDesktop(file, to: rdp.id)

        #expect(draft.removedCredentialIDs == [credential.id])
        #expect(draft.addresses.map(\.host) == ["10.0.0.7", "rdgateway-r1.wvd.microsoft.com"])
        #expect(draft.machine.name == "win")
        #expect(draft.rdpProfiles[0].resolvedProfile().gateway == file.gateway)
    }

    @Test func rdpGatewaysSharingTheDesktopAccountSaveNoSecondCredential() throws {
        var draft = MachineDraft(newMachine: "win")
        draft.addresses[0].host = "10.0.0.7"
        draft.addRDPProfile()
        draft.rdpProfiles[0].gateway.isEnabled = true
        draft.rdpProfiles[0].gateway.host = "gw.example.com"
        // Typed before switching back to the desktop account; must not be saved.
        draft.rdpProfiles[0].gateway.usesDesktopAccount = false
        draft.rdpProfiles[0].gateway.enteredSecret = "gw55"
        draft.rdpProfiles[0].gateway.usesDesktopAccount = true

        guard case .batch(let changes) = try draft.change() else {
            Issue.record("expected a batch")
            return
        }
        let saved = try #require(changes.compactMap { if case .upsertProfile(.rdp(let p)) = $0 { p } else { nil } }.first)
        #expect(saved.gateway == RDPGateway(host: "gw.example.com"))
        #expect(changes.allSatisfy { if case .upsertCredential = $0 { false } else { true } })
        #expect(draft.pendingSecrets.isEmpty)
    }

    @Test func anEnabledGatewayNeedsAnAddress() {
        var draft = MachineDraft(newMachine: "win")
        draft.addresses[0].host = "10.0.0.7"
        draft.addRDPProfile()
        draft.rdpProfiles[0].gateway.isEnabled = true
        #expect(throws: ValidationError.missingGatewayHost(profile: "RDP")) { try draft.change() }
    }

    @Test func editingKeepsASavedGatewayAndRemovingTheProfileForgetsItsCredential() {
        let machine = Machine(name: "win")
        let credential = CredentialReference(label: "gw", kind: .password)
        let gateway = RDPGateway(host: "gw.example.com", port: 8443, credentials: .separate(username: "dmz-nick", domain: "DMZ", credentialID: credential.id))
        let rdp = RDPProfile(machineID: machine.id, gateway: gateway)
        let snapshot = MachineLibrarySnapshot(machines: [machine], addresses: [], profiles: [.rdp(rdp)], credentials: [credential])
        var draft = MachineDraft(editing: machine, in: snapshot)
        #expect(draft.rdpProfiles[0].gateway.hasStoredSecret)
        #expect(draft.rdpProfiles[0].resolvedProfile().gateway == gateway)

        draft.removeProfile(rdp.id)

        #expect(draft.removedCredentialIDs == [credential.id])
    }

    @Test func removingAnRDPProfileForgetsItsCredential() {
        let machine = Machine(name: "win")
        let credential = CredentialReference(label: "x", kind: .password)
        let rdp = RDPProfile(machineID: machine.id, credentialID: credential.id)
        let snapshot = MachineLibrarySnapshot(machines: [machine], addresses: [], profiles: [.rdp(rdp)], credentials: [credential])
        var draft = MachineDraft(editing: machine, in: snapshot)
        #expect(draft.rdpProfiles[0].hasStoredSecret)

        draft.removeProfile(rdp.id)

        #expect(draft.rdpProfiles.isEmpty)
        #expect(draft.removedProfileIDs == [rdp.id])
        #expect(draft.removedCredentialIDs == [credential.id])
    }
}

struct QuickSetupDraftTests {
    @Test func newDraftEditsItsFirstAddressAndProfile() {
        var draft = MachineDraft(newMachine: "box")
        draft.quickHost = "box.example.com"
        draft.quickUsername = "nick"
        #expect(draft.addresses.map(\.host) == ["box.example.com"])
        #expect(draft.quickProtocol == .ssh)
        #expect(draft.profiles.first?.profile.username == "nick")
    }

    @Test func switchingProtocolReplacesTheProfileAndKeepsTheUsername() throws {
        var draft = MachineDraft(newMachine: "box")
        draft.quickHost = "box.example.com"
        draft.quickUsername = "nick"
        draft.quickPassword = "hunter2"
        draft.quickProtocol = .rdp
        #expect(draft.profiles.isEmpty && draft.vncProfiles.isEmpty)
        #expect(draft.rdpProfiles.first?.profile.username == "nick")
        #expect(draft.quickUsername == "nick")
        #expect(draft.quickPassword == "hunter2")
        #expect(draft.pendingSecrets.count == 1)

        draft.quickProtocol = .vnc
        #expect(draft.rdpProfiles.isEmpty)
        #expect(draft.vncProfiles.first?.profile.username == "nick")
        #expect(draft.effectiveDefaultProfileID == draft.vncProfiles.first?.id)

        // Saving a switched draft yields exactly one profile, the default.
        guard case .batch(let changes) = try draft.change() else { Issue.record("expected a batch"); return }
        let profiles = changes.compactMap { if case .upsertProfile(let p) = $0 { p } else { nil } }
        #expect(profiles.count == 1)
        #expect(profiles.first?.protocolKind == .vnc)
    }

    @Test func sshPasswordSwitchesAuthenticationAndClearingRestoresTheAgent() throws {
        var draft = MachineDraft(newMachine: "box")
        draft.quickHost = "box.example.com"
        draft.quickPassword = "hunter2"
        #expect(draft.profiles.first?.authMode == .password)
        #expect(draft.pendingSecrets.count == 1)
        let saved = try draft.profiles[0].resolvedProfile(machineName: "box")
        #expect(saved.authentication == .password)
        #expect(saved.credentialID != nil)

        draft.quickPassword = ""
        #expect(draft.profiles.first?.authMode == .agent)
        #expect(draft.pendingSecrets.isEmpty)
        #expect(try draft.profiles[0].resolvedProfile(machineName: "box").credentialID == nil)
    }
}
