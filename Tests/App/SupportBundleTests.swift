// SPDX-FileCopyrightText: 2026 Nick Wolff <nick@wolff.tech>
// SPDX-License-Identifier: GPL-3.0-only

import ConstellationCore
import Foundation
import Testing
@testable import Constellation

struct SupportBundleTests {
    private func summary(state: SessionState, kind: ConnectionProtocol = .rdp) -> SessionSummary {
        var summary = SessionSummary(
            id: SessionID(), target: .saved(machineID: MachineID(), profileID: ProfileID()), title: "wolff-gm01", machineName: "Wolff-GM01",
            profileName: "RDP", state: state, endpoint: nil)
        summary.kind = .connection(kind)
        return summary
    }

    @Test func sessionLinesCarryProtocolAndStateOnly() {
        let failed = summary(state: .failed(.remoteDesktop("Could not reach wolff-gm01.tail.net:3389 as nick")))
        #expect(SupportBundle.line(for: failed) == "rdp failed (remote desktop error) fit")
        #expect(SupportBundle.line(for: summary(state: .disconnected, kind: .ssh)) == "ssh disconnected")
        let local = SessionSummary(
            id: SessionID(), target: .local, title: "This Mac", machineName: "This Mac",
            profileName: "Terminal", state: .running(startedAt: .now), kind: .localTerminal)
        #expect(SupportBundle.line(for: local) == "local running")
    }

    @Test func filesNeverIncludeSessionNames() {
        let bundle = SupportBundle(
            appVersion: "0.9.0", build: "42", bundleIdentifier: "tech.wolff.Constellation",
            systemVersion: "macOS 26.0", hardwareModel: "Mac16,1", generatedAt: Date(timeIntervalSince1970: 0),
            sessionLines: [SupportBundle.line(for: summary(state: .failed(.authenticationFailed("bad password for nick@wolff-gm01"))))],
            databaseSummaries: ["library.sqlite\nmachines: 3 rows\n"],
            terminalSettingsJSON: "{}",
            logLines: ["2026-08-25T00:00:00Z [rdp] info rdp post_connect 2560x1600"])
        let everything = bundle.files.values.joined(separator: "\n")
        #expect(bundle.files.keys.sorted() == ["README.txt", "databases.txt", "log.txt", "sessions.txt", "system.txt", "terminal-settings.json"])
        #expect(everything.contains("0.9.0 (42)"))
        #expect(everything.contains("rdp failed (authentication failed) fit"))
        #expect(!everything.contains("wolff-gm01"))
        #expect(!everything.contains("nick"))
        #expect(!everything.contains("bad password"))
    }

    @Test func writesEveryFile() throws {
        let bundle = SupportBundle(
            appVersion: "0.9.0", build: "1", bundleIdentifier: "tech.wolff.Constellation",
            systemVersion: "macOS", hardwareModel: "Mac", generatedAt: Date(),
            sessionLines: [], databaseSummaries: [], terminalSettingsJSON: "{}", logLines: [])
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("support-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        try bundle.write(to: directory)
        let written = try FileManager.default.contentsOfDirectory(atPath: directory.path).sorted()
        #expect(written == bundle.files.keys.sorted())
        #expect(try String(contentsOf: directory.appendingPathComponent("sessions.txt"), encoding: .utf8) == "no open sessions\n")
    }
}
