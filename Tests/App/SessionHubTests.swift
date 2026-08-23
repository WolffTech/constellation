import AppKit
import ConstellationCore
import ConstellationOpenSSH
import ConstellationTerminal
import Foundation
import Testing
@testable import Constellation

/// Connects through the real app bundle (helper included) to the disposable
/// target. Needs `CONSTELLATION_TEST_SSH_TARGET` and `_PASSWORD`.
@MainActor
struct SessionHubTests {
    nonisolated private static var target: SSHDestination? {
        SSHDestination(parsing: ProcessInfo.processInfo.environment["CONSTELLATION_TEST_SSH_TARGET"] ?? "")
    }

    @Test(.enabled(if: SessionHubTests.target != nil, "set CONSTELLATION_TEST_SSH_TARGET"))
    func connectsWithAVaultPasswordAndDisconnects() async throws {
        let target = try #require(Self.target)
        let password = ProcessInfo.processInfo.environment["CONSTELLATION_TEST_SSH_PASSWORD"] ?? ""

        let vault = InMemoryCredentialVault()
        let credential = CredentialReference(label: "test", kind: .password)
        try vault.store(Secret(password), for: credential.id)
        let machine = Machine(name: "target")
        let address = MachineAddress(machineID: machine.id, label: "LAN", host: target.host)
        let profile = SSHProfile(machineID: machine.id, username: target.user, port: target.port ?? 22, authentication: .password, credentialID: credential.id)
        let snapshot = MachineLibrarySnapshot(machines: [machine], addresses: [address], profiles: [.ssh(profile)], credentials: [credential])

        let runtime = try GhosttyRuntime(appearance: .default)
        let askPass = try AskPassService(secrets: VaultSecretProvider(vault: vault)) { request in
            request.kind == .confirm ? .confirmed(true) : .denied
        }
        let hub = SessionHub(runtime: runtime, askPass: askPass)

        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 800, height: 500), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }

        hub.connect(.ssh(profile), machine: machine, snapshot: snapshot)
        #expect(hub.presentedError == nil, Comment(rawValue: hub.presentedError ?? ""))
        let active = try #require(hub.session(for: machine.id))
        window.contentView = active.session.view
        window.orderFrontRegardless()

        var sentMarker = false
        let connected = waitUntil(.seconds(40)) {
            let screen = active.session.screenText()
            if !sentMarker, screen.contains("$ ") {
                sentMarker = true
                active.session.send(.text("echo hub-ok\n"))
            }
            return screen.contains("hub-ok")
        }
        #expect(connected, "screen was: \(active.session.screenText()) state=\(active.session.processState)")
        #expect(!active.session.screenText().contains("password:"))
        #expect(hub.connectedCount == 1)

        let pid = try #require(active.session.foregroundProcessID())
        hub.disconnect(machine.id)
        #expect(hub.session(for: machine.id) == nil)
        #expect(waitUntil(.seconds(5)) { kill(pid, 0) == -1 && errno == ESRCH })
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
