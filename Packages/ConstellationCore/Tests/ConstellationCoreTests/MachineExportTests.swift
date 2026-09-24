// SPDX-FileCopyrightText: 2026 Nick Wolff <nick@wolff.tech>
// SPDX-License-Identifier: GPL-3.0-only

import Foundation
import Testing
@testable import ConstellationCore

struct MachineExportTests {
    private func sampleSnapshot() -> (MachineLibrarySnapshot, CredentialID) {
        let machine = Machine(name: "alpha", notes: "temp box", tags: ["homelab"], isFavorite: true)
        let credential = CredentialReference(label: "temp password", kind: .password)
        let address = MachineAddress(machineID: machine.id, label: "LAN", host: "192.0.2.18", kind: .lan, priority: 0)
        let profile = SSHProfile(machineID: machine.id, name: "SSH", username: "temp", authentication: .password, credentialID: credential.id)
        let snapshot = MachineLibrarySnapshot(machines: [machine], addresses: [address], profiles: [.ssh(profile)], credentials: [credential])
        return (snapshot, credential.id)
    }

    @Test func exportCarriesNoCredentialIDs() throws {
        let (snapshot, credentialID) = sampleSnapshot()
        let data = try MachineExport.encode(MachineExport.document(from: snapshot))
        let json = String(decoding: data, as: UTF8.self)
        #expect(!json.contains(credentialID.description))
        #expect(!json.contains("credentialID"))
        #expect(!json.contains("credentials"))
        #expect(json.contains("192.0.2.18"))
    }

    @Test func exportDropsTheGatewayCredentialButKeepsTheGateway() throws {
        let machine = Machine(name: "win")
        let credential = CredentialReference(label: "gateway", kind: .password)
        let gateway = RDPGateway(host: "gw.example.com", credentials: .separate(username: "dmz-nick", domain: "DMZ", credentialID: credential.id))
        let profile = ConnectionProfile.rdp(RDPProfile(machineID: machine.id, gateway: gateway))
        #expect(profile.credentialIDs == [credential.id])

        guard case .rdp(let exported) = profile.withoutCredential() else {
            Issue.record("expected an RDP profile")
            return
        }
        #expect(exported.gateway == RDPGateway(host: "gw.example.com", credentials: .separate(username: "dmz-nick", domain: "DMZ", credentialID: nil)))
    }

