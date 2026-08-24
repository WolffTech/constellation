import AppKit
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

public struct VNCSessionFailure: Error, Sendable, Equatable, LocalizedError {
    public var message: String
    public var isAuthenticationFailure: Bool

    public init(message: String, isAuthenticationFailure: Bool = false) {
        self.message = message
        self.isAuthenticationFailure = isAuthenticationFailure
    }

    public var errorDescription: String? { message }
}

public enum VNCSessionState: Sendable, Equatable {
    case idle
    case connecting
    case connected
    case disconnecting
    /// `nil` is a clean close (local disconnect or server closed without error).
    case disconnected(VNCSessionFailure?)

    public var isLive: Bool {
        switch self {
        case .connecting, .connected, .disconnecting: true
        case .idle, .disconnected: false
        }
    }
}

public enum VNCSessionEvent: Sendable, Equatable {
    case stateChanged(VNCSessionState)
    case framebufferSizeChanged(width: Int, height: Int)
}

/// How the remote framebuffer maps onto the host view.
public enum RemoteDesktopDisplayMode: Sendable, Equatable, CaseIterable {
    /// Scale down to fit the view, never up; centred.
    case fit
    /// One remote pixel per point, scrollable.
    case actualSize
}

/// A remote desktop the app can show in a tab. Everything happens on the main
/// actor; adapters hop from their own threads before calling back.
@MainActor
public protocol RemoteDesktopSession: AnyObject {
    var view: NSView { get }
    var state: VNCSessionState { get }
    var framebufferSize: CGSize? { get }
    var displayMode: RemoteDesktopDisplayMode { get set }
    var eventHandler: (@MainActor (VNCSessionEvent) -> Void)? { get set }

    func connect()
    func disconnect()
    /// Hands keyboard focus to the remote desktop view.
    func focus()
}
