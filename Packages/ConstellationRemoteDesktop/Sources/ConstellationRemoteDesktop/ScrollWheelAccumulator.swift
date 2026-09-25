// SPDX-FileCopyrightText: 2026 Nick Wolff <nick@wolff.tech>
// SPDX-License-Identifier: GPL-3.0-only

import AppKit

/// Converts AppKit scroll deltas into remote wheel steps. A wheel "notch"
/// is one click of a physical mouse wheel; protocols divide it into
/// `stepsPerNotch` steps (RDP uses 120, VNC only whole clicks). Fractions
/// carry over between events so slow trackpad scrolls still add up.
public struct ScrollWheelAccumulator: Sendable {
    /// Trackpad points per notch. macOS scrolls about 10 points per line and
    /// reports mouse wheels in lines, so one line maps to one notch.
    static let pointsPerNotch: CGFloat = 10

    public let stepsPerNotch: Int
    private var pendingX: CGFloat = 0
    private var pendingY: CGFloat = 0

    public init(stepsPerNotch: Int) {
        self.stepsPerNotch = stepsPerNotch
    }

    /// Whole steps to send. Positive `x` scrolls right and positive `y`
    /// scrolls up, matching remote wheel conventions.
    public mutating func steps(for event: NSEvent) -> (x: Int, y: Int) {
        steps(deltaX: event.scrollingDeltaX, deltaY: event.scrollingDeltaY, isPrecise: event.hasPreciseScrollingDeltas)
    }

    /// AppKit convention: positive `deltaX` scrolls left, positive `deltaY`
    /// scrolls up. Precise deltas are points; imprecise deltas are lines.
    mutating func steps(deltaX: CGFloat, deltaY: CGFloat, isPrecise: Bool) -> (x: Int, y: Int) {
        let scale = CGFloat(stepsPerNotch) / (isPrecise ? Self.pointsPerNotch : 1)
        pendingX -= deltaX * scale
        pendingY += deltaY * scale
        let x = Int(pendingX.rounded(.towardZero))
        let y = Int(pendingY.rounded(.towardZero))
        pendingX -= CGFloat(x)
        pendingY -= CGFloat(y)
        return (x, y)
    }
}
