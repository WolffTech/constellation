// SPDX-FileCopyrightText: 2026 Nick Wolff <nick@wolff.tech>
// SPDX-License-Identifier: GPL-3.0-only

import AppKit
import ConstellationRemoteDesktop
import Foundation
import RoyalVNCKit

/// One RoyalVNCKit connection and the view that shows it.
@MainActor
public final class RoyalVNCSession: RemoteDesktopSession {
    public let view: NSView
    public private(set) var state: RemoteDesktopSessionState = .idle
    public private(set) var framebufferSize: CGSize?
    public var eventHandler: (@MainActor (RemoteDesktopSessionEvent) -> Void)?
    public var displayMode: RemoteDesktopDisplayMode = .fit {
        didSet { host.displayMode = displayMode }
    }

    public let configuration: VNCSessionConfiguration
    private let credentials: VNCCredentialProvider
    private let host: RemoteDesktopHostView
    private var connection: VNCConnection?
    private var bridge: DelegateBridge?
    private var framebufferView: VNCCAFramebufferView?

    public init(configuration: VNCSessionConfiguration, credentials: @escaping VNCCredentialProvider) {
        self.configuration = configuration
        self.credentials = credentials
        host = RemoteDesktopHostView(frame: NSRect(x: 0, y: 0, width: 800, height: 600))
        view = host
    }

    public func connect() {
        guard !state.isLive else { return }
        tearDownConnection()
        let connection = VNCConnection(settings: Self.connectionSettings(for: configuration))
        let bridge = DelegateBridge(session: self)
        connection.delegate = bridge
        self.connection = connection
        self.bridge = bridge
        transition(to: .connecting)
        connection.connect()
    }

    public func disconnect() {
        guard let connection, state.isLive else { return }
        transition(to: .disconnecting)
        connection.disconnect()
    }

    public func focus() {
        guard let framebufferView else { return }
        framebufferView.window?.makeFirstResponder(framebufferView)
    }

    // MARK: Delegate callbacks, already on the main actor

    fileprivate func connectionStateDidChange(_ connectionState: VNCConnection.ConnectionState) {
        switch connectionState.status {
        case .connecting:
            transition(to: .connecting)
        case .connected:
            transition(to: .connected)
        case .disconnecting:
            transition(to: .disconnecting)
        case .disconnected:
            let failure = Self.failure(from: connectionState.error)
            tearDownConnection()
            transition(to: .disconnected(failure))
        }
    }

    fileprivate func credential(for authenticationType: VNCAuthenticationType) async -> VNCCredential? {
        let request: VNCCredentialRequest = authenticationType.requiresUsername ? .usernameAndPassword : .password
        switch await credentials(request) {
        case .password(let password):
            return VNCPasswordCredential(password: password)
        case .usernameAndPassword(let username, let password):
            return VNCUsernamePasswordCredential(username: username, password: password)
        case nil:
            return nil
        }
    }

    fileprivate func framebufferDidChange(_ framebuffer: VNCFramebuffer, connection: VNCConnection, bridge: DelegateBridge) {
        guard connection === self.connection else { return }
        framebufferView?.removeFromSuperview()
        let size = framebuffer.size.cgSize
        let view = VNCCAFramebufferView(
            frame: NSRect(origin: .zero, size: size),
            framebuffer: framebuffer,
            connection: connection,
            connectionDelegate: bridge)
        framebufferView = view
        framebufferSize = size
        host.show(view, framebufferSize: size)
        focus()
        eventHandler?(.framebufferSizeChanged(width: Int(size.width), height: Int(size.height)))
    }

    // MARK: Helpers

