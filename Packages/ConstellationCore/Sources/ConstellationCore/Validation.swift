// SPDX-FileCopyrightText: 2026 Nick Wolff <nick@wolff.tech>
// SPDX-License-Identifier: GPL-3.0-only

import Foundation

public enum ValidationError: Error, Hashable, Sendable, LocalizedError {
    case emptyMachineName
    case emptyHost
    case invalidHost(String)
    case invalidPort(Int)
    case emptyProfileName
    case missingCredential(profile: String)
    case missingKeyFile(profile: String)

    public var errorDescription: String? {
        switch self {
        case .emptyMachineName: "Give the machine a name."
        case .emptyHost: "Enter a hostname or IP address."
        case .invalidHost(let host): "“\(host)” is not a valid hostname or IP address."
        case .invalidPort(let port): "Port \(port) is out of range. Use 1 through 65535."
        case .emptyProfileName: "Give the profile a name."
        case .missingCredential(let profile): "“\(profile)” uses password authentication but has no saved password."
        case .missingKeyFile(let profile): "“\(profile)” uses a key file but no path is set."
        }
    }
}

public enum Validator {
    public static func validate(_ machine: Machine) throws(ValidationError) {
        if machine.name.trimmingCharacters(in: .whitespaces).isEmpty { throw .emptyMachineName }
    }

    public static func validate(_ address: MachineAddress) throws(ValidationError) {
        try validateHost(address.host)
    }

    /// Accepts DNS names, IPv4, and IPv6 (optionally bracketed, with a zone).
    public static func validateHost(_ host: String) throws(ValidationError) {
        let trimmed = host.trimmingCharacters(in: .whitespaces)
        if trimmed.isEmpty { throw .emptyHost }
        var candidate = trimmed
        if candidate.hasPrefix("["), candidate.hasSuffix("]") {
            candidate = String(candidate.dropFirst().dropLast())
        }
        guard candidate.count <= 253, !candidate.contains(where: \.isWhitespace) else { throw .invalidHost(host) }
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: ".-:%_"))
        guard candidate.unicodeScalars.allSatisfy(allowed.contains) else { throw .invalidHost(host) }
        if candidate.contains(":") {
            // IPv6 needs at least two colons; anything else with a colon is a typo'd port.
            guard candidate.filter({ $0 == ":" }).count >= 2 else { throw .invalidHost(host) }
        } else {
            guard !candidate.hasPrefix("."), !candidate.hasSuffix("."), !candidate.contains("..") else { throw .invalidHost(host) }
        }
    }

    public static func validatePort(_ port: Int) throws(ValidationError) {
        guard (1...65535).contains(port) else { throw .invalidPort(port) }
    }

    public static func validate(_ profile: ConnectionProfile) throws(ValidationError) {
        if profile.name.trimmingCharacters(in: .whitespaces).isEmpty { throw .emptyProfileName }
        if let port = profile.port { try validatePort(port) }
        if case .ssh(let ssh) = profile {
            switch ssh.authentication {
            case .password where ssh.credentialID == nil:
                throw .missingCredential(profile: ssh.name)
            case .keyFile(let path) where path.trimmingCharacters(in: .whitespaces).isEmpty:
                throw .missingKeyFile(profile: ssh.name)
            default:
                break
            }
        }
    }

    public static func validate(_ change: MachineLibraryChange) throws(ValidationError) {
        switch change {
        case .upsertMachine(let machine): try validate(machine)
        case .upsertAddress(let address): try validate(address)
        case .upsertProfile(let profile): try validate(profile)
        case .upsertCredential(let credential):
            if credential.label.trimmingCharacters(in: .whitespaces).isEmpty { throw .emptyProfileName }
        case .batch(let changes):
            for change in changes { try validate(change) }
        case .deleteMachine, .deleteAddress, .deleteProfile, .deleteCredential, .replaceWorkspace:
            break
        }
    }
}
