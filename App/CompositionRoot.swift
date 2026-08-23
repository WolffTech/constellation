import ConstellationTerminal
import Foundation
import Observation

/// Builds the app's long-lived objects. Milestone 0 opens a single terminal;
/// the Session Coordinator replaces this in Milestone 2.
@MainActor
@Observable
final class CompositionRoot {
    private(set) var runtime: GhosttyRuntime?
    private(set) var session: GhosttyTerminalSession?
    private(set) var startupError: String?

    init() {
        do {
            let runtime = try GhosttyRuntime(appearance: .default)
            self.runtime = runtime
            session = try runtime.makeSession(command: Self.initialCommand())
        } catch {
            startupError = "\(error)"
        }
    }

    /// Development hook for the Milestone 0 SSH proof: `CONSTELLATION_SSH=user@host[:port]`
    /// opens ssh instead of the local shell. Removed once saved machines exist.
    private static func initialCommand() -> TerminalCommand {
        guard let target = ProcessInfo.processInfo.environment["CONSTELLATION_SSH"], !target.isEmpty else {
            return .localShell()
        }
        var arguments: [String] = []
        var destination = target
        if let colon = target.lastIndex(of: ":"), let port = Int(target[target.index(after: colon)...]) {
            arguments += ["-p", String(port)]
            destination = String(target[..<colon])
        }
        arguments.append(destination)
        return TerminalCommand(executable: "/usr/bin/ssh", arguments: arguments)
    }
}
