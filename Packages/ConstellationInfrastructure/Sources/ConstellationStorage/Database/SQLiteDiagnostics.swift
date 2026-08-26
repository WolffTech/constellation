// SPDX-FileCopyrightText: 2026 Nick Wolff <nick@wolff.tech>
// SPDX-License-Identifier: GPL-3.0-only

import Foundation
import GRDB

/// Shape-only description of a database file for support bundles: applied
/// migrations and row counts per table. Never reads row contents.
public enum SQLiteDiagnostics {
    public static func summary(path: String) -> String {
        guard FileManager.default.fileExists(atPath: path) else {
            return "\(path): missing\n"
        }
        var configuration = Configuration()
        configuration.readonly = true
        do {
            let dbQueue = try DatabaseQueue(path: path, configuration: configuration)
            return try dbQueue.read { db in
                var lines = ["\(path)"]
                let size = (try? FileManager.default.attributesOfItem(atPath: path)[.size] as? Int) ?? 0
                lines.append("size: \(size) bytes")
                let migrations = try String.fetchAll(db, sql: "SELECT identifier FROM grdb_migrations ORDER BY rowid")
                lines.append("migrations: \(migrations.joined(separator: ", "))")
                let tables = try String.fetchAll(db, sql: """
                    SELECT name FROM sqlite_master WHERE type = 'table' AND name NOT LIKE 'sqlite_%' AND name != 'grdb_migrations' ORDER BY name
                    """)
                for table in tables {
                    let count = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM \"\(table)\"") ?? 0
                    lines.append("\(table): \(count) rows")
                }
                return lines.joined(separator: "\n") + "\n"
            }
        } catch {
            return "\(path): could not be read (\(error))\n"
        }
    }
}
