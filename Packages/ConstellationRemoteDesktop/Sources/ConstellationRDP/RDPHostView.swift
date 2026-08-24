import AppKit

/// Hosts the RDP surface in a scroll view and applies the display mode. Mirrors
/// the VNC host: "fit" scales the surface down to the clip view, "actual size"
/// keeps one remote pixel per point and scrolls.
@MainActor
final class RDPHostView: NSView {
    var displayMode: RDPDisplayMode = .fit {
        didSet { applyDisplayMode() }
    }

    private let scrollView = NSScrollView(frame: .zero)
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
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

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
        if displayMode == .fit { applyDisplayMode() }
    }

    private func applyDisplayMode() {
        guard let document = scrollView.documentView, framebufferSize != .zero else { return }
        switch displayMode {
        case .fit:
            scrollView.hasVerticalScroller = false
            scrollView.hasHorizontalScroller = false
            let clip = scrollView.contentView.bounds.size
            // Scale down to fit while preserving aspect; never up.
            let scale = min(1, min(clip.width / framebufferSize.width, clip.height / framebufferSize.height))
            let size = CGSize(width: framebufferSize.width * scale, height: framebufferSize.height * scale)
            let origin = CGPoint(x: (clip.width - size.width) / 2, y: (clip.height - size.height) / 2)
            document.frame = NSRect(origin: origin, size: size)
        case .actualSize:
            scrollView.hasVerticalScroller = true
            scrollView.hasHorizontalScroller = true
            document.frame = NSRect(origin: .zero, size: framebufferSize)
        }
    }
}
