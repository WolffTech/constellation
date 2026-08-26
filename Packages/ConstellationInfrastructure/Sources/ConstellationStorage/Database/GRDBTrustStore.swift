// SPDX-FileCopyrightText: 2026 Nick Wolff <nick@wolff.tech>
// SPDX-License-Identifier: GPL-3.0-only

import ConstellationCore
import Foundation
import GRDB

/// SQLite-backed `TrustStore` in its own database file. Kept apart from the
/// machine library so certificate decisions are a self-contained store, as the
/// architecture describes.
public final class GRDBTrustStore: TrustStore, Sendable {
    private let dbQueue: DatabaseQueue

    public init(path: String) throws {
        try FileManager.default.createDirectory(
            at: URL(fileURLWithPath: path).deletingLastPathComponent(),
            withIntermediateDirectories: true)
        dbQueue = try DatabaseQueue(path: path)
        try Self.migrator.migrate(dbQueue)
    }

    /// A throwaway database for tests.
    public static func inMemory() throws -> GRDBTrustStore {
        try GRDBTrustStore(dbQueue: DatabaseQueue())
    }

    private init(dbQueue: DatabaseQueue) throws {
        self.dbQueue = dbQueue
        try Self.migrator.migrate(dbQueue)
    }

    static var migrator: DatabaseMigrator {
        var migrator = DatabaseMigrator()
        migrator.registerMigration("v1") { db in
            try db.create(table: "trusted_certificates") { t in
                t.column("host", .text).notNull()
                t.column("port", .integer).notNull()
                t.column("fingerprint", .text).notNull()
                t.column("subject", .text).notNull().defaults(to: "")
                t.column("issuer", .text).notNull().defaults(to: "")
                t.column("common_name", .text).notNull().defaults(to: "")
                t.primaryKey(["host", "port"])
            }
        }
        return migrator
    }

    // MARK: TrustStore

    public func trusted(host: String, port: Int) async throws -> TrustedCertificate? {
        try await dbQueue.read { db in
            try Row.fetchOne(
                db,
                sql: "SELECT * FROM trusted_certificates WHERE host = ? AND port = ?",
                arguments: [host, port]).map(Self.certificate)
        }
    }

    public func trust(_ certificate: TrustedCertificate) async throws {
        try await dbQueue.write { db in
            try db.execute(sql: """
                INSERT INTO trusted_certificates (host, port, fingerprint, subject, issuer, common_name)
                VALUES (?, ?, ?, ?, ?, ?)
                ON CONFLICT(host, port) DO UPDATE SET
                    fingerprint = excluded.fingerprint,
                    subject = excluded.subject,
                    issuer = excluded.issuer,
                    common_name = excluded.common_name
                """,
                arguments: [
                    certificate.host, certificate.port, certificate.fingerprint,
                    certificate.subject, certificate.issuer, certificate.commonName,
                ])
        }
    }

    public func forget(host: String, port: Int) async throws {
        try await dbQueue.write { db in
            try db.execute(
                sql: "DELETE FROM trusted_certificates WHERE host = ? AND port = ?",
                arguments: [host, port])
        }
    }

    public func all() async throws -> [TrustedCertificate] {
        try await dbQueue.read { db in
            try Row.fetchAll(db, sql: "SELECT * FROM trusted_certificates ORDER BY host, port").map(Self.certificate)
        }
    }

    private static func certificate(_ row: Row) -> TrustedCertificate {
        TrustedCertificate(
            host: row["host"],
            port: row["port"],
            fingerprint: row["fingerprint"],
            subject: row["subject"],
            issuer: row["issuer"],
            commonName: row["common_name"])
    }
}
