// SPDX-FileCopyrightText: 2026 Nick Wolff <nick@wolff.tech>
// SPDX-License-Identifier: GPL-3.0-only

import AppKit
import CConstellationRDP
import Testing
@testable import ConstellationRDP

@MainActor
struct RDPCursorTests {
    /// A 2x1 cursor: opaque red, then fully transparent. BGRA byte order.
    private static let pixels: [UInt8] = [0, 0, 255, 255, 0, 0, 0, 0]

    @Test func copiesTheBridgeCursor() {
        let shape = Self.pixels.withUnsafeBufferPointer { buffer in
            RDPCursorShape(crdp_cursor(
                kind: CRDP_CURSOR_IMAGE, pixels: buffer.baseAddress,
                width: 2, height: 1, hotspot_x: 1, hotspot_y: 0))
        }
        #expect(shape == .image(RDPCursorImage(
            pixels: Data(Self.pixels), width: 2, height: 1, hotspot: CGPoint(x: 1, y: 0))))
        #expect(RDPCursorShape(crdp_cursor(kind: CRDP_CURSOR_HIDDEN, pixels: nil, width: 0, height: 0, hotspot_x: 0, hotspot_y: 0)) == .hidden)
        // An image without pixels is unusable; show the arrow rather than nothing.
        #expect(RDPCursorShape(crdp_cursor(kind: CRDP_CURSOR_IMAGE, pixels: nil, width: 2, height: 1, hotspot_x: 0, hotspot_y: 0)) == .systemDefault)
    }

    /// On a Retina session one remote pixel is half a point, so the cursor and
    /// its hotspot shrink with the desktop while keeping every pixel.
    @Test func scalesTheCursorWithTheDesktop() throws {
        let image = RDPCursorImage(
            pixels: Data(repeating: 255, count: 64 * 64 * 4), width: 64, height: 64, hotspot: CGPoint(x: 20, y: 10))
        let cursor = try #require(image.makeCursor(pointsPerPixel: 0.5))
        #expect(cursor.image.size == NSSize(width: 32, height: 32))
        #expect(cursor.hotSpot == NSPoint(x: 10, y: 5))
        #expect(cursor.image.representations.first?.pixelsWide == 64)
    }

    @Test func decodesStraightAlphaBGRA() throws {
        let image = RDPCursorImage(pixels: Data(Self.pixels), width: 2, height: 1, hotspot: .zero)
        let cursor = try #require(image.makeCursor(pointsPerPixel: 1))
        let bitmap = NSBitmapImageRep(cgImage: try #require(cursor.image.cgImage(forProposedRect: nil, context: nil, hints: nil)))
        let red = try #require(bitmap.colorAt(x: 0, y: 0))
        #expect(red.redComponent == 1 && red.blueComponent == 0 && red.alphaComponent == 1)
        #expect(bitmap.colorAt(x: 1, y: 0)?.alphaComponent == 0)
    }

    /// The server picks the cursor from where the pointer is, so it must hear
    /// about hovering, not just clicks and drags.
    @Test func forwardsHoverMovesToTheDesktop() throws {
        let surface = RDPSurfaceView(frame: NSRect(x: 0, y: 0, width: 100, height: 100))
        let pixels = [UInt8](repeating: 0, count: 200 * 200 * 4)
        var moves: [RDPInputEvent] = []
        surface.inputSink = { moves.append($0) }
        surface.updateTrackingAreas()
        #expect(surface.trackingAreas.contains { $0.options.contains(.mouseMoved) })

        try pixels.withUnsafeBufferPointer { buffer in
            surface.setFrameBuffer(try #require(buffer.baseAddress), width: 200, height: 200, stride: 800)
            let event = try #require(NSEvent.mouseEvent(
                with: .mouseMoved, location: NSPoint(x: 50, y: 75), modifierFlags: [], timestamp: 0,
                windowNumber: 0, context: nil, eventNumber: 0, clickCount: 0, pressure: 0))
            surface.mouseMoved(with: event)
            surface.clear()
        }
        // The view is flipped and the desktop is twice its size.
        guard case .pointerMove(x: 100, y: 50)? = moves.first else {
            Issue.record("expected a pointer move, got \(moves)")
            return
        }
    }

    @Test func rejectsATruncatedImage() {
        let image = RDPCursorImage(pixels: Data(count: 4), width: 2, height: 2, hotspot: .zero)
        #expect(image.makeCursor(pointsPerPixel: 1) == nil)
        // Compared outside #expect: its operator capture traps intermittently on `===`.
        let fallsBackToArrow = RDPCursorShape.image(image).makeCursor(pointsPerPixel: 1) === NSCursor.arrow
        #expect(fallsBackToArrow)
    }
}
