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
        return migrator
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

        let machines = try Row.fetchAll(db, sql: "SELECT * FROM machines ORDER BY name").map { row in
            let id = try id(MachineID.self, row["id"], table: "machines")
            return Machine(
                id: id,
                name: row["name"],
                notes: row["notes"],
                tags: tags[id] ?? [],
                isFavorite: row["is_favorite"],
                defaultProfileID: (row["default_profile_id"] as String?).flatMap(ProfileID.init(uuidString:)))
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

        return MachineLibrarySnapshot(machines: machines, addresses: addresses, profiles: profiles, credentials: credentials)
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
            try db.execute(sql: """
                INSERT INTO machines (id, name, notes, is_favorite, default_profile_id)
                VALUES (?, ?, ?, ?, ?)
                ON CONFLICT(id) DO UPDATE SET
                    name = excluded.name, notes = excluded.notes,
                    is_favorite = excluded.is_favorite, default_profile_id = excluded.default_profile_id
                """, arguments: [machine.id.description, machine.name, machine.notes, machine.isFavorite, machine.defaultProfileID?.description])
            try db.execute(sql: "DELETE FROM machine_tags WHERE machine_id = ?", arguments: [machine.id.description])
            for tag in machine.tags.sorted() {
                try db.execute(sql: "INSERT INTO machine_tags (machine_id, tag) VALUES (?, ?)", arguments: [machine.id.description, tag])
            }

        case .deleteMachine(let id):
            try db.execute(sql: "DELETE FROM machines WHERE id = ?", arguments: [id.description])

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

        case .batch(let changes):
            for change in changes { try apply(change, db) }
        }
    }

    private static func machineID(in change: MachineLibraryChange) -> MachineID? {
        switch change {
        case .upsertAddress(let address): address.machineID
        case .upsertProfile(let profile): profile.machineID
        case .batch(let changes): changes.lazy.compactMap(machineID(in:)).first
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
