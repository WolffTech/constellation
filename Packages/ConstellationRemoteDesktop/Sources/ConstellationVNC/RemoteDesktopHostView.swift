// SPDX-FileCopyrightText: 2026 Nick Wolff <nick@wolff.tech>
// SPDX-License-Identifier: GPL-3.0-only

import AppKit
import ConstellationRemoteDesktop
import RoyalVNCKit

/// Hosts the framebuffer view in a scroll view and applies the display mode.
/// The framebuffer view stays at the framebuffer's size, so its own scaling
/// (downscale only, one remote pixel per point) never engages; the scroll
/// view's magnification does the scaling instead. "Fit" scales up or down to
/// the clip view while preserving aspect; "actual size" shows one remote pixel
/// per device pixel and scrolls. AppKit's coordinate conversion accounts for
/// magnification, so mouse input still maps to remote pixels.
@MainActor
final class RemoteDesktopHostView: NSView {
    var displayMode: RemoteDesktopDisplayMode = .fit {
        didSet { applyDisplayMode() }
    }

    private let scrollView = VNCScrollView(frame: .zero)
    private var framebufferSize: CGSize = .zero

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.backgroundColor = NSColor.black.cgColor
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.contentView = CenteringClipView()
        scrollView.drawsBackground = false
        scrollView.autohidesScrollers = true
        // Magnification is set programmatically; keep the range wide enough
        // for any desktop and window size.
        scrollView.minMagnification = 0.01
        scrollView.maxMagnification = 100
        addSubview(scrollView)
        NSLayoutConstraint.activate([
            scrollView.leadingAnchor.constraint(equalTo: leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: trailingAnchor),
            scrollView.topAnchor.constraint(equalTo: topAnchor),
            scrollView.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func accessibilityRole() -> NSAccessibility.Role? { .group }
    override func accessibilityLabel() -> String? {
        displayMode == .fit ? "Remote desktop, fit to window" : "Remote desktop, actual size"
    }

    func show(_ view: NSView, framebufferSize: CGSize) {
        self.framebufferSize = framebufferSize
        view.frame = NSRect(origin: .zero, size: framebufferSize)
        scrollView.documentView = view
        applyDisplayMode()
    }

    func clear() {
        scrollView.documentView = nil
        framebufferSize = .zero
    }

    override func layout() {
        super.layout()
        if displayMode == .fit { applyDisplayMode() }
    }

    /// Moving to a display with a different pixel density changes the
    /// magnification that shows one remote pixel per device pixel.
    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        applyDisplayMode()
    }

    private func applyDisplayMode() {
        guard scrollView.documentView != nil, framebufferSize.width > 0, framebufferSize.height > 0 else { return }
        switch displayMode {
        case .fit:
            scrollView.hasVerticalScroller = false
            scrollView.hasHorizontalScroller = false
            // The clip view's frame, not its bounds: bounds are already magnified.
            let clip = scrollView.contentSize
            guard clip.width > 0, clip.height > 0 else { return }
            scrollView.magnification = min(clip.width / framebufferSize.width, clip.height / framebufferSize.height)
        case .actualSize:
            scrollView.hasVerticalScroller = true
            scrollView.hasHorizontalScroller = true
            scrollView.magnification = 1 / (window?.backingScaleFactor ?? 1)
        }
    }
}

/// Centres a document smaller than the visible area instead of pinning it to
/// the bottom-left corner.
private final class CenteringClipView: NSClipView {
    override func constrainBoundsRect(_ proposedBounds: NSRect) -> NSRect {
        var rect = super.constrainBoundsRect(proposedBounds)
        guard let document = documentView else { return rect }
        let size = document.frame.size
        if rect.width > size.width { rect.origin.x = (size.width - rect.width) / 2 }
        if rect.height > size.height { rect.origin.y = (size.height - rect.height) / 2 }
        return rect
    }
}
