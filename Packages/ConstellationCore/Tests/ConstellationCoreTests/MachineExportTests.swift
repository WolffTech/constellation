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
