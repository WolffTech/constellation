// SPDX-FileCopyrightText: 2026 Nick Wolff <nick@wolff.tech>
// SPDX-License-Identifier: GPL-3.0-only

import Foundation

/// A sidebar section. Every machine belongs to at most one group; `position`
/// orders groups in the sidebar and is assigned by the library.
public struct MachineGroup: Identifiable, Hashable, Sendable, Codable {
    public let id: GroupID
    public var name: String
    public var position: Int

    public init(id: GroupID = GroupID(), name: String, position: Int = 0) {
        self.id = id
        self.name = name
        self.position = position
    }
}

public struct Machine: Identifiable, Hashable, Sendable, Codable {
    public let id: MachineID
    public var name: String
    public var notes: String
    /// Free-form search metadata; the sidebar is organised by `groupID`.
    public var tags: Set<String>
    public var isFavorite: Bool
    public var defaultProfileID: ProfileID?
    /// `nil` puts the machine in the ungrouped section.
    public var groupID: GroupID?
    /// Order within the group. The library assigns it: new machines and
    /// machines that change group go last; `moveMachine` reorders.
    public var position: Int

    public init(
        id: MachineID = MachineID(),
        name: String,
        notes: String = "",
        tags: Set<String> = [],
        isFavorite: Bool = false,
        defaultProfileID: ProfileID? = nil,
        groupID: GroupID? = nil,
        position: Int = 0
    ) {
        self.id = id
        self.name = name
        self.notes = notes
        self.tags = tags
        self.isFavorite = isFavorite
        self.defaultProfileID = defaultProfileID
        self.groupID = groupID
        self.position = position
    }

    private enum CodingKeys: String, CodingKey {
        case id, name, notes, tags, isFavorite, defaultProfileID, groupID, position
    }

    /// Exports written before groups existed carry neither field.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(MachineID.self, forKey: .id)
        name = try container.decode(String.self, forKey: .name)
        notes = try container.decode(String.self, forKey: .notes)
        tags = try container.decode(Set<String>.self, forKey: .tags)
        isFavorite = try container.decode(Bool.self, forKey: .isFavorite)
        defaultProfileID = try container.decodeIfPresent(ProfileID.self, forKey: .defaultProfileID)
        groupID = try container.decodeIfPresent(GroupID.self, forKey: .groupID)
        position = try container.decodeIfPresent(Int.self, forKey: .position) ?? 0
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