    @Test func rdpProfilesSavedBeforeGatewaysStillDecode() throws {
        let profile = RDPProfile(machineID: MachineID(), username: "nick")
        var json = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(profile)) as? [String: Any])
        json["gateway"] = nil
        let decoded = try JSONDecoder().decode(RDPProfile.self, from: JSONSerialization.data(withJSONObject: json))
        #expect(decoded == profile)
    }

    @Test func importRoundTripsDefinitions() throws {
        let (snapshot, _) = sampleSnapshot()
        let data = try MachineExport.encode(MachineExport.document(from: snapshot))
        let document = try MachineExport.decode(data)
        #expect(document.machines == snapshot.machines)
        #expect(document.addresses == snapshot.addresses)
        #expect(document.profiles.map(\.id) == snapshot.profiles.map(\.id))
        #expect(document.profiles.allSatisfy { $0.credentialID == nil })
        guard case .batch(let changes) = MachineExport.importChange(for: document) else {
            Issue.record("expected a batch")
            return
        }
        #expect(changes.count == 3)
    }

    @Test func reimportKeepsSavedCredentials() throws {
        let machine = Machine(name: "win")
        let password = CredentialReference(label: "desktop", kind: .password)
        let gatewayPassword = CredentialReference(label: "gateway", kind: .password)
        let gateway = RDPGateway(host: "gw.example.com", credentials: .separate(username: "dmz-nick", domain: "DMZ", credentialID: gatewayPassword.id))
        let rdp = ConnectionProfile.rdp(RDPProfile(machineID: machine.id, username: "nick", credentialID: password.id, gateway: gateway))
        let (sshSnapshot, sshPassword) = sampleSnapshot()
        let snapshot = MachineLibrarySnapshot(
            machines: sshSnapshot.machines + [machine],
            addresses: sshSnapshot.addresses,
            profiles: sshSnapshot.profiles + [rdp],
            credentials: sshSnapshot.credentials + [password, gatewayPassword])
        let document = try MachineExport.decode(try MachineExport.encode(MachineExport.document(from: snapshot)))

        guard case .batch(let changes) = MachineExport.importChange(for: document, into: snapshot) else {
            Issue.record("expected a batch")
            return
        }
        let profiles = changes.compactMap { if case .upsertProfile(let p) = $0 { p } else { nil } }
        #expect(Set(profiles) == Set(snapshot.profiles))
        #expect(Set(profiles.flatMap(\.credentialIDs)) == [sshPassword, password.id, gatewayPassword.id])
    }

    @Test func reimportDropsCredentialsThatNoLongerFit() {
        let machineID = MachineID()
        let passphrase = CredentialID()
        let saved = ConnectionProfile.ssh(SSHProfile(machineID: machineID, authentication: .keyFile(path: "~/.ssh/old"), credentialID: passphrase))
        guard case .ssh(var ssh) = saved else { return }
        ssh.authentication = .keyFile(path: "~/.ssh/new")
        #expect(ConnectionProfile.ssh(ssh).withoutCredential().keepingCredentials(of: saved).credentialIDs.isEmpty)

        let gatewayPassword = CredentialID()
        let rdp = RDPProfile(
            machineID: machineID,
            gateway: RDPGateway(host: "gw.example.com", credentials: .separate(username: nil, domain: nil, credentialID: gatewayPassword)))
        var shared = rdp
        shared.gateway?.credentials = .sameAsDesktop
        #expect(ConnectionProfile.rdp(shared).keepingCredentials(of: .rdp(rdp)).credentialIDs.isEmpty)
    }

    @Test func exportCarriesGroupsAndOrder() throws {
        let lab = MachineGroup(name: "Lab", position: 1)
        let work = MachineGroup(name: "Work", position: 0)
        let machines = [Machine(name: "b", groupID: work.id), Machine(name: "a", groupID: lab.id, position: 1), Machine(name: "c", groupID: lab.id)]
        let snapshot = MachineLibrarySnapshot(machines: machines, groups: [lab, work])
        let document = try MachineExport.decode(try MachineExport.encode(MachineExport.document(from: snapshot)))
        #expect(document.version == 2)
        #expect(document.groups == [work, lab])
        #expect(document.machines == machines)
    }

    @Test func importMergesGroupsByNameAndAppendsTheRest() throws {
        let theirLab = MachineGroup(name: "lab", position: 0)
        let theirNew = MachineGroup(name: "New", position: 1)
        let missing = GroupID()
        let document = MachineExportDocument(
            machines: [
                Machine(name: "second", groupID: theirLab.id, position: 1),
                Machine(name: "first", groupID: theirLab.id, position: 0),
                Machine(name: "orphan", groupID: missing),
                Machine(name: "fresh", groupID: theirNew.id),
            ],
            groups: [theirNew, theirLab], addresses: [], profiles: [])
        let myLab = MachineGroup(name: "Lab")
        let target = MachineLibrarySnapshot(groups: [myLab])

        guard case .batch(let changes) = MachineExport.importChange(for: document, into: target) else {
            Issue.record("expected a batch")
            return
        }
        let groups = changes.compactMap { if case .upsertGroup(let g) = $0 { g } else { nil } }
        #expect(groups == [theirNew])
        let machines = changes.compactMap { if case .upsertMachine(let m) = $0 { m } else { nil } }
        // Position order, so the library appends each group's machines as the document had them.
        #expect(machines.map(\.name) == ["first", "fresh", "orphan", "second"])
        #expect(machines.map(\.groupID) == [myLab.id, theirNew.id, nil, myLab.id])
    }

    /// Builds that predate gateways must refuse these libraries by version
    /// rather than drop the gateway or fail to decode it.
    @Test func gatewaysNeedVersionThreeAndRoundTrip() throws {
        let machine = Machine(name: "avd")
        let resource = AVDResource(tenantID: "tenant", loadBalanceInfo: "lb", application: "desktop", desktopSignIn: .passwordInsteadOfEntraID)
        let gateway = RDPGateway(host: "rdgateway.wvd.microsoft.com", credentials: .azureVirtualDesktop(resource))
        let profile = ConnectionProfile.rdp(RDPProfile(machineID: machine.id, gateway: gateway))
        let snapshot = MachineLibrarySnapshot(machines: [machine], profiles: [profile])

        let document = try MachineExport.decode(try MachineExport.encode(MachineExport.document(from: snapshot)))
        #expect(document.version == 3)
        #expect(document.profiles == [profile])
    }

    @Test func decodesVersionOneDocuments() throws {
        let json = """
        {"version":1,"machines":[{"id":"\(MachineID())","name":"old","notes":"","tags":[],"isFavorite":false}],"addresses":[],"profiles":[]}
        """
        let document = try MachineExport.decode(Data(json.utf8))
        #expect(document.groups.isEmpty)
        #expect(document.machines.first?.groupID == nil)
    }

    @Test func rejectsNewerFormats() throws {
        let (snapshot, _) = sampleSnapshot()
        var document = MachineExport.document(from: snapshot)
        document.version = 99
        let data = try MachineExport.encode(document)
        #expect(throws: MachineExportError.unsupportedVersion(99)) { try MachineExport.decode(data) }
    }
}

struct SecretTests {
    @Test func printedFormsAreRedacted() {
        let secret = Secret("hunter2")
        #expect("\(secret)" == "Secret(••••)")
        #expect(String(reflecting: secret) == "Secret(••••)")
        #expect(!String(describing: [secret]).contains("hunter2"))
        #expect(secret.withValue { $0 } == "hunter2")
    }
}
