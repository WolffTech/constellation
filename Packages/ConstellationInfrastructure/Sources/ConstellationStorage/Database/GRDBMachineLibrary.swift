// SPDX-FileCopyrightText: 2026 Nick Wolff <nick@wolff.tech>
// SPDX-License-Identifier: GPL-3.0-only

import ConstellationCore
import Foundation
import GRDB

/// SQLite-backed `MachineLibrary`. Shared, queryable fields live in typed
/// columns; each profile's full definition is stored as versioned JSON that
/// is the source of truth when reading.
public final class GRDBMachineLibrary: MachineLibrary, Sendable {
    private let dbQueue: DatabaseQueue

    public init(path: String) throws {
        try FileManager.default.createDirectory(
            at: URL(fileURLWithPath: path).deletingLastPathComponent(),
            withIntermediateDirectories: true)
        var configuration = Configuration()
        configuration.foreignKeysEnabled = true
        dbQueue = try DatabaseQueue(path: path, configuration: configuration)
        try Self.migrator.migrate(dbQueue)
    }

    /// A throwaway database for tests.
    public static func inMemory() throws -> GRDBMachineLibrary {
        try GRDBMachineLibrary(dbQueue: DatabaseQueue())
    }

    private init(dbQueue: DatabaseQueue) throws {
        self.dbQueue = dbQueue
        try Self.migrator.migrate(dbQueue)
    }

    static var migrator: DatabaseMigrator {
        var migrator = DatabaseMigrator()
        migrator.registerMigration("v1") { db in
            try db.create(table: "machines") { t in
                t.primaryKey("id", .text)
                t.column("name", .text).notNull()
                t.column("notes", .text).notNull().defaults(to: "")
                t.column("is_favorite", .boolean).notNull().defaults(to: false)
                t.column("default_profile_id", .text)
            }
            try db.create(table: "machine_tags") { t in
                t.column("machine_id", .text).notNull().references("machines", onDelete: .cascade)
                t.column("tag", .text).notNull()
                t.primaryKey(["machine_id", "tag"])
            }
            try db.create(table: "machine_addresses") { t in
                t.primaryKey("id", .text)
                t.column("machine_id", .text).notNull().indexed().references("machines", onDelete: .cascade)
                t.column("label", .text).notNull()
                t.column("host", .text).notNull()
                t.column("kind", .text).notNull()
                t.column("priority", .integer).notNull().defaults(to: 0)
            }
            try db.create(table: "credential_references") { t in
                t.primaryKey("id", .text)
                t.column("label", .text).notNull()
                t.column("kind", .text).notNull()
            }
            try db.create(table: "connection_profiles") { t in
                t.primaryKey("id", .text)
                t.column("machine_id", .text).notNull().indexed().references("machines", onDelete: .cascade)
                t.column("protocol", .text).notNull()
                t.column("name", .text).notNull()
                t.column("username", .text)
                t.column("port", .integer)
                t.column("pinned_address_id", .text).references("machine_addresses", onDelete: .setNull)
                t.column("credential_id", .text).references("credential_references", onDelete: .setNull)
                t.column("settings_version", .integer).notNull()
                t.column("settings_json", .text).notNull()
            }
        }
        migrator.registerMigration("v2-workspace-tabs") { db in
            try db.create(table: "workspace_tabs") { t in
                t.primaryKey("id", .text)
                t.column("machine_id", .text).notNull().references("machines", onDelete: .cascade)
                t.column("profile_id", .text).notNull().references("connection_profiles", onDelete: .cascade)
                t.column("title", .text).notNull()
                t.column("position", .integer).notNull().unique()
                t.column("is_selected", .boolean).notNull().defaults(to: false)
            }
        }
        migrator.registerMigration("v3-local-workspace-tabs") { db in
            try db.execute(sql: "ALTER TABLE workspace_tabs RENAME TO workspace_tabs_v2")
            try db.execute(sql: """
                CREATE TABLE workspace_tabs (
                    id TEXT PRIMARY KEY,
                    target TEXT NOT NULL CHECK (target IN ('saved', 'local')),
                    machine_id TEXT REFERENCES machines(id) ON DELETE CASCADE,
                    profile_id TEXT REFERENCES connection_profiles(id) ON DELETE CASCADE,
                    title TEXT NOT NULL,
                    position INTEGER NOT NULL UNIQUE,
                    is_selected BOOLEAN NOT NULL DEFAULT 0,
                    CHECK (
                        (target = 'saved' AND machine_id IS NOT NULL AND profile_id IS NOT NULL)
                        OR (target = 'local' AND machine_id IS NULL AND profile_id IS NULL)
                    )
                )
                """)
            try db.execute(sql: """
                INSERT INTO workspace_tabs (id, target, machine_id, profile_id, title, position, is_selected)
                SELECT id, 'saved', machine_id, profile_id, title, position, is_selected
                FROM workspace_tabs_v2
                """)
            try db.execute(sql: "DROP TABLE workspace_tabs_v2")
        }
        migrator.registerMigration("v4-groups") { db in
            try db.create(table: "machine_groups") { t in
                t.primaryKey("id", .text)
                t.column("name", .text).notNull()
                t.column("position", .integer).notNull().defaults(to: 0)
            }
            try db.alter(table: "machines") { t in
                t.add(column: "group_id", .text).references("machine_groups", onDelete: .setNull)
                t.add(column: "position", .integer).notNull().defaults(to: 0)
            }
            try migrateTagsToGroups(db)
        }
        return migrator
    }

