import AppKit
import CConstellationRDP
import CoreGraphics
import QuartzCore

/// Draws the BGRX frame buffer the C bridge owns and forwards keyboard and
/// pointer input back to it.
///
/// The bridge writes the buffer on FreeRDP's client thread, so the view never
/// hands that live memory to Core Animation. Instead a display link coalesces
/// updates to the screen refresh and, when dirty, copies the buffer into an
/// immutable snapshot for the layer — one rebuild per frame at most, and no
/// tearing from CA reading memory mid-write.
@MainActor
final class RDPSurfaceView: NSView {
    /// Sends translated input to the live session. Set by `RDPSession`.
    var inputSink: ((RDPInputEvent) -> Void)?

    private var buffer: UnsafePointer<UInt8>?
    private var bufferSize = CGSize.zero
    private var stride = 0
    private let colorSpace = CGColorSpaceCreateDeviceRGB()
    private var previousModifiers: NSEvent.ModifierFlags = []
    private var displayLink: CADisplayLink?
    private var needsSnapshot = false

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.backgroundColor = NSColor.black.cgColor
        layer?.contentsGravity = .resize
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window != nil { startDisplayLink() } else { stopDisplayLink() }
    }

    /// Points at a freshly allocated frame buffer. The pointer must stay valid
    /// until the next call or `clear()`.
    func setFrameBuffer(_ pointer: UnsafePointer<UInt8>, width: Int, height: Int, stride: Int) {
        buffer = pointer
        bufferSize = CGSize(width: width, height: height)
        self.stride = stride
        needsSnapshot = true
    }

    func clear() {
        buffer = nil
        bufferSize = .zero
        needsSnapshot = false
        layer?.contents = nil
    }

    func markDirty() { needsSnapshot = true }

    var framebufferSize: CGSize? { bufferSize == .zero ? nil : bufferSize }

    // MARK: Display link

    private func startDisplayLink() {
        guard displayLink == nil else { return }
        let link = displayLink(target: self, selector: #selector(displayLinkFired))
        link.add(to: .main, forMode: .common)
        displayLink = link
    }

    private func stopDisplayLink() {
        displayLink?.invalidate()
        displayLink = nil
    }

    @objc private func displayLinkFired(_ link: CADisplayLink) {
        guard needsSnapshot else { return }
        needsSnapshot = false
        refreshImage()
    }

    /// Copies the current frame buffer into an immutable image. The copy makes
    /// the snapshot safe for Core Animation to read while the client thread
    /// keeps writing the live buffer.
    private func refreshImage() {
        guard let buffer, bufferSize != .zero else { return }
        let length = stride * Int(bufferSize.height)
        guard let data = CFDataCreate(nil, buffer, length),
              let provider = CGDataProvider(data: data) else {
            return
        }
        // BGRX in memory: little-endian 32-bit with the alpha byte ignored.
        let bitmapInfo = CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipFirst.rawValue).union(.byteOrder32Little)
        let image = CGImage(
            width: Int(bufferSize.width),
            height: Int(bufferSize.height),
            bitsPerComponent: 8,
            bitsPerPixel: 32,
            bytesPerRow: stride,
            space: colorSpace,
            bitmapInfo: bitmapInfo,
            provider: provider,
            decode: nil,
            shouldInterpolate: false,
            intent: .defaultIntent)
        layer?.contents = image
    }

    // MARK: Pointer

    /// Maps a view location to remote framebuffer coordinates (top-left origin).
    private func remotePoint(_ event: NSEvent) -> (x: UInt16, y: UInt16)? {
        guard bufferSize != .zero else { return nil }
        let local = convert(event.locationInWindow, from: nil)
        let scaleX = bufferSize.width / max(bounds.width, 1)
        let scaleY = bufferSize.height / max(bounds.height, 1)
        let x = (local.x * scaleX).clamped(to: 0...(bufferSize.width - 1))
        let y = (local.y * scaleY).clamped(to: 0...(bufferSize.height - 1))
        return (UInt16(x), UInt16(y))
    }

    private func sendButton(_ event: NSEvent, button: RDPPointerButton, down: Bool) {
        guard let point = remotePoint(event) else { return }
        inputSink?(.pointer(button: button, down: down, x: point.x, y: point.y))
    }

    override func mouseDown(with event: NSEvent) { sendButton(event, button: .left, down: true) }
    override func mouseUp(with event: NSEvent) { sendButton(event, button: .left, down: false) }
    override func rightMouseDown(with event: NSEvent) { sendButton(event, button: .right, down: true) }
    override func rightMouseUp(with event: NSEvent) { sendButton(event, button: .right, down: false) }
    override func otherMouseDown(with event: NSEvent) { sendButton(event, button: .middle, down: true) }
    override func otherMouseUp(with event: NSEvent) { sendButton(event, button: .middle, down: false) }

    override func mouseMoved(with event: NSEvent) { sendMove(event) }
    override func mouseDragged(with event: NSEvent) { sendMove(event) }
    override func rightMouseDragged(with event: NSEvent) { sendMove(event) }
    override func otherMouseDragged(with event: NSEvent) { sendMove(event) }

    private func sendMove(_ event: NSEvent) {
        guard let point = remotePoint(event) else { return }
        inputSink?(.pointerMove(x: point.x, y: point.y))
    }

    override func scrollWheel(with event: NSEvent) {
        guard let point = remotePoint(event) else { return }
        let vertical = Int(event.scrollingDeltaY.rounded())
        let horizontal = Int(event.scrollingDeltaX.rounded())
        if vertical != 0 { inputSink?(.scroll(delta: vertical, horizontal: false, x: point.x, y: point.y)) }
        if horizontal != 0 { inputSink?(.scroll(delta: horizontal, horizontal: true, x: point.x, y: point.y)) }
    }

    // MARK: Keyboard

    override func keyDown(with event: NSEvent) {
        syncModifiers(event)
        inputSink?(.key(macKeyCode: event.keyCode, down: true))
    }

    override func keyUp(with event: NSEvent) {
        syncModifiers(event)
        inputSink?(.key(macKeyCode: event.keyCode, down: false))
    }

    override func flagsChanged(with event: NSEvent) {
        syncModifiers(event)
    }

    /// Turns a modifier-flags change into individual modifier key presses.
    private func syncModifiers(_ event: NSEvent) {
        let modifiers = event.modifierFlags
        let changes: [(NSEvent.ModifierFlags, UInt16)] = [
            (.shift, 0x38),    // left shift
            (.control, 0x3B),  // left control
            (.option, 0x3A),   // left option
            (.command, 0x37),  // left command (maps to Windows key)
            (.capsLock, 0x39),
        ]
        for (flag, keyCode) in changes where modifiers.contains(flag) != previousModifiers.contains(flag) {
            inputSink?(.key(macKeyCode: keyCode, down: modifiers.contains(flag)))
        }
        previousModifiers = modifiers
    }
}

enum RDPPointerButton: Sendable {
    case left, right, middle
}

/// Input translated from AppKit, resolved to RDP wire values in `RDPSession`.
enum RDPInputEvent: Sendable {
    case pointer(button: RDPPointerButton, down: Bool, x: UInt16, y: UInt16)
    case pointerMove(x: UInt16, y: UInt16)
    case scroll(delta: Int, horizontal: Bool, x: UInt16, y: UInt16)
    case key(macKeyCode: UInt16, down: Bool)
}

private extension CGFloat {
    func clamped(to range: ClosedRange<CGFloat>) -> CGFloat {
        Swift.min(Swift.max(self, range.lowerBound), range.upperBound)
    }
}
