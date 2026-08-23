import Foundation

/// A program to run inside a terminal surface.
///
/// libghostty's embedded API always hands the surface command to `/bin/sh -c`, so
/// `shellCommandLine` quotes every word; the shell then passes each one through
/// untouched. Secrets never belong here: arguments and environment are visible
/// to other processes.
public struct TerminalCommand: Sendable, Equatable {
    public var executable: String
    public var arguments: [String]
    public var environment: [String: String]
    public var workingDirectory: String?

    public init(
        executable: String,
        arguments: [String] = [],
        environment: [String: String] = [:],
        workingDirectory: String? = nil
    ) {
        self.executable = executable
        self.arguments = arguments
        self.environment = environment
        self.workingDirectory = workingDirectory
    }

    /// The user's login shell as an interactive login session.
    public static func localShell() -> TerminalCommand {
        let shell = ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh"
        return TerminalCommand(
            executable: shell,
            arguments: ["-l"],
            workingDirectory: FileManager.default.homeDirectoryForCurrentUser.path
        )
    }

    /// POSIX-quoted command line safe to pass to `/bin/sh -c`.
    public var shellCommandLine: String {
        ([executable] + arguments).map(Self.shellQuote).joined(separator: " ")
    }

    /// Single-quotes `word`, escaping embedded single quotes as `'\''`.
    static func shellQuote(_ word: String) -> String {
        "'" + word.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}
