// SPDX-FileCopyrightText: 2026 Nick Wolff <nick@wolff.tech>
// SPDX-License-Identifier: GPL-3.0-only

import AppKit
import Foundation
import Testing
import ConstellationTerminal
@testable import ConstellationOpenSSH

struct SSHDestinationTests {
    @Test func parsesUserHostAndPort() {
        #expect(SSHDestination(parsing: "temp@192.0.2.18:2222") == SSHDestination(host: "192.0.2.18", user: "temp", port: 2222))
        #expect(SSHDestination(parsing: "box.local") == SSHDestination(host: "box.local"))
        #expect(SSHDestination(parsing: "@box") == SSHDestination(host: "box"))
        #expect(SSHDestination(parsing: "") == nil)
    }
}

@MainActor
struct SSHExitStatusSurfaceTests {
    @Test func titleChannelCarriesTheRealStatusThroughLogin() throws {
        _ = NSApplication.shared
        let channel = SSHExitStatusChannel(token: "surface-test")
        let runtime = try GhosttyRuntime(appearance: .default)
        let command = channel.wrapping(TerminalCommand(executable: "/bin/sh", arguments: ["-c", "exit 7"]))
        let session = try runtime.makeSession(command: command)
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 640, height: 400),
            styleMask: [.titled],
            backing: .buffered,
            defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = session.view
        window.orderFrontRegardless()
        defer { session.close(); window.close() }

        var reportedStatus: Int32?
        session.eventHandler = { event in
            guard case .titleChanged(let title) = event else { return }
            reportedStatus = channel.exitStatus(fromTitle: title)
        }

        #expect(waitUntil { reportedStatus != nil && session.processState != .running })
        #expect(reportedStatus == 7)
        #expect(session.processState == .exited(code: 0), "libghostty's login wrapper should still demonstrate why the side channel is needed")
    }

    private func waitUntil(_ condition: () -> Bool) -> Bool {
        let deadline = ContinuousClock.now + .seconds(10)
        while ContinuousClock.now < deadline {
            if condition() { return true }
            RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.05))
        }
        return condition()
    }
}

struct SSHLaunchTests {
    @Test func buildsSeparateArgumentsWithHostKeyAlias() {
        var launch = SSHLaunch(destination: SSHDestination(host: "192.0.2.18", user: "temp", port: 22), hostKeyAlias: "alpha")
        launch.identityFile = "/Users/example/.ssh/id_ed25519"
        launch.options = ["BatchMode=yes"]
        let command = launch.command(environment: ["SSH_ASKPASS_REQUIRE": "force"])
        #expect(command.executable == "/usr/bin/ssh")
        #expect(command.arguments == ["-o", "ConnectTimeout=10", "-o", "HostKeyAlias=alpha", "-i", "/Users/example/.ssh/id_ed25519", "-o", "IdentitiesOnly=yes", "-o", "BatchMode=yes", "-p", "22", "-l", "temp", "192.0.2.18"])
        #expect(command.environment["SSH_ASKPASS_REQUIRE"] == "force")
    }

    @Test func stripsIPv6BracketsBeforeLaunching() {
        let command = SSHLaunch(destination: SSHDestination(host: "[fe80::1]", user: "nick")).command()
        #expect(Array(command.arguments.suffix(3)) == ["-l", "nick", "fe80::1"])
    }

    @Test func exitStatusChannelWrapsTheCommandWithoutChangingItsEnvironment() {
        let channel = SSHExitStatusChannel(token: "test-token")
        let command = TerminalCommand(
            executable: "/usr/bin/ssh",
            arguments: ["nick@box"],
            environment: ["SSH_ASKPASS_REQUIRE": "force"])
        let wrapped = channel.wrapping(command)

        #expect(wrapped.executable == "/bin/sh")
        #expect(wrapped.environment == command.environment)
        #expect(wrapped.arguments.count == 2)
        #expect(wrapped.arguments[1].contains(command.shellCommandLine))
        #expect(wrapped.arguments[1].contains("constellation-exit:test-token"))
        #expect(channel.connectionOptions == [
            "PermitLocalCommand=yes",
            "LocalCommand=printf '\\033]2;constellation-connected:test-token\\007'",
        ])
        #expect(channel.isConnectionTitle("constellation-connected:test-token"))
        #expect(!channel.isConnectionTitle("constellation-connected:wrong"))
        #expect(channel.exitStatus(fromTitle: "constellation-exit:test-token:255") == 255)
        #expect(channel.exitStatus(fromTitle: "constellation-exit:wrong:1") == nil)
        #expect(channel.exitStatus(fromTitle: "normal shell title") == nil)
    }
}

struct AskPassProtocolTests {
    @Test func promptVariableWins() {
        #expect(AskPass.promptKind(sshPromptVariable: "confirm", promptText: "password: ") == .confirm)
        #expect(AskPass.promptKind(sshPromptVariable: "none", promptText: "password: ") == .none)
    }

    @Test func hostKeyQuestionsAreConfirmationsEvenWithoutTheVariable() {
        #expect(AskPass.promptKind(sshPromptVariable: nil, promptText: "The authenticity of host 'x' can't be established.\nAre you sure you want to continue connecting (yes/no/[fingerprint])? ") == .confirm)
        #expect(AskPass.promptKind(sshPromptVariable: nil, promptText: "Please type 'yes', 'no' or the fingerprint: ") == .confirm)
    }

    @Test func onlyPasswordAndPassphrasePromptsAreSecrets() {
        #expect(AskPass.promptKind(sshPromptVariable: nil, promptText: "temp@192.0.2.18's password: ") == .secret)
        #expect(AskPass.promptKind(sshPromptVariable: nil, promptText: "Enter passphrase for key '/Users/x/.ssh/id_ed25519': ") == .secret)
        #expect(AskPass.promptKind(sshPromptVariable: nil, promptText: "Something unexpected? ") == .confirm)
    }

    @Test func responsesMapToSSHOutput() {
        #expect(AskPass.Response.secret("hunter2").sshOutput == "hunter2")
        #expect(AskPass.Response.confirmed(true).sshOutput == "yes")
        #expect(AskPass.Response.confirmed(false).sshOutput == "no")
        #expect(AskPass.Response.denied.sshOutput == nil)
    }
}
