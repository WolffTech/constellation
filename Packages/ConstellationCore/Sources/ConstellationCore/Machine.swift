// SPDX-FileCopyrightText: 2026 Nick Wolff <nick@wolff.tech>
// SPDX-License-Identifier: GPL-3.0-only

import Foundation

public struct Machine: Identifiable, Hashable, Sendable, Codable {
    public let id: MachineID
    public var name: String
    public var notes: String
    public var tags: Set<String>
    public var isFavorite: Bool
    public var defaultProfileID: ProfileID?

    public init(
        id: MachineID = MachineID(),
        name: String,
        notes: String = "",
        tags: Set<String> = [],
        isFavorite: Bool = false,
        defaultProfileID: ProfileID? = nil
    ) {
        self.id = id
        self.name = name
        self.notes = notes
        self.tags = tags
        self.isFavorite = isFavorite
        self.defaultProfileID = defaultProfileID
    }
}

/// One way to reach a machine. A machine may have several; `priority` orders
/// them for automatic selection (lower first).
public struct MachineAddress: Identifiable, Hashable, Sendable, Codable {
    public let id: AddressID
    public let machineID: MachineID
    /// Optional; the UI shows the network kind when this is empty.
    public var label: String
    public var host: String
    public var kind: AddressKind
    public var priority: Int

    public init(
        id: AddressID = AddressID(),
        machineID: MachineID,
        label: String,
        host: String,
        kind: AddressKind = .lan,
        priority: Int = 0
    ) {
        self.id = id
        self.machineID = machineID
        self.label = label
        self.host = host
        self.kind = kind
        self.priority = priority
    }
}

public extension MachineAddress {
    /// The label, falling back to the network kind so an address is never nameless.
    var displayLabel: String {
        let trimmed = label.trimmingCharacters(in: .whitespaces)
        return trimmed.isEmpty ? kind.displayName : trimmed
    }
}

public enum AddressKind: String, Hashable, Sendable, Codable, CaseIterable {
    case lan
    case tailscale
    case vpn
    case publicNetwork
    case other

    public var displayName: String {
        switch self {
        case .lan: "LAN"
        case .tailscale: "Tailscale"
        case .vpn: "VPN"
        case .publicNetwork: "Public"
        case .other: "Other"
        }
    }
}
