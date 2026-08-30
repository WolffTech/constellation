// SPDX-FileCopyrightText: 2026 Nick Wolff <nick@wolff.tech>
// SPDX-License-Identifier: GPL-3.0-only

import AppKit
import CConstellationRDP
import ConstellationRemoteDesktop
import Foundation

/// One FreeRDP connection and the AppKit view that shows it. Everything public
/// happens on the main actor; the C bridge's callbacks arrive on the client
/// thread and hop here.
@MainActor
public final class RDPSession: RemoteDesktopSession {
    public let view: NSView
    public private(set) var state: RemoteDesktopSessionState = .idle
    /// In pixels: on a Retina display the desktop is twice the view's point size.
    public private(set) var framebufferSize: CGSize?
    public var eventHandler: (@MainActor (RemoteDesktopSessionEvent) -> Void)?
    public var displayMode: RemoteDesktopDisplayMode = .fit {
        didSet { host.displayMode = displayMode }
    }

    public let configuration: RDPSessionConfiguration
    private let passwordProvider: RDPPasswordProvider
    private let verifier: RDPCertificateVerifier
    private let host: RDPHostView
    private let surface = RDPSurfaceView(frame: NSRect(x: 0, y: 0, width: 1280, height: 800))
    private var handle: OpaquePointer?
    /// Callback tasks retain this token; its weak session link dies safely during teardown.
    private var callbackContext: RDPCallbackContext?
    private var connectTask: Task<Void, Never>?
    private var resizeTask: Task<Void, Never>?
    /// Present only when the configuration shares the clipboard.
    private let clipboard: RDPClipboardSync?
    /// Polls the pasteboard while connected; AppKit has no change notification.
    private var clipboardTimer: Timer?
    /// The last pixel size asked of the server, so repeated layouts dedupe.
    private var requestedPixelSize: CGSize?

    /// Pixels per point on the display showing the view. Before the view is on
    /// screen the main display's scale is the best guess, so a Retina session
    /// starts at the right density instead of resizing after the first frame.
    private var backingScale: CGFloat {
        host.window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 1
    }

    private var scalePercent: UInt32 { UInt32((backingScale * 100).rounded()) }

    /// Converts a point size to the even-width pixel size MS-RDPEDISP accepts.
    private func pixelSize(for points: CGSize) -> CGSize {
        let scale = backingScale
        var width = (points.width * scale).rounded(.down)
        width -= width.truncatingRemainder(dividingBy: 2)
        return CGSize(width: width, height: (points.height * scale).rounded(.down))
    }

    public init(
        configuration: RDPSessionConfiguration,
        password: @escaping RDPPasswordProvider,
        verifyCertificate: @escaping RDPCertificateVerifier
    ) {
        self.configuration = configuration
        self.passwordProvider = password
        self.verifier = verifyCertificate
        clipboard = configuration.sharesClipboard ? RDPClipboardSync() : nil
        host = RDPHostView(frame: NSRect(x: 0, y: 0, width: 1280, height: 800))
        view = host
        surface.inputSink = { [weak self] event in self?.handle(input: event) }
        if configuration.dynamicResolution {
            host.onFitSizeChanged = { [weak self] size in self?.scheduleResolutionRequest(size) }
        }
    }

    isolated deinit {
        resizeTask?.cancel()
        clipboardTimer?.invalidate()
        if let handle { crdp_session_free(handle) }
    }

    public func connect() {
        guard !state.isLive, connectTask == nil else { return }
        transition(to: .connecting)
        connectTask = Task { [weak self] in
            guard let self else { return }
            let password = await self.passwordProvider()
            if Task.isCancelled { return }
            self.startSession(password: password)
            self.connectTask = nil
        }
    }

    public func disconnect() {
        connectTask?.cancel()
        connectTask = nil
        guard let handle, state.isLive else { return }
        transition(to: .disconnecting)
        crdp_session_disconnect(handle)
    }

    public func focus() {
        surface.window?.makeFirstResponder(surface)
    }

    /// Frame updates received from the bridge and snapshots handed to Core
    /// Animation so far. For profiling.
    var frameStatistics: (updates: Int, snapshots: Int) {
        (surface.updateCount, surface.snapshotCount)
    }

    /// Asks the server for a new desktop size, in points; the display's backing
    /// scale turns it into pixels. A no-op unless dynamic resolution was
    /// negotiated and the session is connected.
    public func requestResolution(width: Int, height: Int) {
        request(pixels: pixelSize(for: CGSize(width: max(0, width), height: max(0, height))))
    }

