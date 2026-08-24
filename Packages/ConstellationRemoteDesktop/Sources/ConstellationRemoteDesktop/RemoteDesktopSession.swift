import AppKit
import Foundation

/// Why a remote desktop session ended.
public struct RemoteDesktopSessionFailure: Error, Sendable, Equatable, LocalizedError {
    public var message: String
    public var isAuthenticationFailure: Bool

    public init(message: String, isAuthenticationFailure: Bool = false) {
        self.message = message
        self.isAuthenticationFailure = isAuthenticationFailure
    }

    public var errorDescription: String? { message }
}

public enum RemoteDesktopSessionState: Sendable, Equatable {
    case idle
    case connecting
    case connected
    case disconnecting
    /// `nil` is a clean close (local disconnect or server closed without error).
    case disconnected(RemoteDesktopSessionFailure?)

    public var isLive: Bool {
        switch self {
        case .connecting, .connected, .disconnecting: true
        case .idle, .disconnected: false
        }
    }
}

public enum RemoteDesktopSessionEvent: Sendable, Equatable {
    case stateChanged(RemoteDesktopSessionState)
    case framebufferSizeChanged(width: Int, height: Int)
}

/// How the remote framebuffer maps onto the host view.
public enum RemoteDesktopDisplayMode: Sendable, Equatable, CaseIterable {
    /// Scale down to fit the view, never up; centred. Protocols that support
    /// dynamic resolution ask the remote to match the view instead.
    case fit
    /// One remote pixel per point, scrollable.
    case actualSize
}

/// A remote desktop the app can show in a tab, whatever the protocol.
/// Everything happens on the main actor; adapters hop from their own threads
/// before calling back.
@MainActor
public protocol RemoteDesktopSession: AnyObject {
    var view: NSView { get }
    var state: RemoteDesktopSessionState { get }
    var framebufferSize: CGSize? { get }
    var displayMode: RemoteDesktopDisplayMode { get set }
    var eventHandler: (@MainActor (RemoteDesktopSessionEvent) -> Void)? { get set }

    func connect()
    func disconnect()
    /// Hands keyboard focus to the remote desktop view.
    func focus()
}
