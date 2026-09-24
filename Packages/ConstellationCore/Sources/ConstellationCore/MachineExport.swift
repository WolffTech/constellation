// SPDX-FileCopyrightText: 2026 Nick Wolff <nick@wolff.tech>
// SPDX-License-Identifier: GPL-3.0-only

import Foundation

/// Portable machine definitions. Carries no secrets and no Keychain
/// references; recent sessions, trust decisions and workspace state are
/// deliberately absent.
public struct MachineExportDocument: Hashable, Sendable, Codable {
    /// 2 added groups; 3 added RDP gateways, including Azure Virtual
    /// Desktop. Older documents still decode.
    public static let currentVersion = 3

    public var version: Int
    public var machines: [Machine]
    /// In sidebar order. Absent from version 1 documents.
    public var groups: [MachineGroup]
    public var addresses: [MachineAddress]
    public var profiles: [ConnectionProfile]

    public init(
        version: Int = currentVersion,
        machines: [Machine],
        groups: [MachineGroup] = [],
        addresses: [MachineAddress],
        profiles: [ConnectionProfile]
    ) {
        self.version = version
        self.machines = machines
        self.groups = groups
        self.addresses = addresses
        self.profiles = profiles
    }

    private enum CodingKeys: String, CodingKey {
        case version, machines, groups, addresses, profiles
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        version = try container.decode(Int.self, forKey: .version)
        machines = try container.decode([Machine].self, forKey: .machines)
        groups = try container.decodeIfPresent([MachineGroup].self, forKey: .groups) ?? []
        addresses = try container.decode([MachineAddress].self, forKey: .addresses)
        profiles = try container.decode([ConnectionProfile].self, forKey: .profiles)
    }
}

public enum MachineExportError: Error, Hashable, Sendable, LocalizedError {
    case unsupportedVersion(Int)

    public var errorDescription: String? {
        switch self {
        case .unsupportedVersion(let version): "This export was made by a newer Constellation (format \(version))."
        }
    }
}

public enum MachineExport {
    /// Writes the oldest format that holds the library. Builds that predate
    /// gateways would drop them or fail to decode, so only a library with a
    /// gateway needs version 3; those builds then refuse it by version.
    public static func document(from snapshot: MachineLibrarySnapshot) -> MachineExportDocument {
        let hasGateway = snapshot.profiles.contains { if case .rdp(let p) = $0 { p.gateway != nil } else { false } }
        return MachineExportDocument(
            version: hasGateway ? 3 : 2,
            machines: snapshot.machines,
            groups: snapshot.groups,
            addresses: snapshot.addresses.sorted { ($0.machineID.description, $0.priority) < ($1.machineID.description, $1.priority) },
            profiles: snapshot.profiles.map { $0.withoutCredential() }.sorted { $0.name < $1.name })
    }

    public static func encode(_ document: MachineExportDocument) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try encoder.encode(document)
    }

    public static func decode(_ data: Data) throws -> MachineExportDocument {
        let document = try JSONDecoder().decode(MachineExportDocument.self, from: data)
        guard document.version <= MachineExportDocument.currentVersion else {
            throw MachineExportError.unsupportedVersion(document.version)
        }
        return document
    }

    /// Upserts everything in the document. Imported profiles carry no
    /// credential of their own; one that replaces a profile in `snapshot`
    /// keeps that profile's saved secrets. A group whose name matches one in
    /// `snapshot` (ignoring case) is merged into it rather than duplicated;
    /// the rest are appended in document order. Machines keep their document
    /// order within groups.
    public static func importChange(for document: MachineExportDocument, into snapshot: MachineLibrarySnapshot = .empty) -> MachineLibraryChange {
        var remapped: [GroupID: GroupID] = [:]
        var groupChanges: [MachineLibraryChange] = []
        for group in document.groups.sorted(by: { ($0.position, $0.name) < ($1.position, $1.name) }) {
            if let existing = snapshot.groups.first(where: { $0.name.caseInsensitiveCompare(group.name) == .orderedSame }) {
                remapped[group.id] = existing.id
            } else if snapshot.group(group.id) == nil {
                groupChanges.append(.upsertGroup(group))
            }
        }
        let knownGroups = Set(document.groups.map(\.id)).union(snapshot.groups.map(\.id))
        let machines = document.machines
            .sorted { ($0.position, $0.name) < ($1.position, $1.name) }
            .map { machine -> Machine in
                var machine = machine
                if let groupID = machine.groupID {
                    // A machine may name a group the document does not carry; it becomes ungrouped.
                    machine.groupID = knownGroups.contains(groupID) ? remapped[groupID] ?? groupID : nil
                }
                return machine
            }
        return .batch(
            groupChanges
                + machines.map { .upsertMachine($0) }
                + document.addresses.map { .upsertAddress($0) }
                + document.profiles.map { profile in
                    let imported = profile.withoutCredential()
                    return .upsertProfile(snapshot.profile(profile.id).map(imported.keepingCredentials(of:)) ?? imported)
                })
    }
}
