import CoreGraphics
import Foundation

/// What an RDP session needs to start. The password is resolved lazily through
/// a provider at connect time so it never lives in this value.
public struct RDPSessionConfiguration: Sendable, Equatable {
    public var host: String
    public var port: Int
    public var username: String?
    public var domain: String?
    /// Initial desktop size. The server may resize; with `dynamicResolution`
    /// the client can request new sizes as the window changes.
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

public enum RDPSessionFailureKind: Sendable, Equatable {
    case generic
    case authentication
    case cancelled
    case dns
    case tls
    case connect
}

public struct RDPSessionFailure: Error, Sendable, Equatable, LocalizedError {
    public var kind: RDPSessionFailureKind
    public var message: String

    public init(kind: RDPSessionFailureKind, message: String) {
        self.kind = kind
        self.message = message
    }

    public var isAuthenticationFailure: Bool { kind == .authentication }
    public var errorDescription: String? { message }
}

public enum RDPSessionState: Sendable, Equatable {
    case idle
    case connecting
    case connected
    case disconnecting
    /// `nil` is a clean close.
    case disconnected(RDPSessionFailure?)

    public var isLive: Bool {
        switch self {
        case .connecting, .connected, .disconnecting: true
        case .idle, .disconnected: false
        }
    }
}

public enum RDPSessionEvent: Sendable, Equatable {
    case stateChanged(RDPSessionState)
    case framebufferSizeChanged(width: Int, height: Int)
}

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
}

public enum RDPCertificateVerdict: Sendable, Equatable {
    case reject
    case acceptOnce
    case acceptAndStore
}

/// Decides whether to trust a server certificate. Called off the main actor's
/// UI work but hopped to the main actor here; it blocks connection setup until
/// it returns, which is how the native prompt pauses the connection.
public typealias RDPCertificateVerifier = @MainActor @Sendable (RDPCertificate) async -> RDPCertificateVerdict

/// How the remote framebuffer maps onto the host view. Matches the VNC adapter.
public enum RDPDisplayMode: Sendable, Equatable, CaseIterable {
    case fit
    case actualSize
}
