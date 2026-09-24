// SPDX-FileCopyrightText: 2026 Nick Wolff <nick@wolff.tech>
// SPDX-License-Identifier: GPL-3.0-only

import AppKit
import ConstellationRemoteDesktop
import Testing
@testable import ConstellationVNC

@MainActor
struct RemoteDesktopHostViewTests {
    /// The desktop's on-screen size, in the host's points.
    private func displayedSize(hostSize: CGSize, framebuffer: CGSize, mode: RemoteDesktopDisplayMode) -> CGSize {
        let host = RemoteDesktopHostView(frame: NSRect(origin: .zero, size: hostSize))
        host.displayMode = mode
        let desktop = NSView()
        host.show(desktop, framebufferSize: framebuffer)
        host.layoutSubtreeIfNeeded()
        return host.convert(desktop.bounds, from: desktop).size
    }

    @Test func fitScalesDownAndUpPreservingAspect() {
        let desktop = CGSize(width: 1920, height: 1080)
        #expect(displayedSize(hostSize: CGSize(width: 960, height: 600), framebuffer: desktop, mode: .fit) == CGSize(width: 960, height: 540))
        #expect(displayedSize(hostSize: CGSize(width: 4000, height: 2160), framebuffer: desktop, mode: .fit) == CGSize(width: 3840, height: 2160))
    }

    @Test func actualSizeShowsOneRemotePixelPerDevicePixel() {
        // Without a window the backing scale is 1, so pixels and points match.
        let desktop = CGSize(width: 1920, height: 1080)
        #expect(displayedSize(hostSize: CGSize(width: 960, height: 600), framebuffer: desktop, mode: .actualSize) == desktop)
    }
}
