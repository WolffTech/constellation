import AppKit
import ConstellationOpenSSH
import ConstellationTerminal
import Foundation
import Observation

/// Builds the app's long-lived objects. Milestone 0 opens a single terminal;
/// the Session Coordinator replaces this in Milestone 2.
@MainActor
@Observable
final class CompositionRoot {
    private(set) var runtime: GhosttyRuntime?
    private(set) var askPass: AskPassService?
    private(set) var session: GhosttyTerminalSession?
    private(set) var startupError: String?

    init() {
        do {
            let runtime = try GhosttyRuntime(appearance: .default)
            self.runtime = runtime
            // No vault until Milestone 1: every ssh prompt goes to the user.
            let askPass = try AskPassService(secrets: InMemorySecretProvider([:])) { request in
                AskPassPrompter.ask(request)
            }
            self.askPass = askPass
            session = try runtime.makeSession(command: initialCommand(askPass: askPass))
        } catch {
            startupError = "\(error)"
        }
    }

    /// Development hook for the Milestone 0 SSH proof: `CONSTELLATION_SSH=user@host[:port]`
    /// opens ssh instead of the local shell. Removed once saved machines exist.
    private func initialCommand(askPass: AskPassService) -> TerminalCommand {
        guard let text = ProcessInfo.processInfo.environment["CONSTELLATION_SSH"],
              let destination = SSHDestination(parsing: text) else {
            return .localShell()
        }
        let token = askPass.registerLaunch()
        guard let helper = Bundle.main.url(forAuxiliaryExecutable: "constellation-askpass")?.path else {
            return SSHLaunch(destination: destination).command()
        }
        let environment = askPass.environment(token: token, credentialID: nil, helperPath: helper)
        return SSHLaunch(destination: destination).command(environment: environment)
    }
}

/// Native dialogs for ssh prompts the vault cannot answer.
@MainActor
enum AskPassPrompter {
    static func ask(_ request: AskPass.Request) -> AskPass.Response {
        let alert = NSAlert()
        alert.messageText = request.kind == .confirm ? "SSH needs confirmation" : "SSH needs a secret"
        alert.informativeText = request.prompt
        switch request.kind {
        case .confirm:
            alert.addButton(withTitle: "Yes")
            alert.addButton(withTitle: "No")
            return .confirmed(alert.runModal() == .alertFirstButtonReturn)
        case .secret:
            let field = NSSecureTextField(frame: NSRect(x: 0, y: 0, width: 260, height: 24))
            alert.accessoryView = field
            alert.addButton(withTitle: "OK")
            alert.addButton(withTitle: "Cancel")
            alert.window.initialFirstResponder = field
            guard alert.runModal() == .alertFirstButtonReturn else { return .denied }
            return .secret(field.stringValue)
        case .none:
            alert.addButton(withTitle: "OK")
            alert.runModal()
            return .confirmed(true)
        }
    }
}
