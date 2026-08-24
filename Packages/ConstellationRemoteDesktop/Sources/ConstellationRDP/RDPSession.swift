import AppKit
import CConstellationRDP
import Foundation

/// One FreeRDP connection and the AppKit view that shows it. Everything public
/// happens on the main actor; the C bridge's callbacks arrive on the client
/// thread and hop here.
///
/// This is the Milestone 4 proof adapter. It is deliberately self-contained and
/// does not yet conform to the shared `RemoteDesktopSession` protocol or plug
/// into the app shell; unifying the VNC and RDP session surfaces is milestone
/// work once the proof holds.
@MainActor
public final class RDPSession {
    public let view: NSView
    public private(set) var state: RDPSessionState = .idle
    public private(set) var framebufferSize: CGSize?
    public var eventHandler: (@MainActor (RDPSessionEvent) -> Void)?
    public var displayMode: RDPDisplayMode = .fit {
        didSet { host.displayMode = displayMode }
    }

    private let configuration: RDPSessionConfiguration
    private let passwordProvider: RDPPasswordProvider
    private let verifier: RDPCertificateVerifier
    private let host: RDPHostView
    private let surface = RDPSurfaceView(frame: NSRect(x: 0, y: 0, width: 1280, height: 800))
    private var handle: OpaquePointer?
    private var connectTask: Task<Void, Never>?

    public init(
        configuration: RDPSessionConfiguration,
        password: @escaping RDPPasswordProvider,
        verifyCertificate: @escaping RDPCertificateVerifier
    ) {
        self.configuration = configuration
        self.passwordProvider = password
        self.verifier = verifyCertificate
        host = RDPHostView(frame: NSRect(x: 0, y: 0, width: 1280, height: 800))
        view = host
        surface.inputSink = { [weak self] event in self?.handle(input: event) }
    }

    isolated deinit {
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

    /// Hands keyboard focus to the remote desktop view.
    public func focus() {
        surface.window?.makeFirstResponder(surface)
    }

    /// Requests a new desktop resolution (no-op unless dynamic resolution was
    /// negotiated and the session is connected).
    public func requestResolution(width: Int, height: Int) {
        guard let handle else { return }
        crdp_session_request_resolution(handle, UInt32(max(0, width)), UInt32(max(0, height)))
    }

    // MARK: Session start

    private func startSession(password: String?) {
        let callbacks = crdp_callbacks(
            context: Unmanaged.passUnretained(self).toOpaque(),
            state_changed: rdpStateChanged,
            frame_resized: rdpFrameResized,
            frame_updated: rdpFrameUpdated,
            verify_certificate: rdpVerifyCertificate)

        configuration.host.withCString { hostPtr in
            withOptionalCString(configuration.username) { userPtr in
                withOptionalCString(configuration.domain) { domainPtr in
                    withOptionalCString(password) { passwordPtr in
                        var config = crdp_config(
                            host: hostPtr,
                            port: UInt32(max(0, configuration.port)),
                            username: userPtr,
                            domain: domainPtr,
                            password: passwordPtr,
                            width: UInt32(max(1, configuration.width)),
                            height: UInt32(max(1, configuration.height)),
                            dynamic_resolution: configuration.dynamicResolution,
                            share_clipboard: configuration.sharesClipboard)
                        var callbacksCopy = callbacks
                        handle = crdp_session_create(&config, &callbacksCopy)
                    }
                }
            }
        }

        guard handle != nil else {
            transition(to: .disconnected(RDPSessionFailure(kind: .generic, message: "Could not create the RDP session.")))
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
        case CRDP_STATE_DISCONNECTED:
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
    }

    fileprivate func frameUpdated() {
        surface.markDirty()
    }

    fileprivate func verifyCertificate(_ certificate: RDPCertificate) async -> RDPCertificateVerdict {
        await verifier(certificate)
    }

    // MARK: Helpers

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

    private func transition(to newState: RDPSessionState) {
        guard newState != state else { return }
        state = newState
        eventHandler?(.stateChanged(newState))
    }

    static func failure(from failure: crdp_failure) -> RDPSessionFailure? {
        switch failure {
        case CRDP_FAILURE_NONE, CRDP_FAILURE_CANCELLED:
            return nil
        case CRDP_FAILURE_AUTHENTICATION:
            return RDPSessionFailure(kind: .authentication, message: "Authentication failed.")
        case CRDP_FAILURE_DNS:
            return RDPSessionFailure(kind: .dns, message: "The server could not be found.")
        case CRDP_FAILURE_TLS:
            return RDPSessionFailure(kind: .tls, message: "The secure connection could not be established.")
        case CRDP_FAILURE_CONNECT:
            return RDPSessionFailure(kind: .connect, message: "Could not reach the server.")
        default:
            return RDPSessionFailure(kind: .generic, message: "The connection ended unexpectedly.")
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

private func session(from context: UnsafeMutableRawPointer?) -> RDPSession? {
    guard let context else { return nil }
    return Unmanaged<RDPSession>.fromOpaque(context).takeUnretainedValue()
}

private func rdpStateChanged(_ context: UnsafeMutableRawPointer?, _ state: crdp_state, _ failure: crdp_failure) {
    let boxed = SendableBox((context, state, failure))
    Task { @MainActor in
        session(from: boxed.value.0)?.stateChanged(boxed.value.1, failure: boxed.value.2)
    }
}

private func rdpFrameResized(_ context: UnsafeMutableRawPointer?, _ buffer: UnsafePointer<UInt8>?, _ width: UInt32, _ height: UInt32, _ stride: UInt32) {
    guard let buffer else { return }
    let boxed = SendableBox((context, buffer, Int(width), Int(height), Int(stride)))
    Task { @MainActor in
        session(from: boxed.value.0)?.frameResized(buffer: boxed.value.1, width: boxed.value.2, height: boxed.value.3, stride: boxed.value.4)
    }
}

private func rdpFrameUpdated(_ context: UnsafeMutableRawPointer?, _ x: UInt32, _ y: UInt32, _ width: UInt32, _ height: UInt32) {
    let boxed = SendableBox(context)
    Task { @MainActor in
        session(from: boxed.value)?.frameUpdated()
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

    let verdictBox = VerdictBox()
    let semaphore = DispatchSemaphore(value: 0)
    let boxed = SendableBox(context)
    Task { @MainActor in
        verdictBox.verdict = await session(from: boxed.value)?.verifyCertificate(swiftCertificate) ?? .reject
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
