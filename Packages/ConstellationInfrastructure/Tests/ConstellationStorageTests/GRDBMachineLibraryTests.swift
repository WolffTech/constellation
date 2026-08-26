// SPDX-FileCopyrightText: 2026 Nick Wolff <nick@wolff.tech>
// SPDX-License-Identifier: GPL-3.0-only

import ConstellationCore
import Foundation
import Testing
@testable import ConstellationStorage

struct GRDBMachineLibraryTests {
    private func seeded() async throws -> (GRDBMachineLibrary, Machine, MachineAddress, CredentialReference, SSHProfile) {
        let library = try GRDBMachineLibrary.inMemory()
        let machine = Machine(name: "alpha", notes: "temp", tags: ["homelab", "debian"], isFavorite: true)
        let address = MachineAddress(machineID: machine.id, label: "LAN", host: "192.0.2.18", kind: .lan, priority: 0)
        let credential = CredentialReference(label: "temp password", kind: .password)
        let profile = SSHProfile(machineID: machine.id, name: "SSH", username: "temp", addressSelection: .pinned(address.id), authentication: .password, credentialID: credential.id)
        try await library.save(.batch([
            .upsertMachine(machine), .upsertAddress(address), .upsertCredential(credential), .upsertProfile(.ssh(profile)),
        ]))
        return (library, machine, address, credential, profile)
    }

    @Test func roundTripsEverything() async throws {
        let (library, machine, address, credential, profile) = try await seeded()
        let snapshot = try await library.snapshot()
        #expect(snapshot.machines == [machine])
        #expect(snapshot.addresses == [address])
        #expect(snapshot.credentials == [credential])
        #expect(snapshot.profiles == [.ssh(profile)])
    }

    @Test func updatingAMachineKeepsItsAddressesAndProfiles() async throws {
        let (library, machine, _, _, _) = try await seeded()
        var renamed = machine
        renamed.name = "alpha-2"
        renamed.tags = ["lab"]
        try await library.save(.upsertMachine(renamed))
        let snapshot = try await library.snapshot()
        #expect(snapshot.machines == [renamed])
        #expect(snapshot.addresses(for: machine.id).count == 1)
        #expect(snapshot.profiles(for: machine.id).count == 1)
    }

    @Test func deletingAMachineCascades() async throws {
        let (library, machine, _, credential, _) = try await seeded()
        try await library.save(.deleteMachine(machine.id))
        let snapshot = try await library.snapshot()
        #expect(snapshot.machines.isEmpty)
        #expect(snapshot.addresses.isEmpty)
        #expect(snapshot.profiles.isEmpty)
        // Credentials are shared and survive; the UI offers to remove orphans.
        #expect(snapshot.orphanedCredentials == [credential])
    }

    @Test func deletingReferencedRowsClearsTheProfileView() async throws {
        let (library, machine, address, credential, profile) = try await seeded()
        try await library.save(.batch([.deleteAddress(address.id), .deleteCredential(credential.id)]))
        let snapshot = try await library.snapshot()
        let stored = try #require(snapshot.profile(profile.id))
        #expect(stored.addressSelection == .automatic)
        #expect(stored.credentialID == nil)
        #expect(stored.machineID == machine.id)
    }

    @Test func rejectsAddressesForUnknownMachines() async throws {
        let library = try GRDBMachineLibrary.inMemory()
        let orphan = MachineAddress(machineID: MachineID(), label: "LAN", host: "10.0.0.1")
        await #expect(throws: MachineLibraryError.unknownMachine(orphan.machineID)) {
            try await library.save(.upsertAddress(orphan))
        }
    }

    @Test func validationFailuresAreSurfacedAndNothingIsWritten() async throws {
        let library = try GRDBMachineLibrary.inMemory()
        let machine = Machine(name: "ok")
        await #expect(throws: MachineLibraryError.validation(.invalidPort(0))) {
            try await library.save(.batch([
                .upsertMachine(machine),
                .upsertProfile(.ssh(SSHProfile(machineID: machine.id, port: 0))),
            ]))
        }
        #expect(try await library.snapshot() == .empty)
    }

    @Test func corruptProfileJSONIsReportedNotDropped() async throws {
        let (library, machine, _, _, profile) = try await seeded()
        try library.execute(sql: "UPDATE connection_profiles SET settings_json = '{\"broken\": true}' WHERE id = ?", arguments: [profile.id.description])
        await #expect(throws: MachineLibraryError.self) {
            _ = try await library.snapshot()
        }
        do {
            _ = try await library.snapshot()
        } catch let MachineLibraryError.corruptRecord(table, id, _) {
            #expect(table == "connection_profiles")
            #expect(id == profile.id.description)
        }
        _ = machine
    }

    @Test func persistsAcrossReopen() async throws {
        let path = FileManager.default.temporaryDirectory
            .appendingPathComponent("constellation-tests-\(UUID().uuidString)/library.sqlite").path
        defer { try? FileManager.default.removeItem(atPath: URL(fileURLWithPath: path).deletingLastPathComponent().path) }
        let machine = Machine(name: "persisted", tags: ["a"])
        do {
            let library = try GRDBMachineLibrary(path: path)
            try await library.save(.upsertMachine(machine))
        }
        let reopened = try GRDBMachineLibrary(path: path)
        #expect(try await reopened.snapshot().machines == [machine])
    }

    @Test func replacesAndRestoresWorkspaceTabsInOrder() async throws {
        let (library, machine, _, _, profile) = try await seeded()
        let first = WorkspaceTab(
            id: SessionID(), machineID: machine.id, profileID: profile.id,
            title: "first", position: 1)
        let second = WorkspaceTab(
            id: SessionID(), machineID: machine.id, profileID: profile.id,
            title: "second", position: 0, isSelected: true)

        try await library.save(.replaceWorkspace([first, second]))

        #expect(try await library.snapshot().workspaceTabs == [second, first])
        try await library.save(.replaceWorkspace([]))
        #expect(try await library.snapshot().workspaceTabs.isEmpty)
    }

    @Test func deletingAProfileRemovesItsWorkspaceTabs() async throws {
        let (library, machine, _, _, profile) = try await seeded()
        let tab = WorkspaceTab(
            id: SessionID(), machineID: machine.id, profileID: profile.id,
            title: "SSH", position: 0)
        try await library.save(.replaceWorkspace([tab]))

        try await library.save(.deleteProfile(profile.id))

        #expect(try await library.snapshot().workspaceTabs.isEmpty)
    }
}