    static func connectionSettings(for configuration: VNCSessionConfiguration) -> VNCConnection.Settings {
        let inputMode: VNCConnection.Settings.InputMode = switch configuration.keyboardMode {
        case .local: .none
        case .forwardUnusedShortcuts: .forwardKeyboardShortcutsIfNotInUseLocally
        case .forwardAllShortcuts: .forwardKeyboardShortcutsEvenIfInUseLocally
        }
        let colorDepth: VNCConnection.Settings.ColorDepth = switch configuration.colorDepth {
        case .bits8: .depth8Bit
        case .bits16: .depth16Bit
        case .bits24: .depth24Bit
        }
        return VNCConnection.Settings(
            isDebugLoggingEnabled: false,
            hostname: configuration.host,
            port: UInt16(clamping: configuration.port),
            isShared: configuration.sharesSession,
            isScalingEnabled: true,
            useDisplayLink: true,
            inputMode: inputMode,
            isClipboardRedirectionEnabled: configuration.sharesClipboard,
            colorDepth: colorDepth,
            frameEncodings: .default)
    }

    private func transition(to newState: RemoteDesktopSessionState) {
        guard newState != state else { return }
        state = newState
        eventHandler?(.stateChanged(newState))
    }

    private func tearDownConnection() {
        connection?.delegate = nil
        connection = nil
        bridge = nil
        framebufferView?.removeFromSuperview()
        framebufferView = nil
        host.clear()
    }

    /// Maps RoyalVNCKit's close reason. Cancelled and plain closes are clean.
    static func failure(from error: Error?) -> RemoteDesktopSessionFailure? {
        guard let error else { return nil }
        if let vncError = error as? VNCError {
            guard vncError.shouldDisplayToUser else { return nil }
            return RemoteDesktopSessionFailure(
                message: vncError.localizedDescription,
                isAuthenticationFailure: vncError.isAuthenticationError)
        }
        return RemoteDesktopSessionFailure(message: error.localizedDescription)
    }
}

/// RoyalVNCKit calls its delegate from its own queues; this hops to the main
/// actor. `VNCCAFramebufferView` takes over `connection.delegate` for input
/// and rendering and forwards the rest here.
private final class DelegateBridge: NSObject, VNCConnectionDelegate, @unchecked Sendable {
    private weak var session: RoyalVNCSession?

    init(session: RoyalVNCSession) {
        self.session = session
    }

    func connection(_ connection: VNCConnection, stateDidChange connectionState: VNCConnection.ConnectionState) {
        let boxed = UncheckedSendable(connectionState)
        Task { @MainActor [weak session] in
            session?.connectionStateDidChange(boxed.value)
        }
    }

    func connection(
        _ connection: VNCConnection,
        credentialFor authenticationType: VNCAuthenticationType,
        completion: @escaping (VNCCredential?) -> Void
    ) {
        let boxedCompletion = UncheckedSendable(completion)
        let boxedType = UncheckedSendable(authenticationType)
        Task { @MainActor [weak session] in
            let credential = await session?.credential(for: boxedType.value)
            boxedCompletion.value(credential)
        }
    }

    func connection(_ connection: VNCConnection, didCreateFramebuffer framebuffer: VNCFramebuffer) {
        framebufferDidChange(framebuffer, connection: connection)
    }

    func connection(_ connection: VNCConnection, didResizeFramebuffer framebuffer: VNCFramebuffer) {
        framebufferDidChange(framebuffer, connection: connection)
    }

    func connection(_ connection: VNCConnection, didUpdateFramebuffer framebuffer: VNCFramebuffer, x: UInt16, y: UInt16, width: UInt16, height: UInt16) {
        // The framebuffer view renders updates itself.
    }

    func connection(_ connection: VNCConnection, didUpdateCursor cursor: VNCCursor) {
        // The framebuffer view applies cursors itself.
    }

    private func framebufferDidChange(_ framebuffer: VNCFramebuffer, connection: VNCConnection) {
        let boxed = UncheckedSendable((framebuffer, connection))
        Task { @MainActor [weak session, weak self] in
            guard let self else { return }
            session?.framebufferDidChange(boxed.value.0, connection: boxed.value.1, bridge: self)
        }
    }
}

/// RoyalVNCKit predates Sendable; its objects cross to the main actor here only.
private struct UncheckedSendable<Value>: @unchecked Sendable {
    let value: Value
    init(_ value: Value) { self.value = value }
}