    /// Recreates the sidebar as it looked before groups: one group per tag in
    /// alphabetical order, each machine in its alphabetically first tag,
    /// machines by name. Tags themselves are kept.
    private static func migrateTagsToGroups(_ db: Database) throws {
        let rows = try Row.fetchAll(db, sql: """
            SELECT t.machine_id, t.tag FROM machine_tags t JOIN machines m ON m.id = t.machine_id ORDER BY t.tag, m.name
            """)
        var groupIDs: [String: String] = [:]
        var firstTag: [String: String] = [:]
        for row in rows {
            let tag: String = row["tag"]
            let machineID: String = row["machine_id"]
            if groupIDs[tag] == nil {
                let id = GroupID().description
                groupIDs[tag] = id
                try db.execute(sql: "INSERT INTO machine_groups (id, name, position) VALUES (?, ?, ?)",
                               arguments: [id, tag.capitalized, groupIDs.count - 1])
            }
            if firstTag[machineID] == nil { firstTag[machineID] = tag }
        }
        for (machineID, tag) in firstTag {
            try db.execute(sql: "UPDATE machines SET group_id = ? WHERE id = ?", arguments: [groupIDs[tag], machineID])
        }
        for id in try String.fetchAll(db, sql: "SELECT id FROM machine_groups") {
            try renumberMachines(in: GroupID(uuidString: id), db)
        }
        try renumberMachines(in: nil, db)
    }

    // MARK: MachineLibrary

    public func snapshot() async throws -> MachineLibrarySnapshot {
        try await dbQueue.read { db in try Self.readSnapshot(db) }
    }

    public func save(_ change: MachineLibraryChange) async throws {
        do {
            try Validator.validate(change)
        } catch {
            throw MachineLibraryError.validation(error)
        }
        do {
            try await dbQueue.write { db in try Self.apply(change, db) }
        } catch let error as DatabaseError where error.extendedResultCode == .SQLITE_CONSTRAINT_FOREIGNKEY {
            throw MachineLibraryError.unknownMachine(Self.machineID(in: change) ?? MachineID())
        }
    }

    /// Raw SQL access for tests that need to plant bad rows.
    func execute(sql: String, arguments: StatementArguments = []) throws {
        try dbQueue.write { db in try db.execute(sql: sql, arguments: arguments) }
    }

    // MARK: Reading

