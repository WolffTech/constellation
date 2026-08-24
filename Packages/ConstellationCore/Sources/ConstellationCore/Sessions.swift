import Foundation

/// The saved identity of a tab. Process state and Quick Connect targets never
/// enter the machine library.
public struct WorkspaceTab: Identifiable, Hashable, Sendable, Codable {
    public let id: SessionID
    public let machineID: MachineID
    public let profileID: ProfileID
    public var title: String
    public var position: Int
    public var isSelected: Bool

    public init(
        id: SessionID,
        machineID: MachineID,
        profileID: ProfileID,
        title: String,
        position: Int,
        isSelected: Bool = false
    ) {
        self.id = id
        self.machineID = machineID
        self.profileID = profileID
        self.title = title
        self.position = position
        self.isSelected = isSelected
    }
}

/// A one-off SSH destination entered in Quick Connect.
public struct QuickConnectTarget: Hashable, Sendable {
    public var host: String
    public var username: String?
    /// `nil` lets OpenSSH configuration choose the port.
    public var port: Int?

    public init(host: String, username: String? = nil, port: Int? = nil) {
        self.host = host
        self.username = username
        self.port = port
    }

    /// Parses `host`, `user@host`, `host:port`, `user@host:port`, and bracketed IPv6.
    public init(parsing text: String) throws {
        let input = text.trimmingCharacters(in: .whitespacesAndNewlines)
        var destination = input
        var username: String?
        if let at = destination.firstIndex(of: "@") {
            let candidate = String(destination[..<at])
            username = candidate.isEmpty ? nil : candidate
            destination = String(destination[destination.index(after: at)...])
        }

        var host = destination
        var port: Int?
        if destination.hasPrefix("[") {
            guard let close = destination.firstIndex(of: "]") else {
                throw QuickConnectError.invalidTarget
            }
            host = String(destination[destination.index(after: destination.startIndex)..<close])
            let suffix = destination[destination.index(after: close)...]
            if !suffix.isEmpty {
                guard suffix.first == ":", let value = Int(suffix.dropFirst()) else {
                    throw QuickConnectError.invalidTarget
                }
                port = value
            }
        } else if destination.filter({ $0 == ":" }).count == 1,
                  let colon = destination.lastIndex(of: ":") {
            let suffix = destination[destination.index(after: colon)...]
            guard let value = Int(suffix) else { throw QuickConnectError.invalidTarget }
            host = String(destination[..<colon])
            port = value
        }

        do {
            try Validator.validateHost(host)
            if let port { try Validator.validatePort(port) }
        } catch {
            throw QuickConnectError.validation(error)
        }
        self.init(host: host, username: username, port: port)
    }

    public var displayName: String {
        let hostPart = host.contains(":") ? "[\(host)]" : host
        let userPart = username.map { "\($0)@" } ?? ""
        let portPart = port.map { ":\($0)" } ?? ""
        return userPart + hostPart + portPart
    }

    public var effectivePort: Int { port ?? 22 }
}

public enum QuickConnectError: Error, Hashable, Sendable, LocalizedError {
    case invalidTarget
    case validation(ValidationError)

    public var errorDescription: String? {
        switch self {
        case .invalidTarget:
            "Enter a host, user@host, or user@host:port."
        case .validation(let error):
            error.errorDescription
        }
    }
}
