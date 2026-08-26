// SPDX-FileCopyrightText: 2026 Nick Wolff <nick@wolff.tech>
// SPDX-License-Identifier: GPL-3.0-only

import ConstellationTerminal
import Foundation

/// `user@host[:port]` as typed in Quick Connect or stored on a profile.
public struct SSHDestination: Sendable, Equatable {
    public var host: String
    public var user: String?
    public var port: Int?

    public init(host: String, user: String? = nil, port: Int? = nil) {
        self.host = host
        self.user = user
        self.port = port
    }

    /// Parses `host`, `user@host`, or `user@host:port`. Returns `nil` for an empty host.
    public init?(parsing text: String) {
        var rest = text.trimmingCharacters(in: .whitespaces)
        var user: String?
        if let at = rest.firstIndex(of: "@") {
            user = String(rest[..<at])
            rest = String(rest[rest.index(after: at)...])
        }
        var port: Int?
        if let colon = rest.lastIndex(of: ":"), let value = Int(rest[rest.index(after: colon)...]) {
            port = value
            rest = String(rest[..<colon])
        }
        guard !rest.isEmpty else { return nil }
        self.init(host: rest, user: user.flatMap { $0.isEmpty ? nil : $0 }, port: port)
    }

    var hostArgument: String {
        if host.hasPrefix("["), host.hasSuffix("]") {
            return String(host.dropFirst().dropLast())
        }
        return host
    }
}

/// Builds the `/usr/bin/ssh` command for one session.
public struct SSHLaunch: Sendable {
    public var destination: SSHDestination
    /// Shared `known_hosts` entry for every address of one machine.
    public var hostKeyAlias: String?
    public var connectTimeout: Int = 10
    /// Private key to use exclusively (`-i` plus `IdentitiesOnly=yes`).
    public var identityFile: String?
    /// Extra `-o` options, for tests and future profile settings.
    public var options: [String] = []

    public init(destination: SSHDestination, hostKeyAlias: String? = nil) {
        self.destination = destination
        self.hostKeyAlias = hostKeyAlias
    }

    public func command(environment: [String: String] = [:]) -> TerminalCommand {
        var arguments = ["-o", "ConnectTimeout=\(connectTimeout)"]
        if let hostKeyAlias { arguments += ["-o", "HostKeyAlias=\(hostKeyAlias)"] }
        if let identityFile { arguments += ["-i", identityFile, "-o", "IdentitiesOnly=yes"] }
        for option in options { arguments += ["-o", option] }
        if let port = destination.port { arguments += ["-p", String(port)] }
        if let user = destination.user { arguments += ["-l", user] }
        arguments.append(destination.hostArgument)
        return TerminalCommand(executable: "/usr/bin/ssh", arguments: arguments, environment: environment)
    }
}
