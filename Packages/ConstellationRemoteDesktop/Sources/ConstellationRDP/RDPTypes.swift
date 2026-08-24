import CoreGraphics
import Foundation

/// What an RDP session needs to start. The password is resolved lazily through
/// a provider at connect time so it never lives in this value.
public struct RDPSessionConfiguration: Sendable, Equatable {
    public var host: String
    public var port: Int
    public var username: String?
    public var domain: String?
    /// Initial desktop size in points. With `dynamicResolution` the session
    /// asks the server to follow the view size afterwards.
    public var width: Int
    public var height: Int
    public var dynamicResolution: Bool
    public var sharesClipboard: Bool

    public init(
        host: String,
        port: Int = 3389,
        username: String? = nil,
        domain: String? = nil,
        width: Int = 1280,
        height: Int = 800,
        dynamicResolution: Bool = true,
        sharesClipboard: Bool = false
    ) {
        self.host = host
        self.port = port
        self.username = username
        self.domain = domain
        self.width = width
        self.height = height
        self.dynamicResolution = dynamicResolution
        self.sharesClipboard = sharesClipboard
    }
}

/// Resolves the account password (from Keychain in the app). Returning `nil`
/// aborts before connecting.
public typealias RDPPasswordProvider = @MainActor @Sendable () async -> String?

/// A server certificate presented for approval. Mirrors the C bridge's view.
public struct RDPCertificate: Sendable, Equatable {
    public var host: String
    public var port: Int
    public var commonName: String
    public var subject: String
    public var issuer: String
    public var fingerprint: String
    public var hostMismatch: Bool
    public var changed: Bool

    public init(host: String, port: Int, commonName: String, subject: String, issuer: String, fingerprint: String, hostMismatch: Bool, changed: Bool) {
        self.host = host
        self.port = port
        self.commonName = commonName
        self.subject = subject
        self.issuer = issuer
        self.fingerprint = fingerprint
        self.hostMismatch = hostMismatch
        self.changed = changed
    }
}

public enum RDPCertificateVerdict: Sendable, Equatable {
    case reject
    case acceptOnce
    /// Lets FreeRDP record the certificate in its own known-hosts file.
    case acceptAndStore
}

/// Decides whether to trust a server certificate. Runs on the main actor while
/// FreeRDP's client thread waits, which is how a native prompt pauses
/// connection setup.
public typealias RDPCertificateVerifier = @MainActor @Sendable (RDPCertificate) async -> RDPCertificateVerdict