    private static func readSnapshot(_ db: Database) throws -> MachineLibrarySnapshot {
        var tags: [MachineID: Set<String>] = [:]
        for row in try Row.fetchAll(db, sql: "SELECT machine_id, tag FROM machine_tags") {
            let id = try id(MachineID.self, row["machine_id"], table: "machine_tags")
            tags[id, default: []].insert(row["tag"])
        }

        let groups = try Row.fetchAll(db, sql: "SELECT * FROM machine_groups ORDER BY position, name").map { row in
            MachineGroup(id: try id(GroupID.self, row["id"], table: "machine_groups"), name: row["name"], position: row["position"])
        }

        let machines = try Row.fetchAll(db, sql: """
            SELECT m.* FROM machines m LEFT JOIN machine_groups g ON g.id = m.group_id
            ORDER BY g.position IS NULL, g.position, m.position, m.name
            """).map { row in
            let id = try id(MachineID.self, row["id"], table: "machines")
            return Machine(
                id: id,
                name: row["name"],
                notes: row["notes"],
                tags: tags[id] ?? [],
                isFavorite: row["is_favorite"],
                defaultProfileID: (row["default_profile_id"] as String?).flatMap(ProfileID.init(uuidString:)),
                groupID: (row["group_id"] as String?).flatMap(GroupID.init(uuidString:)),
                position: row["position"])
        }

        let addresses = try Row.fetchAll(db, sql: "SELECT * FROM machine_addresses ORDER BY priority, label").map { row in
            guard let kind = AddressKind(rawValue: row["kind"]) else {
                throw MachineLibraryError.corruptRecord(table: "machine_addresses", id: row["id"], reason: "unknown kind \(row["kind"] as String)")
            }
            return MachineAddress(
                id: try id(AddressID.self, row["id"], table: "machine_addresses"),
                machineID: try id(MachineID.self, row["machine_id"], table: "machine_addresses"),
                label: row["label"],
                host: row["host"],
                kind: kind,
                priority: row["priority"])
        }

        let credentials = try Row.fetchAll(db, sql: "SELECT * FROM credential_references ORDER BY label").map { row in
            guard let kind = CredentialKind(rawValue: row["kind"]) else {
                throw MachineLibraryError.corruptRecord(table: "credential_references", id: row["id"], reason: "unknown kind \(row["kind"] as String)")
            }
            return CredentialReference(id: try id(CredentialID.self, row["id"], table: "credential_references"), label: row["label"], kind: kind)
        }

        let addressIDs = Set(addresses.map(\.id))
        let credentialIDs = Set(credentials.map(\.id))
        let decoder = JSONDecoder()
        let profiles = try Row.fetchAll(db, sql: "SELECT id, settings_version, settings_json FROM connection_profiles ORDER BY name").map { row in
            let rowID: String = row["id"]
            let version: Int = row["settings_version"]
            guard version <= 1 else {
                throw MachineLibraryError.corruptRecord(table: "connection_profiles", id: rowID, reason: "settings version \(version) is newer than this app")
            }
            let json: String = row["settings_json"]
            let profile: ConnectionProfile
            do {
                profile = try decoder.decode(ConnectionProfile.self, from: Data(json.utf8))
            } catch {
                throw MachineLibraryError.corruptRecord(table: "connection_profiles", id: rowID, reason: "\(error)")
            }
            // Deleted addresses and credentials are nulled by SQLite; mirror that in the JSON view.
            return reconcile(profile, addressIDs: addressIDs, credentialIDs: credentialIDs)
        }

        let workspaceTabs = try Row.fetchAll(db, sql: "SELECT * FROM workspace_tabs ORDER BY position").map { row in
            let rowID: String = row["id"]
            let target: WorkspaceTabTarget
            switch row["target"] as String {
            case "local":
                target = .local
            case "saved":
                guard let machineIDText: String = row["machine_id"],
                      let profileIDText: String = row["profile_id"] else {
                    throw MachineLibraryError.corruptRecord(
                        table: "workspace_tabs", id: rowID, reason: "saved target has no machine or profile")
                }
                target = .saved(
                    machineID: try id(MachineID.self, machineIDText, table: "workspace_tabs"),
                    profileID: try id(ProfileID.self, profileIDText, table: "workspace_tabs"))
            case let value:
                throw MachineLibraryError.corruptRecord(
                    table: "workspace_tabs", id: rowID, reason: "unknown target \(value)")
            }
            return WorkspaceTab(
                id: try id(SessionID.self, rowID, table: "workspace_tabs"),
                target: target,
                title: row["title"],
                position: row["position"],
                isSelected: row["is_selected"])
        }

        return MachineLibrarySnapshot(
            machines: machines,
            groups: groups,
            addresses: addresses,
            profiles: profiles,
            credentials: credentials,
            workspaceTabs: workspaceTabs)
    }

