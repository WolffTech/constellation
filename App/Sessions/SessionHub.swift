import ConstellationCore
import ConstellationOpenSSH
import ConstellationTerminal
import Foundation
import Observation

/// Live terminal sessions, one per machine for now. Milestone 2 replaces
/// this with the Session Coordinator and tabs.
@MainActor
@Observable
final class SessionHub {
    struct ActiveSession: Identifiable {
        let id: MachineID
        let profile: ConnectionProfile
        let session: GhosttyTerminalSession
        let askPassToken: String
    }

    private(set) var sessions: [MachineID: ActiveSession] = [:]
    var presentedError: String?

    private let runtime: GhosttyRuntime
    private let askPass: AskPassService

    init(runtime: GhosttyRuntime, askPass: AskPassService) {
        self.runtime = runtime
        self.askPass = askPass
    }

    func session(for machineID: MachineID) -> ActiveSession? {
        sessions[machineID]
    }

    func connect(_ profile: ConnectionProfile, machine: Machine, snapshot: MachineLibrarySnapshot) {
        guard case .ssh(let ssh) = profile else {
            presentedError = "\(profile.protocolKind.displayName) sessions arrive in a later milestone."
            return
        }
        guard let address = Self.address(for: profile, machine: machine, snapshot: snapshot) else {
            presentedError = "“\(machine.name)” has no address to connect to."
            return
        }
        disconnect(machine.id)

        var launch = SSHLaunch(
            destination: SSHDestination(host: address.host, user: ssh.username, port: ssh.port),
            // One known_hosts entry per machine, whichever address is used.
            hostKeyAlias: "constellation-\(machine.id)")
        switch ssh.authentication {
        case .agent:
            break
        case .keyFile(let path):
            launch.identityFile = path
        case .password:
            launch.options = ["PubkeyAuthentication=no", "PreferredAuthentications=keyboard-interactive,password"]
        }

        let token = askPass.registerLaunch()
        guard let helper = Bundle.main.url(forAuxiliaryExecutable: "constellation-askpass")?.path else {
            presentedError = "The bundled constellation-askpass helper is missing."
            askPass.endLaunch(token: token)
            return
        }
        let environment = askPass.environment(token: token, credentialID: ssh.credentialID?.description, helperPath: helper)
        do {
            let session = try runtime.makeSession(command: launch.command(environment: environment))
            sessions[machine.id] = ActiveSession(id: machine.id, profile: profile, session: session, askPassToken: token)
        } catch {
            askPass.endLaunch(token: token)
            presentedError = error.localizedDescription
        }
    }

    func disconnect(_ machineID: MachineID) {
        guard let active = sessions.removeValue(forKey: machineID) else { return }
        active.session.close()
        askPass.endLaunch(token: active.askPassToken)
    }

    var connectedCount: Int {
        sessions.values.filter { $0.session.processState == .running }.count
    }

    /// Pinned address if the profile has one, else the machine's first by priority.
    /// Reachability probing arrives with the Session Coordinator.
    private static func address(for profile: ConnectionProfile, machine: Machine, snapshot: MachineLibrarySnapshot) -> MachineAddress? {
        let addresses = snapshot.addresses(for: machine.id)
        if case .pinned(let id) = profile.addressSelection, let pinned = addresses.first(where: { $0.id == id }) {
            return pinned
        }
        return addresses.first
    }
}
