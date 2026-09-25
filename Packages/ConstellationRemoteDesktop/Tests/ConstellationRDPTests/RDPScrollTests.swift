// SPDX-FileCopyrightText: 2026 Nick Wolff <nick@wolff.tech>
// SPDX-License-Identifier: GPL-3.0-only

import Testing
@testable import ConstellationRDP
@testable import ConstellationRemoteDesktop

struct RDPScrollTests {
    @Test func mouseWheelLinesBecomeWholeNotches() {
        var wheel = ScrollWheelAccumulator(stepsPerNotch: 120)
        #expect(wheel.steps(deltaX: 0, deltaY: 1, isPrecise: false) == (0, 120))
        #expect(wheel.steps(deltaX: 0, deltaY: -3, isPrecise: false) == (0, -360))
    }

    @Test func trackpadPointsAccumulateAcrossEvents() {
        var wheel = ScrollWheelAccumulator(stepsPerNotch: 1)
        #expect(wheel.steps(deltaX: 0, deltaY: 6, isPrecise: true) == (0, 0))
        #expect(wheel.steps(deltaX: 0, deltaY: 6, isPrecise: true) == (0, 1))
        #expect(wheel.steps(deltaX: 0, deltaY: 8, isPrecise: true) == (0, 1))
    }

    @Test func horizontalDeltaIsFlippedToScrollRight() {
        // AppKit's positive deltaX scrolls left; wheels use positive for right.
        var wheel = ScrollWheelAccumulator(stepsPerNotch: 1)
        #expect(wheel.steps(deltaX: 2, deltaY: 0, isPrecise: false) == (-2, 0))
    }

    @Test func wheelFlagsUseNineBitTwosComplement() {
        #expect(RDPWire.wheelFlags(delta: 120, horizontal: false) == [0x0200 | 0x78])
        // -120 is 0x188: the sign bit doubles as PTR_FLAGS_WHEEL_NEGATIVE.
        #expect(RDPWire.wheelFlags(delta: -120, horizontal: true) == [0x0400 | 0x188])
        #expect(RDPWire.wheelFlags(delta: 0, horizontal: false).isEmpty)
    }

    @Test func largeWheelDeltasSplitIntoSeveralEvents() {
        #expect(RDPWire.wheelFlags(delta: 360, horizontal: false) == [0x0200 | 0xFF, 0x0200 | 105])
        #expect(RDPWire.wheelFlags(delta: -300, horizontal: false) == [0x0200 | 0x101, 0x0200 | 0x1D3])
    }
}