    private static func reconcile(_ profile: ConnectionProfile, addressIDs: Set<AddressID>, credentialIDs: Set<CredentialID>) -> ConnectionProfile {
        var result = profile
        if case .pinned(let id) = profile.addressSelection, !addressIDs.contains(id) {
            result = result.withAddressSelection(.automatic)
        }
        if let credential = profile.credentialID, !credentialIDs.contains(credential) {
            result = result.withoutCredential()
        }
        return result
    }

    private static func id<T>(_ type: TypedID<T>.Type, _ value: String, table: String) throws -> TypedID<T> {
        guard let id = TypedID<T>(uuidString: value) else {
            throw MachineLibraryError.corruptRecord(table: table, id: value, reason: "not a UUID")
        }
        return id
    }

    // MARK: Writing

    private static func apply(_ change: MachineLibraryChange, _ db: Database) throws {
        switch change {
        case .upsertMachine(let machine):
            if let groupID = machine.groupID { try requireGroup(groupID, db) }
            // The position is the library's: kept unless the machine is new or changed group.
            let existing = try Row.fetchOne(db, sql: "SELECT group_id, position FROM machines WHERE id = ?", arguments: [machine.id.description])
            let previousGroup = existing.map { ($0["group_id"] as String?).flatMap(GroupID.init(uuidString:)) }
            let position: Int = if let existing, previousGroup == machine.groupID {
                existing["position"]
            } else {
                try nextMachinePosition(in: machine.groupID, db)
            }
            try db.execute(sql: """
                INSERT INTO machines (id, name, notes, is_favorite, default_profile_id, group_id, position)
                VALUES (?, ?, ?, ?, ?, ?, ?)
                ON CONFLICT(id) DO UPDATE SET
                    name = excluded.name, notes = excluded.notes,
                    is_favorite = excluded.is_favorite, default_profile_id = excluded.default_profile_id,
                    group_id = excluded.group_id, position = excluded.position
                """, arguments: [
                    machine.id.description, machine.name, machine.notes, machine.isFavorite, machine.defaultProfileID?.description,
                    machine.groupID?.description, position,
                ])
            if let previousGroup, previousGroup != machine.groupID { try renumberMachines(in: previousGroup, db) }
            try db.execute(sql: "DELETE FROM machine_tags WHERE machine_id = ?", arguments: [machine.id.description])
            for tag in machine.tags.sorted() {
                try db.execute(sql: "INSERT INTO machine_tags (machine_id, tag) VALUES (?, ?)", arguments: [machine.id.description, tag])
            }

        case .deleteMachine(let id):
            let groupID = try Row.fetchOne(db, sql: "SELECT group_id FROM machines WHERE id = ?", arguments: [id.description])
                .flatMap { ($0["group_id"] as String?).flatMap(GroupID.init(uuidString:)) }
            try db.execute(sql: "DELETE FROM machines WHERE id = ?", arguments: [id.description])
            try renumberMachines(in: groupID, db)

        case .upsertGroup(let group):
            let position = try Int.fetchOne(db, sql: "SELECT coalesce(max(position) + 1, 0) FROM machine_groups") ?? 0
            try db.execute(sql: """
                INSERT INTO machine_groups (id, name, position) VALUES (?, ?, ?)
                ON CONFLICT(id) DO UPDATE SET name = excluded.name
                """, arguments: [group.id.description, group.name, position])

        case .deleteGroup(let id):
            try requireGroup(id, db)
            // Its machines go after the ungrouped ones before the FK nulls their group.
            let offset = try nextMachinePosition(in: nil, db)
            try db.execute(sql: "UPDATE machines SET position = position + ? WHERE group_id = ?", arguments: [offset, id.description])
            try db.execute(sql: "DELETE FROM machine_groups WHERE id = ?", arguments: [id.description])
            try renumberMachines(in: nil, db)
            try renumberGroups(db)

        case .moveMachine(let id, let groupID, let position):
            if let groupID { try requireGroup(groupID, db) }
            guard let row = try Row.fetchOne(db, sql: "SELECT group_id FROM machines WHERE id = ?", arguments: [id.description]) else {
                throw MachineLibraryError.unknownMachine(id)
            }
            let previousGroup = (row["group_id"] as String?).flatMap(GroupID.init(uuidString:))
            var siblings = try machineIDs(in: groupID, db).filter { $0 != id.description }
            siblings.insert(id.description, at: max(0, min(position, siblings.count)))
            for (index, siblingID) in siblings.enumerated() {
                try db.execute(sql: "UPDATE machines SET group_id = ?, position = ? WHERE id = ?",
                               arguments: [groupID?.description, index, siblingID])
            }
            if previousGroup != groupID { try renumberMachines(in: previousGroup, db) }

        case .moveGroup(let id, let position):
            try requireGroup(id, db)
            var ids = try String.fetchAll(db, sql: "SELECT id FROM machine_groups ORDER BY position, name").filter { $0 != id.description }
            ids.insert(id.description, at: max(0, min(position, ids.count)))
            for (index, groupID) in ids.enumerated() {
                try db.execute(sql: "UPDATE machine_groups SET position = ? WHERE id = ?", arguments: [index, groupID])
            }

        case .upsertAddress(let address):
            try db.execute(sql: """
                INSERT INTO machine_addresses (id, machine_id, label, host, kind, priority)
                VALUES (?, ?, ?, ?, ?, ?)
                ON CONFLICT(id) DO UPDATE SET
                    machine_id = excluded.machine_id, label = excluded.label, host = excluded.host,
                    kind = excluded.kind, priority = excluded.priority
                """, arguments: [address.id.description, address.machineID.description, address.label, address.host, address.kind.rawValue, address.priority])

        case .deleteAddress(let id):
            try db.execute(sql: "DELETE FROM machine_addresses WHERE id = ?", arguments: [id.description])

        case .upsertProfile(let profile):
            let json = String(decoding: try JSONEncoder().encode(profile), as: UTF8.self)
            let pinned: String? = if case .pinned(let id) = profile.addressSelection { id.description } else { nil }
            try db.execute(sql: """
                INSERT INTO connection_profiles
                    (id, machine_id, protocol, name, username, port, pinned_address_id, credential_id, settings_version, settings_json)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?, 1, ?)
                ON CONFLICT(id) DO UPDATE SET
                    machine_id = excluded.machine_id, protocol = excluded.protocol, name = excluded.name,
                    username = excluded.username, port = excluded.port, pinned_address_id = excluded.pinned_address_id,
                    credential_id = excluded.credential_id, settings_version = excluded.settings_version,
                    settings_json = excluded.settings_json
                """, arguments: [
                    profile.id.description, profile.machineID.description, profile.protocolKind.rawValue, profile.name,
                    profile.username, profile.port, pinned, profile.credentialID?.description, json,
                ])

        case .deleteProfile(let id):
            try db.execute(sql: "DELETE FROM connection_profiles WHERE id = ?", arguments: [id.description])

        case .upsertCredential(let credential):
            try db.execute(sql: """
                INSERT INTO credential_references (id, label, kind) VALUES (?, ?, ?)
                ON CONFLICT(id) DO UPDATE SET label = excluded.label, kind = excluded.kind
                """, arguments: [credential.id.description, credential.label, credential.kind.rawValue])

        case .deleteCredential(let id):
            try db.execute(sql: "DELETE FROM credential_references WHERE id = ?", arguments: [id.description])

        case .replaceWorkspace(let tabs):
            try db.execute(sql: "DELETE FROM workspace_tabs")
            for tab in tabs.sorted(by: { $0.position < $1.position }) {
                let target: String
                let machineID: String?
                let profileID: String?
                switch tab.target {
                case .local:
                    target = "local"
                    machineID = nil
                    profileID = nil
                case .saved(let savedMachineID, let savedProfileID):
                    target = "saved"
                    machineID = savedMachineID.description
                    profileID = savedProfileID.description
                }
                try db.execute(sql: """
                    INSERT INTO workspace_tabs (id, target, machine_id, profile_id, title, position, is_selected)
                    VALUES (?, ?, ?, ?, ?, ?, ?)
                    """, arguments: [
                        tab.id.description, target, machineID, profileID, tab.title, tab.position, tab.isSelected,
                    ])
            }

        case .batch(let changes):
            for change in changes { try apply(change, db) }
        }
    }

