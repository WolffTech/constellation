import Foundation

/// Portable machine definitions. Carries no secrets and no Keychain
/// references; recent sessions, trust decisions and workspace state are
/// deliberately absent.
public struct MachineExportDocument: Hashable, Sendable, Codable {
    public static let currentVersion = 1

    public var version: Int
    public var machines: [Machine]
    public var addresses: [MachineAddress]
    public var profiles: [ConnectionProfile]

    public init(version: Int = currentVersion, machines: [Machine], addresses: [MachineAddress], profiles: [ConnectionProfile]) {
        self.version = version
        self.machines = machines
        self.addresses = addresses
        self.profiles = profiles
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
    public static func document(from snapshot: MachineLibrarySnapshot) -> MachineExportDocument {
        MachineExportDocument(
            machines: snapshot.machines.sorted { $0.name < $1.name },
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

    /// Upserts everything in the document. Imported profiles carry no credential.
    public static func importChange(for document: MachineExportDocument) -> MachineLibraryChange {
        .batch(
            document.machines.map { .upsertMachine($0) }
                + document.addresses.map { .upsertAddress($0) }
                + document.profiles.map { .upsertProfile($0.withoutCredential()) })
    }
}
