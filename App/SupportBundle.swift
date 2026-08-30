// SPDX-FileCopyrightText: 2026 Nick Wolff <nick@wolff.tech>
// SPDX-License-Identifier: GPL-3.0-only

import AppKit
import ConstellationStorage
import ConstellationTerminal
import Foundation
import OSLog

/// What Help › Save Support Bundle writes: build and system facts, the shape
/// of the databases, session states and this run's log lines. Machine names,
/// hosts, accounts, clipboard text and secrets never go in; the log lines are
/// safe because the app's logging audit keeps them free of those.
struct SupportBundle {
    static let logSubsystem = "tech.wolff.Constellation"

    var appVersion: String
    var build: String
    var bundleIdentifier: String
    var systemVersion: String
    var hardwareModel: String
    var generatedAt: Date
    var sessionLines: [String]
    var databaseSummaries: [String]
    var terminalSettingsJSON: String
    var logLines: [String]

    /// File name → contents.
    var files: [String: String] {
        let stamp = ISO8601DateFormatter().string(from: generatedAt)
        return [
            "README.txt": """
                Constellation support bundle, generated \(stamp).

                Contains build and system facts, migration state and row counts of the
                databases, the protocol and state of open sessions, terminal appearance
                settings, and the log lines this run of the app wrote. It does not
                contain machine names, addresses, account names, passwords, clipboard
                contents or session output.

                """,
            "system.txt": """
                app: \(bundleIdentifier) \(appVersion) (\(build))
                macOS: \(systemVersion)
                model: \(hardwareModel)
                generated: \(stamp)

                """,
            "sessions.txt": sessionLines.isEmpty ? "no open sessions\n" : sessionLines.joined(separator: "\n") + "\n",
            "databases.txt": databaseSummaries.joined(separator: "\n"),
            "terminal-settings.json": terminalSettingsJSON + "\n",
            "log.txt": logLines.isEmpty ? "no log entries recorded for this run\n" : logLines.joined(separator: "\n") + "\n",
        ]
    }

    /// Protocol, state and display mode only. Failure messages stay out: they
    /// can quote the host or account the attempt used.
    static func line(for session: SessionSummary) -> String {
        let sessionKind = session.kind.connectionProtocol?.rawValue ?? "local"
        var parts = [sessionKind, session.state.displayName.lowercased()]
        if case .failed(let failure) = session.state {
            parts.append("(\(kind(of: failure)))")
        }
        if let connectionProtocol = session.kind.connectionProtocol,
           connectionProtocol != .ssh {
            // Not yet chosen reads as the picker shows it: fit.
            parts.append((session.displayMode ?? .fit) == .fit ? "fit" : "actual size")
        }
        return parts.joined(separator: " ")
    }

    private static func kind(of failure: ConnectionFailure) -> String {
        switch failure {
        case .noAddress: "no address"
        case .unreachable: "unreachable"
        case .unsupportedProtocol: "unsupported protocol"
        case .launchFailed: "launch failed"
        case .sshExited(let code): "ssh exited \(code)"
        case .endedWithoutStatus: "ended without status"
        case .authenticationFailed: "authentication failed"
        case .remoteDesktop: "remote desktop error"
        case .localShellExited(let code): "local shell exited \(code)"
        }
    }

    func write(to directory: URL) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        for (name, contents) in files {
            try contents.write(to: directory.appendingPathComponent(name), atomically: true, encoding: .utf8)
        }
    }

    // MARK: Collection

    @MainActor
    static func collect(root: CompositionRoot, now: Date = Date()) -> SupportBundle {
        let info = Bundle.main.infoDictionary ?? [:]
        let settings = (try? JSONEncoder.pretty.encode(root.terminalSettings.appearance))
            .map { String(decoding: $0, as: UTF8.self) } ?? "{}"
        return SupportBundle(
            appVersion: info["CFBundleShortVersionString"] as? String ?? "?",
            build: info["CFBundleVersion"] as? String ?? "?",
            bundleIdentifier: Bundle.main.bundleIdentifier ?? "?",
            systemVersion: ProcessInfo.processInfo.operatingSystemVersionString,
            hardwareModel: sysctlString("hw.model") ?? "?",
            generatedAt: now,
            sessionLines: (root.sessions?.sessions ?? []).map(line(for:)),
            databaseSummaries: [
                SQLiteDiagnostics.summary(path: CompositionRoot.libraryPath()),
                SQLiteDiagnostics.summary(path: CompositionRoot.trustStorePath()),
            ],
            terminalSettingsJSON: settings,
            logLines: currentProcessLogLines())
    }

    /// Only this process's entries are readable without an entitlement, so
    /// the bundle covers the current run.
    static func currentProcessLogLines() -> [String] {
        guard let store = try? OSLogStore(scope: .currentProcessIdentifier),
              let entries = try? store.getEntries(matching: NSPredicate(format: "subsystem == %@", logSubsystem)) else {
            return []
        }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return entries.compactMap { entry -> String? in
            guard let entry = entry as? OSLogEntryLog else { return nil }
            return "\(formatter.string(from: entry.date)) [\(entry.category)] \(name(of: entry.level)) \(entry.composedMessage)"
        }
    }

    private static func name(of level: OSLogEntryLog.Level) -> String {
        switch level {
        case .debug: "debug"
        case .info: "info"
        case .notice: "notice"
        case .error: "error"
        case .fault: "fault"
        default: "undefined"
        }
    }

    private static func sysctlString(_ name: String) -> String? {
        var size = 0
        guard sysctlbyname(name, nil, &size, nil, 0) == 0, size > 0 else { return nil }
        var buffer = [CChar](repeating: 0, count: size)
        guard sysctlbyname(name, &buffer, &size, nil, 0) == 0 else { return nil }
        return String(cString: buffer)
    }
}

private extension JSONEncoder {
    static var pretty: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return encoder
    }
}

/// Help › Save Support Bundle…: writes the bundle to a temporary folder,
/// zips it and copies the zip where the user chose.
@MainActor
enum SupportBundlePanel {
    static func save(root: CompositionRoot) {
        let bundle = SupportBundle.collect(root: root)
        let panel = NSSavePanel()
        panel.title = "Save Support Bundle"
        panel.nameFieldStringValue = "Constellation Support Bundle.zip"
        panel.allowedContentTypes = [.zip]
        panel.canCreateDirectories = true
        guard panel.runModal() == .OK, let destination = panel.url else { return }
        do {
            try write(bundle, to: destination)
        } catch {
            let alert = NSAlert()
            alert.messageText = "Couldn’t Save Support Bundle"
            alert.informativeText = error.localizedDescription
            alert.runModal()
        }
    }

    static func write(_ bundle: SupportBundle, to destination: URL) throws {
        let staging = FileManager.default.temporaryDirectory
            .appendingPathComponent("constellation-support-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: staging) }
        let folder = staging.appendingPathComponent("Constellation Support Bundle")
        try bundle.write(to: folder)

        var coordinationError: NSError?
        var copyError: Error?
        NSFileCoordinator().coordinate(readingItemAt: folder, options: .forUploading, error: &coordinationError) { zipURL in
            do {
                if FileManager.default.fileExists(atPath: destination.path) {
                    try FileManager.default.removeItem(at: destination)
                }
                try FileManager.default.copyItem(at: zipURL, to: destination)
            } catch {
                copyError = error
            }
        }
        if let coordinationError { throw coordinationError }
        if let copyError { throw copyError }
    }
}