    private static func requireGroup(_ id: GroupID, _ db: Database) throws {
        guard try Bool.fetchOne(db, sql: "SELECT EXISTS (SELECT 1 FROM machine_groups WHERE id = ?)", arguments: [id.description]) == true else {
            throw MachineLibraryError.unknownGroup(id)
        }
    }

    private static func machineIDs(in groupID: GroupID?, _ db: Database) throws -> [String] {
        try String.fetchAll(db, sql: "SELECT id FROM machines WHERE group_id IS ? ORDER BY position, name", arguments: [groupID?.description])
    }

    private static func nextMachinePosition(in groupID: GroupID?, _ db: Database) throws -> Int {
        try Int.fetchOne(db, sql: "SELECT coalesce(max(position) + 1, 0) FROM machines WHERE group_id IS ?", arguments: [groupID?.description]) ?? 0
    }

    /// Makes positions dense again after a removal.
    private static func renumberMachines(in groupID: GroupID?, _ db: Database) throws {
        for (index, id) in try machineIDs(in: groupID, db).enumerated() {
            try db.execute(sql: "UPDATE machines SET position = ? WHERE id = ?", arguments: [index, id])
        }
    }

    private static func renumberGroups(_ db: Database) throws {
        for (index, id) in try String.fetchAll(db, sql: "SELECT id FROM machine_groups ORDER BY position, name").enumerated() {
            try db.execute(sql: "UPDATE machine_groups SET position = ? WHERE id = ?", arguments: [index, id])
        }
    }

    private static func machineID(in change: MachineLibraryChange) -> MachineID? {
        switch change {
        case .upsertAddress(let address): address.machineID
        case .upsertProfile(let profile): profile.machineID
        case .batch(let changes): changes.lazy.compactMap(machineID(in:)).first
        case .replaceWorkspace(let tabs):
            tabs.lazy.compactMap { tab in
                if case .saved(let machineID, _) = tab.target { machineID } else { nil }
            }.first
        default: nil
        }
    }
}

extension ConnectionProfile {
    func withAddressSelection(_ selection: AddressSelection) -> ConnectionProfile {
        switch self {
        case .ssh(var p): p.addressSelection = selection; return .ssh(p)
        case .vnc(var p): p.addressSelection = selection; return .vnc(p)
        case .rdp(var p): p.addressSelection = selection; return .rdp(p)
        case .appleScreenSharing(var p): p.addressSelection = selection; return .appleScreenSharing(p)
        }
    }
}
