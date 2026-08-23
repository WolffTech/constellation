import Foundation

/// A UUID that only matches identifiers of the same kind, so a `MachineID`
/// cannot be passed where a `ProfileID` is expected.
public struct TypedID<Tag>: Hashable, Sendable, Codable, CustomStringConvertible {
    public let rawValue: UUID

    public init(rawValue: UUID = UUID()) {
        self.rawValue = rawValue
    }

    public init?(uuidString: String) {
        guard let uuid = UUID(uuidString: uuidString) else { return nil }
        self.rawValue = uuid
    }

    public init(from decoder: any Decoder) throws {
        rawValue = try decoder.singleValueContainer().decode(UUID.self)
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }

    public var description: String { rawValue.uuidString }
}

public enum MachineIDTag: Sendable {}
public enum AddressIDTag: Sendable {}
public enum ProfileIDTag: Sendable {}
public enum CredentialIDTag: Sendable {}

public typealias MachineID = TypedID<MachineIDTag>
public typealias AddressID = TypedID<AddressIDTag>
public typealias ProfileID = TypedID<ProfileIDTag>
public typealias CredentialID = TypedID<CredentialIDTag>