    @discardableResult
    private func request(pixels: CGSize) -> Bool {
        guard let handle, state == .connected else { return false }
        crdp_session_request_resolution(handle, UInt32(pixels.width), UInt32(pixels.height), scalePercent)
        return true
    }

    // MARK: Session start

    private func startSession(password: String?) {
        let callbackContext = RDPCallbackContext(session: self)
        self.callbackContext = callbackContext
        let callbacks = crdp_callbacks(
            context: Unmanaged.passUnretained(callbackContext).toOpaque(),
            state_changed: rdpStateChanged,
            frame_resized: rdpFrameResized,
            frame_updated: rdpFrameUpdated,
            verify_certificate: rdpVerifyCertificate,
            clipboard_text: rdpClipboardText)

        // The password is copied into FreeRDP's settings and this stack frame
        // is the only other place it lives.
        configuration.host.withCString { hostPtr in
            withOptionalCString(configuration.username) { userPtr in
                withOptionalCString(configuration.domain) { domainPtr in
                    withOptionalCString(password) { passwordPtr in
                        let initial = pixelSize(for: CGSize(width: max(1, configuration.width), height: max(1, configuration.height)))
                        var config = crdp_config(
                            host: hostPtr,
                            port: UInt32(max(0, configuration.port)),
                            username: userPtr,
                            domain: domainPtr,
                            password: passwordPtr,
                            width: UInt32(max(2, initial.width)),
                            height: UInt32(max(1, initial.height)),
                            scale_percent: scalePercent,
                            dynamic_resolution: configuration.dynamicResolution,
                            share_clipboard: configuration.sharesClipboard,
                            connection_type: configuration.connectionQuality.bridgeValue)
                        var callbacksCopy = callbacks
                        handle = crdp_session_create(&config, &callbacksCopy)
                    }
                }
            }
        }

        guard handle != nil else {
            self.callbackContext = nil
            transition(to: .disconnected(RemoteDesktopSessionFailure(message: Self.createFailureMessage)))
            return
        }
        crdp_session_connect(handle)
    }

    // MARK: Callbacks, already hopped to the main actor

    fileprivate func stateChanged(_ state: crdp_state, failure: crdp_failure) {
        switch state {
        case CRDP_STATE_CONNECTING:
            transition(to: .connecting)
        case CRDP_STATE_CONNECTED:
            transition(to: .connected)
            focus()
            // The initial size came from configuration; catch up with the view.
            requestFitResolution()
            startClipboardSync()
        case CRDP_STATE_DISCONNECTED:
            resizeTask?.cancel()
            clipboardTimer?.invalidate()
            clipboardTimer = nil
            transition(to: .disconnected(Self.failure(from: failure)))
        default:
            break
        }
    }

    fileprivate func frameResized(buffer: UnsafePointer<UInt8>, width: Int, height: Int, stride: Int) {
        surface.setFrameBuffer(buffer, width: width, height: height, stride: stride)
        let size = CGSize(width: width, height: height)
        framebufferSize = size
        host.show(surface, framebufferSize: size)
        eventHandler?(.framebufferSizeChanged(width: width, height: height))
        // The first frame uses the configured size; once the view is on screen
        // and laid out, ask the desktop to match it. A no-op if already equal.
        requestFitResolution()
    }

    fileprivate func frameUpdated() {
        surface.markDirty()
    }

    fileprivate func verifyCertificate(_ certificate: RDPCertificate) async -> RDPCertificateVerdict {
        await verifier(certificate)
    }

    fileprivate func clipboardTextReceived(_ text: String) {
        clipboard?.receive(remoteText: text)
    }

    // MARK: Clipboard

