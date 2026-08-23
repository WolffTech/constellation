import ConstellationTerminal
import Observation

/// Builds the app's long-lived objects. Milestone 0 opens a single local shell;
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
            session = try runtime.makeSession(command: .localShell())
        } catch {
            startupError = "\(error)"
        }
    }
}
