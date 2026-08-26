// SPDX-FileCopyrightText: 2026 Nick Wolff <nick@wolff.tech>
// SPDX-License-Identifier: GPL-3.0-only

import AppKit
import Foundation
import Testing
@testable import ConstellationOpenSSH

private final class BundleMarker {}

/// Locates the built `constellation-askpass` next to the test bundle.
func askPassHelperPath() -> String? {
    if let override = ProcessInfo.processInfo.environment["CONSTELLATION_ASKPASS_PATH"], !override.isEmpty {
        return override
    }
    var directory = Bundle(for: BundleMarker.self).bundleURL.deletingLastPathComponent()
    for _ in 0..<3 {
        let candidate = directory.appendingPathComponent("constellation-askpass")
        if FileManager.default.isExecutableFile(atPath: candidate.path) { return candidate.path }
        directory.deleteLastPathComponent()
    }
    return nil
}

/// Runs the real helper binary against an in-process `AskPassService`, the way
/// ssh would, and returns its stdout and exit status.
@MainActor
func runHelper(environment: [String: String], prompt: String) throws -> (output: String, status: Int32) {
    let path = try #require(askPassHelperPath(), "constellation-askpass not built")
    let process = Process()
    process.executableURL = URL(fileURLWithPath: path)
    process.arguments = [prompt]
    process.environment = environment
    let pipe = Pipe()
    process.standardOutput = pipe
    try process.run()
    // The service answers on the main run loop, so keep it spinning while the helper waits.
    while process.isRunning {
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.02))
    }
    let output = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
    return (output, process.terminationStatus)
}

@MainActor
struct AskPassHelperTests {
    @Test func helperReturnsVaultSecretForLiveToken() throws {
        let service = try AskPassService(secrets: InMemorySecretProvider(["cred-1": "hunter2"])) { _ in .denied }
        let token = service.registerLaunch()
        let env = service.environment(token: token, credentialID: "cred-1", helperPath: "/unused")
        let result = try runHelper(environment: env, prompt: "user@host's password: ")
        #expect(result.status == 0)
        #expect(result.output == "hunter2\n")
    }

    @Test func helperRoutesConfirmPromptsToTheUser() throws {
        nonisolated(unsafe) var seenPrompt: String?
        let service = try AskPassService(secrets: InMemorySecretProvider([:])) { request in
            seenPrompt = request.prompt
            return .confirmed(request.kind == .confirm)
        }
        let token = service.registerLaunch()
        var env = service.environment(token: token, credentialID: nil, helperPath: "/unused")
        env["SSH_ASKPASS_PROMPT"] = "confirm"
        let result = try runHelper(environment: env, prompt: "Are you sure you want to continue connecting (yes/no/[fingerprint])?")
        #expect(result.output == "yes\n")
        #expect(seenPrompt?.contains("continue connecting") == true)
    }

    @Test func helperIsDeniedWithoutALiveToken() throws {
        let service = try AskPassService(secrets: InMemorySecretProvider(["cred-1": "hunter2"])) { _ in .secret("leak") }
        let token = service.registerLaunch()
        service.endLaunch(token: token)
        let env = service.environment(token: token, credentialID: "cred-1", helperPath: "/unused")
        let result = try runHelper(environment: env, prompt: "password: ")
        #expect(result.status != 0)
        #expect(result.output.isEmpty)
    }
}
