import AppKit
import ConstellationTerminal
import Foundation
import Testing
@testable import ConstellationOpenSSH

/// Milestone 0 AskPass proof: ssh to a disposable target with the host key
/// confirmation and the password both answered through `constellation-askpass`,
/// never through the terminal. Needs `CONSTELLATION_TEST_SSH_TARGET` and
/// `CONSTELLATION_TEST_SSH_PASSWORD`.
@MainActor
struct SSHAskPassIntegrationTests {
    nonisolated private static var target: String? {
        let value = ProcessInfo.processInfo.environment["CONSTELLATION_TEST_SSH_TARGET"] ?? ""
        return value.isEmpty ? nil : value
    }

    @Test(.enabled(if: SSHAskPassIntegrationTests.target != nil, "set CONSTELLATION_TEST_SSH_TARGET"))
    func hostKeyAndPasswordGoThroughAskPass() throws {
        let target = try #require(Self.target)
        let destination = try #require(SSHDestination(parsing: target))
        let password = ProcessInfo.processInfo.environment["CONSTELLATION_TEST_SSH_PASSWORD"] ?? ""
        let helper = try #require(askPassHelperPath())

        nonisolated(unsafe) var prompts: [AskPass.Request] = []
        let service = try AskPassService(secrets: InMemorySecretProvider(["target": password])) { request in
            prompts.append(request)
            return request.kind == .confirm ? .confirmed(true) : .denied
        }
        let token = service.registerLaunch()
        defer { service.endLaunch(token: token) }

        // A fresh known_hosts file forces the unknown-host confirmation.
        let knownHosts = FileManager.default.temporaryDirectory.appendingPathComponent("constellation-known-hosts-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: knownHosts) }
        var launch = SSHLaunch(destination: destination, hostKeyAlias: "constellation-test")
        launch.options = ["UserKnownHostsFile=\(knownHosts.path)", "PreferredAuthentications=password", "PubkeyAuthentication=no"]
        let command = launch.command(environment: service.environment(token: token, credentialID: "target", helperPath: helper))

        _ = NSApplication.shared
        let runtime = try GhosttyRuntime(appearance: .default)
        let session = try runtime.makeSession(command: command)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 800, height: 500), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = session.view
        window.orderFrontRegardless()
        defer { session.close(); window.close() }

        let marker = "constellation-askpass-\(Int.random(in: 1000...9999))"
        var sentMarker = false
        let connected = waitUntil(.seconds(40)) {
            let screen = session.screenText()
            if !sentMarker, screen.contains("$ ") {
                sentMarker = true
                session.send(.text("echo \(marker)\n"))
            }
            return screen.contains(marker)
        }
        let screen = session.screenText()
        #expect(connected, "screen was: \(screen) state=\(session.processState)")
        #expect(!screen.contains("password:"), "ssh prompted in the terminal instead of askpass")
        #expect(prompts.contains { $0.kind == .confirm }, "no host-key confirmation reached askpass: \(prompts)")
        #expect(prompts.allSatisfy { $0.kind != .secret }, "vault-backed secret should not reach the user prompt")
        let knownHostsContents = (try? String(contentsOf: knownHosts, encoding: .utf8)) ?? ""
        #expect(knownHostsContents.contains("constellation-test"), "HostKeyAlias entry missing: \(knownHostsContents)")
    }

    private func waitUntil(_ timeout: Duration, _ condition: () -> Bool) -> Bool {
        let deadline = ContinuousClock.now + timeout
        while ContinuousClock.now < deadline {
            if condition() { return true }
            RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.1))
        }
        return condition()
    }
}
