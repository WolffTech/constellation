// SPDX-FileCopyrightText: 2026 Nick Wolff <nick@wolff.tech>
// SPDX-License-Identifier: GPL-3.0-only

import ConstellationCore
import Foundation
import Testing
@testable import ConstellationStorage

struct SQLiteDiagnosticsTests {
    @Test func describesMigrationsAndCountsWithoutContents() async throws {
        let path = FileManager.default.temporaryDirectory
            .appendingPathComponent("constellation-diagnostics-\(UUID().uuidString).sqlite").path
        let library = try GRDBMachineLibrary(path: path)
        let machine = Machine(name: "hostname-that-must-not-appear", notes: "", tags: ["secret-tag"], isFavorite: false)
        try await library.save(.upsertMachine(machine))

        let summary = SQLiteDiagnostics.summary(path: path)
        #expect(summary.contains("migrations: v1, v2-workspace-tabs"))
        #expect(summary.contains("machines: 1 rows"))
        #expect(summary.contains("machine_tags: 1 rows"))
        #expect(summary.contains("workspace_tabs: 0 rows"))
        #expect(!summary.contains("hostname-that-must-not-appear"))
        #expect(!summary.contains("secret-tag"))
    }

    @Test func reportsAMissingFile() {
        let summary = SQLiteDiagnostics.summary(path: "/nonexistent/constellation.sqlite")
        #expect(summary == "/nonexistent/constellation.sqlite: missing\n")
    }
}
