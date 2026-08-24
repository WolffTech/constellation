import ConstellationRemoteDesktop
import Foundation

/// What a VNC session needs to start. Secrets are never part of it; the
/// session asks its credential provider when the server demands one.
public struct VNCSessionConfiguration: Sendable, Equatable {
    public var host: String
    public var port: Int
    public var username: String?
    /// Redirect the local pasteboard to and from the remote desktop. Fixed for
    /// the life of the connection.
    public var sharesClipboard: Bool

    public init(host: String, port: Int = 5900, username: String? = nil, sharesClipboard: Bool = false) {
        self.host = host
        self.port = port
        self.username = username
        self.sharesClipboard = sharesClipboard
    }
}

/// What the server asked for during authentication.
public enum VNCCredentialRequest: Sendable, Equatable {
    case password
    case usernameAndPassword
}

public enum VNCSessionCredential: Sendable {
    case password(String)
    case usernameAndPassword(username: String, password: String)
}

/// Answers credential requests. Returning `nil` cancels authentication.
public typealias VNCCredentialProvider = @MainActor @Sendable (VNCCredentialRequest) async -> VNCSessionCredential?