    /// Offers what is already on the pasteboard, then watches for copies.
    private func startClipboardSync() {
        guard let clipboard, clipboardTimer == nil else { return }
        offer(clipboard.currentText())
        let timer = Timer(timeInterval: 1, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self, let text = self.clipboard?.pollLocalChange() else { return }
                self.offer(text)
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        clipboardTimer = timer
    }

    private func offer(_ text: String?) {
        guard let handle, let text, !text.isEmpty else { return }
        crdp_session_set_clipboard_text(handle, text)
    }

    // MARK: Helpers

    /// Asks the desktop to match the current fitted view size. Used on connect,
    /// on the first frame and whenever the view lays out, so the remote desktop
    /// tracks the window without waiting for a manual resize.
    private func requestFitResolution() {
        guard configuration.dynamicResolution, displayMode == .fit else { return }
        scheduleResolutionRequest(host.fitSize)
    }

    /// Coalesces window resizes so the server sees one layout per pause. Works
    /// in pixels so a move between displays of different density re-requests
    /// even when the point size is unchanged.
    private func scheduleResolutionRequest(_ size: CGSize) {
        let target = pixelSize(for: size)
        guard target.width >= 200, target.height >= 200, target != requestedPixelSize else { return }
        resizeTask?.cancel()
        resizeTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(250))
            guard !Task.isCancelled, let self else { return }
            guard self.framebufferSize != target else { return }
            guard self.request(pixels: target) else { return }
            self.requestedPixelSize = target
        }
    }

    private func handle(input event: RDPInputEvent) {
        guard let handle else { return }
        switch event {
        case let .pointer(button, down, x, y):
            var flags = down ? RDPWire.ptrDown : 0
            switch button {
            case .left: flags |= RDPWire.ptrButton1
            case .right: flags |= RDPWire.ptrButton2
            case .middle: flags |= RDPWire.ptrButton3
            }
            crdp_session_send_pointer(handle, flags, x, y)
        case let .pointerMove(x, y):
            crdp_session_send_pointer(handle, RDPWire.ptrMove, x, y)
        case let .scroll(delta, horizontal, x, y):
            let magnitude = UInt16(min(abs(delta), 0xFF) & Int(RDPWire.wheelRotationMask))
            var flags = (horizontal ? RDPWire.ptrHWheel : RDPWire.ptrWheel) | magnitude
            if delta < 0 { flags |= RDPWire.wheelNegative }
            crdp_session_send_pointer(handle, flags, x, y)
        case let .key(macKeyCode, down):
            var extended = false
            let scancode = crdp_scancode_for_mac_keycode(macKeyCode, &extended)
            guard scancode != 0 else { return }
            var flags: UInt16 = extended ? RDPWire.kbdExtended : 0
            if !down { flags |= RDPWire.kbdRelease }
            crdp_session_send_key(handle, flags, scancode)
        }
    }

    private func transition(to newState: RemoteDesktopSessionState) {
        guard newState != state else { return }
        state = newState
        eventHandler?(.stateChanged(newState))
    }

    static let createFailureMessage = "Could not create the RDP session."
    static let authenticationFailureMessage = "Authentication failed. Check the username, domain and password."
    static let dnsFailureMessage = "The server could not be found."
    static let tlsFailureMessage = "The secure connection could not be established."
    static let connectFailureMessage = "The connection to the server did not complete."
    static let genericFailureMessage = "The connection ended unexpectedly."

    /// Maps the bridge's failure class. Clean closes and user cancellations
    /// (a rejected certificate) are not failures.
    static func failure(from failure: crdp_failure) -> RemoteDesktopSessionFailure? {
        switch failure {
        case CRDP_FAILURE_NONE, CRDP_FAILURE_CANCELLED:
            return nil
        case CRDP_FAILURE_AUTHENTICATION:
            return RemoteDesktopSessionFailure(message: authenticationFailureMessage, isAuthenticationFailure: true)
        case CRDP_FAILURE_DNS:
            return RemoteDesktopSessionFailure(message: dnsFailureMessage)
        case CRDP_FAILURE_TLS:
            return RemoteDesktopSessionFailure(message: tlsFailureMessage)
        case CRDP_FAILURE_CONNECT:
            return RemoteDesktopSessionFailure(message: connectFailureMessage)
        default:
            return RemoteDesktopSessionFailure(message: genericFailureMessage)
        }
    }
}

private extension RDPConnectionQuality {
    var bridgeValue: crdp_connection_type {
        switch self {
        case .automatic: CRDP_CONNECTION_DEFAULT
        case .lan: CRDP_CONNECTION_LAN
        case .broadband: CRDP_CONNECTION_BROADBAND
        case .modem: CRDP_CONNECTION_MODEM
        }
    }
}

