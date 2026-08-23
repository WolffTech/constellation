import Testing
@testable import ConstellationOpenSSH

struct SSHDestinationTests {
    @Test func parsesUserHostAndPort() {
        #expect(SSHDestination(parsing: "temp@192.0.2.18:2222") == SSHDestination(host: "192.0.2.18", user: "temp", port: 2222))
        #expect(SSHDestination(parsing: "box.local") == SSHDestination(host: "box.local"))
        #expect(SSHDestination(parsing: "@box") == SSHDestination(host: "box"))
        #expect(SSHDestination(parsing: "") == nil)
    }
}

struct SSHLaunchTests {
    @Test func buildsSeparateArgumentsWithHostKeyAlias() {
        var launch = SSHLaunch(destination: SSHDestination(host: "192.0.2.18", user: "temp", port: 22), hostKeyAlias: "alpha")
        launch.identityFile = "/Users/example/.ssh/id_ed25519"
        launch.options = ["BatchMode=yes"]
        let command = launch.command(environment: ["SSH_ASKPASS_REQUIRE": "force"])
        #expect(command.executable == "/usr/bin/ssh")
        #expect(command.arguments == ["-o", "ConnectTimeout=10", "-o", "HostKeyAlias=alpha", "-i", "/Users/example/.ssh/id_ed25519", "-o", "IdentitiesOnly=yes", "-o", "BatchMode=yes", "-p", "22", "temp@192.0.2.18"])
        #expect(command.environment["SSH_ASKPASS_REQUIRE"] == "force")
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
