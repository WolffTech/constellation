import AppKit
import ConstellationRemoteDesktop
import RoyalVNCKit

/// Hosts the framebuffer view in a scroll view and applies the display mode.
/// `VNCCAFramebufferView` scales itself down to its bounds and centres, so
/// "fit" is just "frame follows the clip view".
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
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func show(_ view: NSView, framebufferSize: CGSize) {
        self.framebufferSize = framebufferSize
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

    private func applyDisplayMode() {
        guard let document = scrollView.documentView else { return }
        switch displayMode {
        case .fit:
            scrollView.hasVerticalScroller = false
            scrollView.hasHorizontalScroller = false
            document.frame = NSRect(origin: .zero, size: scrollView.contentView.bounds.size)
        case .actualSize:
            scrollView.hasVerticalScroller = true
            scrollView.hasHorizontalScroller = true
            let clip = scrollView.contentView.bounds.size
            // Never smaller than the clip view, so a small desktop still centres.
            document.frame = NSRect(
                origin: .zero,
                size: CGSize(width: max(framebufferSize.width, clip.width), height: max(framebufferSize.height, clip.height)))
        }
    }
}
