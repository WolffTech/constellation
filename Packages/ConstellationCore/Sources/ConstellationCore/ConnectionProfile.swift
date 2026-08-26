// SPDX-FileCopyrightText: 2026 Nick Wolff <nick@wolff.tech>
// SPDX-License-Identifier: GPL-3.0-only

import Foundation

public enum ConnectionProtocol: String, Hashable, Sendable, Codable, CaseIterable {
    case ssh
    case vnc
    case rdp
    case appleScreenSharing

    public var displayName: String {
        switch self {
        case .ssh: "SSH"
        case .vnc: "VNC"
        case .rdp: "RDP"
        case .appleScreenSharing: "Screen Sharing"
        }
    }

    public var defaultPort: Int {
        switch self {
        case .ssh: 22
        case .vnc, .appleScreenSharing: 5900
        case .rdp: 3389
        }
    }
}

/// Which of a machine's addresses a profile connects to.
public enum AddressSelection: Hashable, Sendable, Codable {
    /// Try the machine's addresses in priority order.
    case automatic
    case pinned(AddressID)
}

public enum SSHAuthentication: Hashable, Sendable, Codable {
    case agent
    case keyFile(path: String)
    case password

    public var displayName: String {
        switch self {
        case .agent: "SSH agent"
        case .keyFile: "Key file"
        case .password: "Password"
        }
    }
}

/// A label for a Keychain item. The secret itself never lives in the library.
public struct CredentialReference: Identifiable, Hashable, Sendable, Codable {
    public let id: CredentialID
    public var label: String
    public var kind: CredentialKind

    public init(id: CredentialID = CredentialID(), label: String, kind: CredentialKind) {
        self.id = id
        self.label = label
        self.kind = kind
    }
}

public enum CredentialKind: String, Hashable, Sendable, Codable, CaseIterable {
    case password
    case passphrase

    public var displayName: String {
        switch self {
        case .password: "Password"
        case .passphrase: "Key passphrase"
        }
    }
}

public struct SSHProfile: Identifiable, Hashable, Sendable, Codable {
    public let id: ProfileID
    public let machineID: MachineID
    public var name: String
    public var username: String?
    public var port: Int
    public var addressSelection: AddressSelection
    public var authentication: SSHAuthentication
    /// The password for `.password`, or the key passphrase for `.keyFile`.
    public var credentialID: CredentialID?

    public init(
        id: ProfileID = ProfileID(),
        machineID: MachineID,
        name: String = "SSH",
        username: String? = nil,
        port: Int = 22,
        addressSelection: AddressSelection = .automatic,
        authentication: SSHAuthentication = .agent,
        credentialID: CredentialID? = nil
    ) {
        self.id = id
        self.machineID = machineID
        self.name = name
        self.username = username
        self.port = port
        self.addressSelection = addressSelection
        self.authentication = authentication
        self.credentialID = credentialID
    }
}

public struct VNCProfile: Identifiable, Hashable, Sendable, Codable {
    public let id: ProfileID
    public let machineID: MachineID
    public var name: String
    public var username: String?
    public var port: Int
    public var addressSelection: AddressSelection
    public var credentialID: CredentialID?
    public var sharesClipboard: Bool

    public init(
        id: ProfileID = ProfileID(),
        machineID: MachineID,
        name: String = "VNC",
        username: String? = nil,
        port: Int = 5900,
        addressSelection: AddressSelection = .automatic,
        credentialID: CredentialID? = nil,
        sharesClipboard: Bool = false
    ) {
        self.id = id
        self.machineID = machineID
        self.name = name
        self.username = username
        self.port = port
        self.addressSelection = addressSelection
        self.credentialID = credentialID
        self.sharesClipboard = sharesClipboard
    }
}

public struct RDPProfile: Identifiable, Hashable, Sendable, Codable {
    public let id: ProfileID
    public let machineID: MachineID
    public var name: String
    public var username: String?
    public var domain: String?
    public var port: Int
    public var addressSelection: AddressSelection
    public var credentialID: CredentialID?
    public var sharesClipboard: Bool

    public init(
        id: ProfileID = ProfileID(),
        machineID: MachineID,
        name: String = "RDP",
        username: String? = nil,
        domain: String? = nil,
        port: Int = 3389,
        addressSelection: AddressSelection = .automatic,
        credentialID: CredentialID? = nil,
        sharesClipboard: Bool = false
    ) {
        self.id = id
        self.machineID = machineID
        self.name = name
        self.username = username
        self.domain = domain
        self.port = port
        self.addressSelection = addressSelection
        self.credentialID = credentialID
        self.sharesClipboard = sharesClipboard
    }
}

/// Hands off to Apple's Screen Sharing app; no settings beyond the address.
public struct ScreenSharingProfile: Identifiable, Hashable, Sendable, Codable {
    public let id: ProfileID
    public let machineID: MachineID
    public var name: String
    public var addressSelection: AddressSelection

    public init(
        id: ProfileID = ProfileID(),
        machineID: MachineID,
        name: String = "Screen Sharing",
        addressSelection: AddressSelection = .automatic
    ) {
        self.id = id
        self.machineID = machineID
        self.name = name
        self.addressSelection = addressSelection
    }
}

public enum ConnectionProfile: Identifiable, Hashable, Sendable, Codable {
    case ssh(SSHProfile)
    case vnc(VNCProfile)
    case rdp(RDPProfile)
    case appleScreenSharing(ScreenSharingProfile)

    public var id: ProfileID {
        switch self {
        case .ssh(let p): p.id
        case .vnc(let p): p.id
        case .rdp(let p): p.id
        case .appleScreenSharing(let p): p.id
        }
    }

    public var machineID: MachineID {
        switch self {
        case .ssh(let p): p.machineID
        case .vnc(let p): p.machineID
        case .rdp(let p): p.machineID
        case .appleScreenSharing(let p): p.machineID
        }
    }

    public var name: String {
        switch self {
        case .ssh(let p): p.name
        case .vnc(let p): p.name
        case .rdp(let p): p.name
        case .appleScreenSharing(let p): p.name
        }
    }

    public var protocolKind: ConnectionProtocol {
        switch self {
        case .ssh: .ssh
        case .vnc: .vnc
        case .rdp: .rdp
        case .appleScreenSharing: .appleScreenSharing
        }
    }

    public var port: Int? {
        switch self {
        case .ssh(let p): p.port
        case .vnc(let p): p.port
        case .rdp(let p): p.port
        case .appleScreenSharing: nil
        }
    }

    public var username: String? {
        switch self {
        case .ssh(let p): p.username
        case .vnc(let p): p.username
        case .rdp(let p): p.username
        case .appleScreenSharing: nil
        }
    }

    public var addressSelection: AddressSelection {
        switch self {
        case .ssh(let p): p.addressSelection
        case .vnc(let p): p.addressSelection
        case .rdp(let p): p.addressSelection
        case .appleScreenSharing(let p): p.addressSelection
        }
    }

    public var credentialID: CredentialID? {
        switch self {
        case .ssh(let p): p.credentialID
        case .vnc(let p): p.credentialID
        case .rdp(let p): p.credentialID
        case .appleScreenSharing: nil
        }
    }

    /// The same profile with no Keychain reference, for export.
    public func withoutCredential() -> ConnectionProfile {
        switch self {
        case .ssh(var p): p.credentialID = nil; return .ssh(p)
        case .vnc(var p): p.credentialID = nil; return .vnc(p)
        case .rdp(var p): p.credentialID = nil; return .rdp(p)
        case .appleScreenSharing: return self
        }
    }
}
