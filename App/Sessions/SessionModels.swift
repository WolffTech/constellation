import ConstellationCore
import Foundation

enum SessionTarget: Hashable, Sendable {
    case saved(machineID: MachineID, profileID: ProfileID)
    case quick(QuickConnectTarget)
}

struct ConnectionFacts: Equatable, Sendable {
    var host: String
    var port: Int
    var connectedAt: Date
}

struct SessionPrompt: Equatable, Sendable {
    var message: String
}

enum ConnectionFailure: Error, Equatable, Sendable, LocalizedError {
    case noAddress
    case unreachable
    case unsupportedProtocol(ConnectionProtocol)
    case launchFailed(String)
    case sshExited(Int32)
    case endedWithoutStatus

    var errorDescription: String? {
        switch self {
        case .noAddress: "This machine has no address for the selected profile."
        case .unreachable: "None of this profile's addresses accepted a TCP connection."
        case .unsupportedProtocol(let kind): "\(kind.displayName) sessions arrive in a later milestone."
        case .launchFailed(let message): "The SSH session could not start. \(message)"
        case .sshExited(let code): "SSH exited with status \(code)."
        case .endedWithoutStatus: "SSH ended without reporting its exit status."
        }
    }
}

enum SessionState: Equatable, Sendable {
    case disconnected
    case connecting(startedAt: ContinuousClock.Instant)
    case awaitingUserInput(SessionPrompt)
    case connected(ConnectionFacts)
    case disconnecting
    case failed(ConnectionFailure)

    var isConnected: Bool {
        if case .connected = self { true } else { false }
    }

    var hasLiveProcess: Bool {
        switch self {
        case .connecting, .awaitingUserInput, .connected, .disconnecting: true
        case .disconnected, .failed: false
        }
    }

    var displayName: String {
        switch self {
        case .disconnected: "Disconnected"
        case .connecting: "Connecting"
        case .awaitingUserInput: "Waiting for input"
        case .connected: "Connected"
        case .disconnecting: "Disconnecting"
        case .failed: "Failed"
        }
    }
}

struct SessionSummary: Identifiable, Equatable, Sendable {
    let id: SessionID
    var target: SessionTarget
    var title: String
    var machineName: String?
    var profileName: String
    var state: SessionState

    var machineID: MachineID? {
        guard case .saved(let machineID, _) = target else { return nil }
        return machineID
    }

    var profileID: ProfileID? {
        guard case .saved(_, let profileID) = target else { return nil }
        return profileID
    }
}

/// A close the user must confirm because a live process would be cut.
enum CloseRequest: Equatable, Sendable {
    case session(SessionID)
    case others(keeping: SessionID)
}

/// An error shown to the user with the operation that failed as its title.
struct PresentedError: Equatable, Sendable {
    var title: String
    var message: String
}

enum SessionCoordinatorError: Error, Equatable, LocalizedError {
    case unknownProfile(ProfileID)
    case unknownMachine(MachineID)
    case unknownSession(SessionID)
    case notQuickConnect(SessionID)
    case noProfiles(MachineID)

    var errorDescription: String? {
        switch self {
        case .unknownProfile: "That connection profile no longer exists."
        case .unknownMachine: "That machine no longer exists."
        case .unknownSession: "That session tab no longer exists."
        case .notQuickConnect: "Only a Quick Connect tab can be saved as a machine."
        case .noProfiles: "This machine has no connection profile. Edit it to add one."
        }
    }
}
