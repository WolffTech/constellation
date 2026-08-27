// SPDX-FileCopyrightText: 2026 Nick Wolff <nick@wolff.tech>
// SPDX-License-Identifier: GPL-3.0-only

import Foundation

/// A remote certificate the user has chosen to trust, keyed by host and port.
/// Trust-on-first-use for VNC and RDP: the app remembers the accepted
/// fingerprint so a known server connects without prompting, and warns when a
/// server later presents a different one.
public struct TrustedCertificate: Hashable, Sendable, Codable, Identifiable {
    public var host: String
    public var port: Int
    /// SHA-256 fingerprint as the protocol adapter reports it. Compare with
    /// `matches(fingerprint:)`, which normalizes formatting.
    public var fingerprint: String
    public var subject: String
    public var issuer: String
    public var commonName: String
    /// When the user chose Always Trust. `nil` for decisions recorded before
    /// the app kept the date.
    public var trustedAt: Date?

    public init(
        host: String, port: Int, fingerprint: String,
        subject: String, issuer: String, commonName: String,
        trustedAt: Date? = nil
    ) {
        self.host = host
        self.port = port
        self.fingerprint = fingerprint
        self.subject = subject
        self.issuer = issuer
        self.commonName = commonName
        self.trustedAt = trustedAt
    }

    /// One decision per server, so the address is the identity.
    public var id: String { "\(host):\(port)" }

    /// True when `fingerprint` is the same certificate ignoring separators and
    /// case (adapters vary between `AA:BB` and `aabb`).
    public func matches(fingerprint other: String) -> Bool {
        Self.normalize(fingerprint) == Self.normalize(other)
    }

    static func normalize(_ fingerprint: String) -> String {
        fingerprint.lowercased().filter { $0.isHexDigit }
    }
}

/// Remembers certificate decisions for VNC and RDP. SSH host-key trust is not
/// here; it stays in the user's OpenSSH `known_hosts`.
public protocol TrustStore: Sendable {
    /// The trusted certificate recorded for a server, if any.
    func trusted(host: String, port: Int) async throws -> TrustedCertificate?
    /// Records or replaces the trusted certificate for its host and port.
    func trust(_ certificate: TrustedCertificate) async throws
    /// Drops any recorded decision for a server.
    func forget(host: String, port: Int) async throws
    /// Every recorded decision ordered by host then port, for a management view.
    func all() async throws -> [TrustedCertificate]
}

public actor InMemoryTrustStore: TrustStore {
    private var entries: [String: TrustedCertificate] = [:]

    public init() {}

    private func key(_ host: String, _ port: Int) -> String { "\(host):\(port)" }

    public func trusted(host: String, port: Int) async throws -> TrustedCertificate? {
        entries[key(host, port)]
    }

    public func trust(_ certificate: TrustedCertificate) async throws {
        entries[key(certificate.host, certificate.port)] = certificate
    }

    public func forget(host: String, port: Int) async throws {
        entries[key(host, port)] = nil
    }

    public func all() async throws -> [TrustedCertificate] {
        entries.values.sorted { ($0.host, $0.port) < ($1.host, $1.port) }
    }
}
