import ConstellationCore
import Foundation
import GRDB
import Testing
@testable import ConstellationStorage

/// Clean-install and upgrade paths for the on-disk databases. The upgrade
/// test builds the first shipped schema with the real v1 migration, plants
/// rows the way that version wrote them, and opens it with the current code.
struct GRDBUpgradeTests {
    private func temporaryPath(_ name: String) -> String {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("constellation-upgrade-\(UUID().uuidString)")
        return directory.appendingPathComponent("nested").appendingPathComponent(name).path
    }

    @Test func createsTheLibraryInAMissingDirectory() async throws {
        let path = temporaryPath("library.sqlite")
        let library = try GRDBMachineLibrary(path: path)
        let snapshot = try await library.snapshot()
        #expect(snapshot.machines.isEmpty)
        #expect(FileManager.default.fileExists(atPath: path))
    }

    @Test func createsTheTrustStoreInAMissingDirectory() async throws {
        let path = temporaryPath("trust.sqlite")
        let store = try GRDBTrustStore(path: path)
        #expect(try await store.all().isEmpty)
        #expect(FileManager.default.fileExists(atPath: path))
    }

    @Test func upgradesALibraryFromSchemaV1() async throws {
        let path = temporaryPath("library.sqlite")
        let machine = Machine(name: "alpha", notes: "", tags: ["homelab"], isFavorite: true)
        let address = MachineAddress(machineID: machine.id, label: "LAN", host: "192.0.2.18", kind: .lan, priority: 0)
        let credential = CredentialReference(label: "password", kind: .password)
        let profile = SSHProfile(machineID: machine.id, name: "SSH", username: "nick", addressSelection: .pinned(address.id), authentication: .password, credentialID: credential.id)

        do {
            try FileManager.default.createDirectory(
                at: URL(fileURLWithPath: path).deletingLastPathComponent(), withIntermediateDirectories: true)
            let v1 = try DatabaseQueue(path: path)
            try await GRDBMachineLibrary.migrator.migrate(v1, upTo: "v1")
            let json = String(decoding: try JSONEncoder().encode(ConnectionProfile.ssh(profile)), as: UTF8.self)
            try await v1.write { db in
                try db.execute(sql: "INSERT INTO machines (id, name, notes, is_favorite) VALUES (?, ?, ?, ?)",
                               arguments: [machine.id.description, machine.name, machine.notes, machine.isFavorite])
                try db.execute(sql: "INSERT INTO machine_tags (machine_id, tag) VALUES (?, ?)",
                               arguments: [machine.id.description, "homelab"])
                try db.execute(sql: "INSERT INTO machine_addresses (id, machine_id, label, host, kind, priority) VALUES (?, ?, ?, ?, ?, ?)",
                               arguments: [address.id.description, machine.id.description, address.label, address.host, address.kind.rawValue, address.priority])
                try db.execute(sql: "INSERT INTO credential_references (id, label, kind) VALUES (?, ?, ?)",
                               arguments: [credential.id.description, credential.label, credential.kind.rawValue])
                try db.execute(sql: """
                    INSERT INTO connection_profiles
                        (id, machine_id, protocol, name, username, port, pinned_address_id, credential_id, settings_version, settings_json)
                    VALUES (?, ?, 'ssh', ?, ?, NULL, ?, ?, 1, ?)
                    """, arguments: [profile.id.description, machine.id.description, profile.name, profile.username, address.id.description, credential.id.description, json])
                let tables = try String.fetchAll(db, sql: "SELECT name FROM sqlite_master WHERE type = 'table'")
                #expect(!tables.contains("workspace_tabs"))
            }
        }

        let library = try GRDBMachineLibrary(path: path)
        let snapshot = try await library.snapshot()
        #expect(snapshot.machines == [machine])
        #expect(snapshot.addresses == [address])
        #expect(snapshot.credentials == [credential])
        #expect(snapshot.profiles == [.ssh(profile)])
        #expect(snapshot.workspaceTabs.isEmpty)

        // The v2 table exists and takes rows that reference the migrated data.
        let tab = WorkspaceTab(id: SessionID(), machineID: machine.id, profileID: profile.id, title: "alpha", position: 0, isSelected: true)
        try await library.save(.replaceWorkspace([tab]))
        #expect(try await library.snapshot().workspaceTabs == [tab])
    }

    @Test func refusesAProfileWrittenByANewerVersion() async throws {
        let library = try GRDBMachineLibrary.inMemory()
        let machine = Machine(name: "future", notes: "", tags: [], isFavorite: false)
        try await library.save(.upsertMachine(machine))
        try library.execute(sql: """
            INSERT INTO connection_profiles (id, machine_id, protocol, name, settings_version, settings_json)
            VALUES (?, ?, 'ssh', 'SSH', 2, '{}')
            """, arguments: [ProfileID().description, machine.id.description])
        await #expect(throws: MachineLibraryError.self) { try await library.snapshot() }
    }
}
