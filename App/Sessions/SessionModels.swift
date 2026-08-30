// SPDX-FileCopyrightText: 2026 Nick Wolff <nick@wolff.tech>
// SPDX-License-Identifier: GPL-3.0-only

import ConstellationCore
import ConstellationRemoteDesktop
import Foundation

enum SessionTarget: Hashable, Sendable {
    case local
    case saved(machineID: MachineID, profileID: ProfileID)
    case quick(QuickConnectTarget)
}

enum SessionKind: Equatable, Sendable {
    case localTerminal
    case connection(ConnectionProtocol)

    var displayName: String {
        switch self {
        case .localTerminal: "Local"
        case .connection(let connectionProtocol): connectionProtocol.displayName
        }
    }

    var symbolName: String {
        switch self {
        case .localTerminal: "terminal"
        case .connection(let connectionProtocol): connectionProtocol.symbolName
        }
    }

    var connectionProtocol: ConnectionProtocol? {
        if case .connection(let connectionProtocol) = self { connectionProtocol } else { nil }
    }
}

struct SessionEndpoint: Equatable, Sendable {
    var host: String
    var port: Int

    /// `vnc://user@host:port` for Apple's Screen Sharing app.
    func screenSharingURL(username: String?) -> URL? {
        var components = URLComponents()
        components.scheme = "vnc"
        components.host = host
        components.port = port
        if let username, !username.isEmpty { components.user = username }
        return components.url
    }
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
    case authenticationFailed(String)
    case remoteDesktop(String)
    case localShellExited(Int32)

    var errorDescription: String? {
        switch self {
        case .noAddress: "This machine has no address for the selected profile."
        case .unreachable: "None of this profile's addresses accepted a TCP connection."
        case .unsupportedProtocol(let kind): "\(kind.displayName) sessions arrive in a later milestone."
        case .launchFailed(let message): "The SSH session could not start. \(message)"
        case .sshExited(let code): "SSH exited with status \(code)."
        case .endedWithoutStatus: "SSH ended without reporting its exit status."
        case .authenticationFailed(let message): message
        case .remoteDesktop(let message): message
        case .localShellExited(let code): "The local shell exited with status \(code)."
        }
    }
}

enum SessionState: Equatable, Sendable {
    case disconnected
    case connecting(startedAt: ContinuousClock.Instant)
    case awaitingUserInput(SessionPrompt)
    case connected(ConnectionFacts)
    case running(startedAt: ContinuousClock.Instant)
    case disconnecting
    case failed(ConnectionFailure)

    var isConnected: Bool {
        if case .connected = self { true } else { false }
    }

    var hasLiveProcess: Bool {
        switch self {
        case .connecting, .awaitingUserInput, .connected, .running, .disconnecting: true
        case .disconnected, .failed: false
        }
    }

    var displayName: String {
        switch self {
        case .disconnected: "Disconnected"
        case .connecting: "Connecting"
        case .awaitingUserInput: "Waiting for input"
        case .connected: "Connected"
        case .running: "Running"
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
    /// The address the last attempt resolved to; also feeds the Screen Sharing handoff.
    var endpoint: SessionEndpoint?
    /// Remote desktop sessions only. `nil` until a session starts (the driver
    /// picks the default) or the user chooses one; a choice outlives reconnects.
    var displayMode: RemoteDesktopDisplayMode?
    /// A bell from a background terminal stays visible until the tab is selected.
    var needsAttention = false

    var machineID: MachineID? {
        guard case .saved(let machineID, _) = target else { return nil }
        return machineID
    }

    var profileID: ProfileID? {
        guard case .saved(_, let profileID) = target else { return nil }
        return profileID
    }

    /// A stable connection label. Terminal titles may change to the current
    /// directory, but a tab should continue to identify its machine.
    var tabTitle: String {
        switch target {
        case .local:
            "This Mac"
        case .saved:
            machineName ?? title
        case .quick(let target):
            target.displayName
        }
    }

    /// Known once the profile was loaded; Quick Connect is always SSH.
    var kind: SessionKind = .connection(.ssh)
    /// The profile's account name, for the Screen Sharing handoff.
    var username: String?
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
