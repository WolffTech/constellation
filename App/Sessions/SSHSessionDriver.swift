import ConstellationCore
import ConstellationOpenSSH
import ConstellationTerminal
import Foundation

struct SSHSessionRequest: Equatable, Sendable {
    var destination: SSHDestination
    var hostKeyAlias: String?
    var authentication: SSHAuthentication
    var credentialID: CredentialID?
}

@MainActor
final class SSHDriverSession {
    let terminal: any TerminalSession
    let exitStatusChannel: SSHExitStatusChannel

    private var didFinish = false
    private let finishHandler: @MainActor () -> Void

    init(
        terminal: any TerminalSession,
        exitStatusChannel: SSHExitStatusChannel,
        finishHandler: @escaping @MainActor () -> Void = {}
    ) {
        self.terminal = terminal
        self.exitStatusChannel = exitStatusChannel
        self.finishHandler = finishHandler
    }

    func finish() {
        guard !didFinish else { return }
        didFinish = true
        finishHandler()
    }

    func close() {
        terminal.close()
        finish()
    }
}

@MainActor
protocol SSHSessionDriving: AnyObject {
    func start(_ request: SSHSessionRequest) throws -> SSHDriverSession
}

@MainActor
final class GhosttySSHSessionDriver: SSHSessionDriving {
    private let runtime: GhosttyRuntime
    private let askPass: AskPassService

    init(runtime: GhosttyRuntime, askPass: AskPassService) {
        self.runtime = runtime
        self.askPass = askPass
    }

    func start(_ request: SSHSessionRequest) throws -> SSHDriverSession {
        var launch = SSHLaunch(destination: request.destination, hostKeyAlias: request.hostKeyAlias)
        switch request.authentication {
        case .agent:
            break
        case .keyFile(let path):
            launch.identityFile = path
        case .password:
            launch.options = ["PubkeyAuthentication=no", "PreferredAuthentications=keyboard-interactive,password"]
        }

        guard let helper = Bundle.main.url(forAuxiliaryExecutable: "constellation-askpass")?.path else {
            throw DriverError.missingAskPassHelper
        }
        let askPassToken = askPass.registerLaunch()
        let environment = askPass.environment(
            token: askPassToken,
            credentialID: request.credentialID?.description,
            helperPath: helper)
        let channel = SSHExitStatusChannel()
        launch.options.append(contentsOf: channel.connectionOptions)
        do {
            let command = channel.wrapping(launch.command(environment: environment))
            let terminal = try runtime.makeSession(command: command)
            return SSHDriverSession(terminal: terminal, exitStatusChannel: channel) { [askPass] in
                askPass.endLaunch(token: askPassToken)
            }
        } catch {
            askPass.endLaunch(token: askPassToken)
            throw error
        }
    }

    enum DriverError: Error, LocalizedError {
        case missingAskPassHelper

        var errorDescription: String? {
            "The bundled constellation-askpass helper is missing."
        }
    }
}
