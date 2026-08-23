import AppKit
import Foundation
import Testing
@testable import ConstellationTerminal

/// Milestone 0 proof against a disposable SSH target. Skipped unless
/// `CONSTELLATION_TEST_SSH_TARGET=user@host[:port]` is set. If
/// `CONSTELLATION_TEST_SSH_PASSWORD` is set it is typed at the password prompt;
/// otherwise the agent or default key must authenticate. An unknown host key
/// is accepted because the target is disposable.
@MainActor
struct SSHSessionTests {
    nonisolated private static var target: String? {
        let value = ProcessInfo.processInfo.environment["CONSTELLATION_TEST_SSH_TARGET"] ?? ""
        return value.isEmpty ? nil : value
    }

    @Test(.enabled(if: SSHSessionTests.target != nil, "set CONSTELLATION_TEST_SSH_TARGET"))
    func remoteShellRoundTripAndTeardown() throws {
        let target = try #require(Self.target)
        var arguments = ["-o", "ConnectTimeout=10"]
        var destination = target
        if let colon = target.lastIndex(of: ":"), let port = Int(target[target.index(after: colon)...]) {
            arguments += ["-p", String(port)]
            destination = String(target[..<colon])
        }
        arguments.append(destination)

        _ = NSApplication.shared
        let runtime = try GhosttyRuntime(appearance: .default)
        let session = try runtime.makeSession(command: TerminalCommand(executable: "/usr/bin/ssh", arguments: arguments))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 800, height: 500), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = session.view
        window.orderFrontRegardless()
        defer { window.close() }

        let password = ProcessInfo.processInfo.environment["CONSTELLATION_TEST_SSH_PASSWORD"] ?? ""
        var answeredHostKey = false
        var sentPassword = false
        let marker = "constellation-ssh-\(Int.random(in: 1000...9999))"
        var sentMarker = false

        let connected = waitUntil(.seconds(40)) {
            let screen = session.screenText()
            if !answeredHostKey, screen.contains("(yes/no") {
                answeredHostKey = true
                session.send(.text("yes\n"))
            }
            if !sentPassword, !password.isEmpty, screen.lowercased().contains("password:") {
                sentPassword = true
                session.send(.text(password + "\n"))
            }
            if !sentMarker, screen.contains("$") || screen.contains("#") || screen.contains(">") {
                // Something that looks like a prompt; ask the remote to identify itself.
                if !password.isEmpty && !sentPassword { return false }
                sentMarker = true
                session.send(.text("echo \(marker) && uname -s\n"))
            }
            return screen.contains("Linux") && screen.contains(marker)
        }
        #expect(connected, "screen was: \(session.screenText()) state=\(session.processState)")
        #expect(session.processState == .running)

        let pid = try #require(session.foregroundProcessID())
        session.close()
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
