// SPDX-FileCopyrightText: 2026 Nick Wolff <nick@wolff.tech>
// SPDX-License-Identifier: GPL-3.0-only

import AppKit
import ConstellationRemoteDesktop

/// Hosts the RDP surface in a scroll view and applies the display mode. "Fit"
/// scales the surface to the clip view and reports the clip size so a session
/// with dynamic resolution can ask the server to match it; "actual size" keeps
/// one remote pixel per device pixel and scrolls. The frame buffer is in
/// pixels; frames here are in points.
@MainActor
final class RDPHostView: NSView {
    var displayMode: RemoteDesktopDisplayMode = .fit {
        didSet { applyDisplayMode() }
    }

    /// Called with the clip size whenever it changes while in `.fit` mode.
    var onFitSizeChanged: ((CGSize) -> Void)?

    private let scrollView = NSScrollView(frame: .zero)
    private var framebufferSize: CGSize = .zero
    private var lastReportedFitSize: CGSize = .zero

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.backgroundColor = NSColor.black.cgColor
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.drawsBackground = false
        scrollView.autohidesScrollers = true
        addSubview(scrollView)
        NSLayoutConstraint.activate([
            scrollView.leadingAnchor.constraint(equalTo: leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: trailingAnchor),
            scrollView.topAnchor.constraint(equalTo: topAnchor),
            scrollView.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func accessibilityRole() -> NSAccessibility.Role? { .group }
    override func accessibilityLabel() -> String? {
        displayMode == .fit ? "Remote desktop, fit to window" : "Remote desktop, actual size"
    }

    /// The size a fitted desktop would have: the clip view's bounds.
    var fitSize: CGSize { scrollView.contentView.bounds.size }

    func show(_ view: NSView, framebufferSize: CGSize) {
        self.framebufferSize = framebufferSize
        if scrollView.documentView !== view {
            scrollView.documentView = view
        }
        applyDisplayMode()
    }

    func clear() {
        scrollView.documentView = nil
        framebufferSize = .zero
    }

    override func layout() {
        super.layout()
        if displayMode == .fit {
            applyDisplayMode()
            reportFitSizeIfChanged()
        }
    }

    /// Moving to a display with a different pixel density changes the pixel
    /// size the desktop should have, even if the point size did not.
    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        applyDisplayMode()
        if displayMode == .fit { reportFitSizeIfChanged() }
    }

    private func reportFitSizeIfChanged() {
        let size = fitSize
        guard size.width > 0, size.height > 0 else { return }
        // Report every layout (not just on change): the size may be unchanged
        // since before the session connected, but the desktop still needs to be
        // told once connected. The session debounces and ignores no-ops.
        lastReportedFitSize = size
        onFitSizeChanged?(size)
    }

    private func applyDisplayMode() {
        guard let document = scrollView.documentView, framebufferSize != .zero else { return }
        switch displayMode {
        case .fit:
            scrollView.hasVerticalScroller = false
            scrollView.hasHorizontalScroller = false
            let clip = fitSize
            // Fill the view while preserving aspect. Dynamic resolution makes the
            // desktop match the view; until it does, scaling avoids a tiny image.
            let scale = min(clip.width / framebufferSize.width, clip.height / framebufferSize.height)
            let size = CGSize(width: framebufferSize.width * scale, height: framebufferSize.height * scale)
            let origin = CGPoint(x: (clip.width - size.width) / 2, y: (clip.height - size.height) / 2)
            document.frame = NSRect(origin: origin, size: size)
        case .actualSize:
            scrollView.hasVerticalScroller = true
            scrollView.hasHorizontalScroller = true
            let scale = window?.backingScaleFactor ?? 1
            document.frame = NSRect(origin: .zero, size: CGSize(width: framebufferSize.width / scale, height: framebufferSize.height / scale))
        }
    }
}
