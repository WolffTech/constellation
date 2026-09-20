// SPDX-FileCopyrightText: 2026 Nick Wolff <nick@wolff.tech>
// SPDX-License-Identifier: GPL-3.0-only

import AppKit
import CConstellationRDP
import CoreGraphics

/// The cursor the server wants over the desktop. RDP leaves the cursor out of
/// the frame, so resize arrows, I-beams and busy spinners only exist here.
enum RDPCursorShape: Sendable, Equatable {
    case systemDefault
    case hidden
    case image(RDPCursorImage)

    /// Copies the bridge's cursor; its pixels die with the callback.
    init(_ cursor: crdp_cursor) {
        switch cursor.kind {
        case CRDP_CURSOR_HIDDEN:
            self = .hidden
        case CRDP_CURSOR_IMAGE:
            let length = Int(cursor.width) * Int(cursor.height) * 4
            guard let pixels = cursor.pixels, length > 0 else {
                self = .systemDefault
                return
            }
            self = .image(RDPCursorImage(
                pixels: Data(bytes: pixels, count: length),
                width: Int(cursor.width),
                height: Int(cursor.height),
                hotspot: CGPoint(x: Int(cursor.hotspot_x), y: Int(cursor.hotspot_y))))
        default:
            self = .systemDefault
        }
    }

    /// `pointsPerPixel` is how large one remote pixel is drawn, so the cursor
    /// scales with the desktop: half size on a Retina session, larger when a
    /// small desktop is fitted to a big window.
    @MainActor
    func makeCursor(pointsPerPixel: CGFloat) -> NSCursor {
        switch self {
        case .systemDefault:
            return .arrow
        case .hidden:
            return Self.invisible
        case .image(let image):
            return image.makeCursor(pointsPerPixel: pointsPerPixel) ?? .arrow
        }
    }

    /// A transparent cursor rather than `NSCursor.hide()`, whose calls must
    /// balance and which would leak past the view's edge.
    @MainActor
    private static let invisible = NSCursor(
        image: NSImage(size: NSSize(width: 1, height: 1), flipped: false) { _ in true },
        hotSpot: .zero)
}

struct RDPCursorImage: Sendable, Equatable {
    /// `width * height * 4` bytes of BGRA with straight alpha.
    let pixels: Data
    let width: Int
    let height: Int
    /// From the top-left, in remote pixels.
    let hotspot: CGPoint

    @MainActor
    func makeCursor(pointsPerPixel: CGFloat) -> NSCursor? {
        guard width > 0, height > 0, pixels.count == width * height * 4, pointsPerPixel > 0,
              let provider = CGDataProvider(data: pixels as CFData) else {
            return nil
        }
        // BGRA in memory: little-endian 32-bit with alpha first, not premultiplied.
        let bitmapInfo = CGBitmapInfo(rawValue: CGImageAlphaInfo.first.rawValue).union(.byteOrder32Little)
        guard let image = CGImage(
            width: width,
            height: height,
            bitsPerComponent: 8,
            bitsPerPixel: 32,
            bytesPerRow: width * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: bitmapInfo,
            provider: provider,
            decode: nil,
            shouldInterpolate: true,
            intent: .defaultIntent) else {
            return nil
        }
        // A bitmap rep with a point size smaller than its pixel size keeps the
        // extra pixels for Retina; `NSImage(cgImage:size:)` resamples them away.
        let size = NSSize(width: CGFloat(width) * pointsPerPixel, height: CGFloat(height) * pointsPerPixel)
        let representation = NSBitmapImageRep(cgImage: image)
        representation.size = size
        let cursorImage = NSImage(size: size)
        cursorImage.addRepresentation(representation)
        let hotSpot = NSPoint(
            x: min(hotspot.x * pointsPerPixel, size.width),
            y: min(hotspot.y * pointsPerPixel, size.height))
        return NSCursor(image: cursorImage, hotSpot: hotSpot)
    }
}
