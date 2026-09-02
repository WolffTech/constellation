// SPDX-FileCopyrightText: 2026 Nick Wolff <nick@wolff.tech>
// SPDX-License-Identifier: GPL-3.0-only

import Foundation

/// Everything the app needs to show and edit machines. Loaded whole; the
/// library is small and a snapshot keeps the UI free of query plumbing.
public struct MachineLibrarySnapshot: Hashable, Sendable {
    /// Sidebar order: by group position, then machine position.
    public var machines: [Machine]
    public var groups: [MachineGroup]
    public var addresses: [MachineAddress]
    public var profiles: [ConnectionProfile]
    public var credentials: [CredentialReference]
    public var workspaceTabs: [WorkspaceTab]

    public init(
        machines: [Machine] = [],
        groups: [MachineGroup] = [],
        addresses: [MachineAddress] = [],
        profiles: [ConnectionProfile] = [],
        credentials: [CredentialReference] = [],
        workspaceTabs: [WorkspaceTab] = []
    ) {
        self.machines = machines
        self.groups = groups.sorted { ($0.position, $0.name) < ($1.position, $1.name) }
        self.addresses = addresses
        self.profiles = profiles
        self.credentials = credentials
        self.workspaceTabs = workspaceTabs.sorted { $0.position < $1.position }
    }

    public static let empty = MachineLibrarySnapshot()

    public func machine(_ id: MachineID) -> Machine? {
        machines.first { $0.id == id }
    }

    public func group(_ id: GroupID) -> MachineGroup? {
        groups.first { $0.id == id }
    }

    /// Machines in a group (`nil` for the ungrouped ones) in sidebar order.
    public func machines(in groupID: GroupID?) -> [Machine] {
        machines.filter { $0.groupID == groupID }.sorted { ($0.position, $0.name) < ($1.position, $1.name) }
    }

    /// Addresses for a machine in priority order.
    public func addresses(for machineID: MachineID) -> [MachineAddress] {
        addresses.filter { $0.machineID == machineID }.sorted { ($0.priority, $0.label) < ($1.priority, $1.label) }
    }

    public func profiles(for machineID: MachineID) -> [ConnectionProfile] {
        profiles.filter { $0.machineID == machineID }.sorted { $0.name < $1.name }
    }

    public func profile(_ id: ProfileID) -> ConnectionProfile? {
        profiles.first { $0.id == id }
    }

    public func credential(_ id: CredentialID) -> CredentialReference? {
        credentials.first { $0.id == id }
    }

    /// Credential references no profile uses.
    public var orphanedCredentials: [CredentialReference] {
        let used = Set(profiles.compactMap(\.credentialID))
        return credentials.filter { !used.contains($0.id) }
    }
}

/// One edit. `batch` applies its changes in a single transaction.
public indirect enum MachineLibraryChange: Hashable, Sendable {
    case upsertMachine(Machine)
    case deleteMachine(MachineID)
    /// A new group goes last; an existing one keeps its position.
    case upsertGroup(MachineGroup)
    /// Its machines become ungrouped, appended after the existing ones.
    case deleteGroup(GroupID)
    /// Places the machine at `position` among the target group's machines,
    /// clamped to the end. Siblings are renumbered.
    case moveMachine(MachineID, to: GroupID?, position: Int)
    case moveGroup(GroupID, position: Int)
    case upsertAddress(MachineAddress)
    case deleteAddress(AddressID)
    case upsertProfile(ConnectionProfile)
    case deleteProfile(ProfileID)
    case upsertCredential(CredentialReference)
    case deleteCredential(CredentialID)
    /// Replaces the complete saved-tab snapshot. Quick Connect tabs are excluded.
    case replaceWorkspace([WorkspaceTab])
    case batch([MachineLibraryChange])
}

public protocol MachineLibrary: Sendable {
    func snapshot() async throws -> MachineLibrarySnapshot
    /// Validates, then applies the change atomically.
    func save(_ change: MachineLibraryChange) async throws
}

public enum MachineLibraryError: Error, Hashable, Sendable, LocalizedError {
    case validation(ValidationError)
    case unknownMachine(MachineID)
    case unknownGroup(GroupID)
    /// A stored record could not be decoded. Surfaced rather than dropped.
    case corruptRecord(table: String, id: String, reason: String)

    public var errorDescription: String? {
        switch self {
        case .validation(let error): error.errorDescription
        case .unknownMachine(let id): "No machine with id \(id) exists."
        case .unknownGroup(let id): "No group with id \(id) exists."
        case .corruptRecord(let table, let id, let reason): "Stored \(table) record \(id) could not be read: \(reason)"
        }
    }
}