/// Wire values from FreeRDP's input.h. Defined here because the C bridge header
/// keeps FreeRDP's headers private.
private enum RDPWire {
    static let ptrMove: UInt16 = 0x0800
    static let ptrDown: UInt16 = 0x8000
    static let ptrButton1: UInt16 = 0x1000
    static let ptrButton2: UInt16 = 0x2000
    static let ptrButton3: UInt16 = 0x4000
    static let ptrWheel: UInt16 = 0x0200
    static let ptrHWheel: UInt16 = 0x0400
    static let wheelNegative: UInt16 = 0x0100
    static let wheelRotationMask: UInt16 = 0x01FF
    static let kbdExtended: UInt16 = 0x0100
    static let kbdRelease: UInt16 = 0x8000
}

private func withOptionalCString<Result>(_ string: String?, _ body: (UnsafePointer<CChar>?) -> Result) -> Result {
    guard let string else { return body(nil) }
    return string.withCString(body)
}

// MARK: - C callback trampolines

private final class RDPCallbackContext: @unchecked Sendable {
    weak var session: RDPSession?

    @MainActor
    init(session: RDPSession) {
        self.session = session
    }
}

private func callbackContext(from context: UnsafeMutableRawPointer?) -> RDPCallbackContext? {
    guard let context else { return nil }
    return Unmanaged<RDPCallbackContext>.fromOpaque(context).takeUnretainedValue()
}

private func rdpStateChanged(_ context: UnsafeMutableRawPointer?, _ state: crdp_state, _ failure: crdp_failure) {
    guard let callbackContext = callbackContext(from: context) else { return }
    Task { @MainActor in
        callbackContext.session?.stateChanged(state, failure: failure)
    }
}

private func rdpFrameResized(_ context: UnsafeMutableRawPointer?, _ buffer: UnsafePointer<UInt8>?, _ width: UInt32, _ height: UInt32, _ stride: UInt32) {
    guard let callbackContext = callbackContext(from: context), let buffer else { return }
    let boxed = SendableBox(buffer)
    Task { @MainActor in
        callbackContext.session?.frameResized(
            buffer: boxed.value,
            width: Int(width),
            height: Int(height),
            stride: Int(stride))
    }
}

private func rdpClipboardText(_ context: UnsafeMutableRawPointer?, _ utf8: UnsafePointer<CChar>?) {
    guard let callbackContext = callbackContext(from: context), let utf8 else { return }
    let text = String(cString: utf8) // copied; the C string dies with the call
    Task { @MainActor in
        callbackContext.session?.clipboardTextReceived(text)
    }
}

private func rdpFrameUpdated(_ context: UnsafeMutableRawPointer?, _ x: UInt32, _ y: UInt32, _ width: UInt32, _ height: UInt32) {
    guard let callbackContext = callbackContext(from: context) else { return }
    Task { @MainActor in
        callbackContext.session?.frameUpdated()
    }
}

/// Blocks the client thread until the main actor returns a verdict. This is how
/// certificate verification pauses connection setup for a native prompt.
private func rdpVerifyCertificate(_ context: UnsafeMutableRawPointer?, _ certificate: UnsafePointer<crdp_certificate>?) -> crdp_cert_verdict {
    guard let certificate else { return CRDP_CERT_REJECT }
    let cert = certificate.pointee
    let swiftCertificate = RDPCertificate(
        host: String(cString: cert.host),
        port: Int(cert.port),
        commonName: cert.common_name.map(String.init(cString:)) ?? "",
        subject: cert.subject.map(String.init(cString:)) ?? "",
        issuer: cert.issuer.map(String.init(cString:)) ?? "",
        fingerprint: cert.fingerprint.map(String.init(cString:)) ?? "",
        hostMismatch: cert.host_mismatch,
        changed: cert.changed)

    guard let callbackContext = callbackContext(from: context) else { return CRDP_CERT_REJECT }
    let verdictBox = VerdictBox()
    let semaphore = DispatchSemaphore(value: 0)
    Task { @MainActor in
        verdictBox.verdict = await callbackContext.session?.verifyCertificate(swiftCertificate) ?? .reject
        semaphore.signal()
    }
    semaphore.wait()
    switch verdictBox.verdict {
    case .acceptAndStore: return CRDP_CERT_ACCEPT_AND_STORE
    case .acceptOnce: return CRDP_CERT_ACCEPT_ONCE
    case .reject: return CRDP_CERT_REJECT
    }
}

private final class VerdictBox: @unchecked Sendable {
    var verdict: RDPCertificateVerdict = .reject
}

/// FreeRDP's pointers predate Sendable; they cross to the main actor here only.
private struct SendableBox<Value>: @unchecked Sendable {
    let value: Value
    init(_ value: Value) { self.value = value }
}
