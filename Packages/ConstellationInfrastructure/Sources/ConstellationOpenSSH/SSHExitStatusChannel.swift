import ConstellationTerminal
import Foundation

/// Carries ssh's real exit status through a terminal-title escape sequence.
/// libghostty's macOS `login` wrapper otherwise reports every exit as zero.
public struct SSHExitStatusChannel: Hashable, Sendable {
    public let token: String

    public init(token: String = UUID().uuidString) {
        self.token = token
    }

    public func wrapping(_ command: TerminalCommand) -> TerminalCommand {
        let marker = "constellation-exit:\(token):"
        let script = """
            \(command.shellCommandLine)
            status=$?
            printf '\\033]2;\(marker)%s\\007' "$status"
            exit "$status"
            """
        return TerminalCommand(
            executable: "/bin/sh",
            arguments: ["-c", script],
            environment: command.environment,
            workingDirectory: command.workingDirectory)
    }

    /// An OpenSSH `LocalCommand` that emits a title only after SSH connects.
    public var connectionOptions: [String] {
        [
            "PermitLocalCommand=yes",
            "LocalCommand=printf '\\033]2;constellation-connected:\(token)\\007'",
        ]
    }

    public func isConnectionTitle(_ title: String) -> Bool {
        title == "constellation-connected:\(token)"
    }

    public func exitStatus(fromTitle title: String) -> Int32? {
        let prefix = "constellation-exit:\(token):"
        guard title.hasPrefix(prefix),
              let value = Int32(title.dropFirst(prefix.count)),
              (0...255).contains(value) else { return nil }
        return value
    }
}
