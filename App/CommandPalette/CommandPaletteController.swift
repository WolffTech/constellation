// SPDX-FileCopyrightText: 2026 Nick Wolff <nick@wolff.tech>
// SPDX-License-Identifier: GPL-3.0-only

import AppKit
import Observation
import SwiftUI

/// Sizes shared by the panel and its SwiftUI content, so the panel's height
/// can be computed from the rows rather than measured after layout.
enum PaletteMetrics {
    static let width: CGFloat = 620
    static let cornerRadius: CGFloat = 20
    /// Concentric with the panel corner across the list's horizontal padding.
    static let rowCornerRadius: CGFloat = cornerRadius - 8
    static let fieldHeight: CGFloat = 56
    static let rowHeight: CGFloat = 44
    static let headerHeight: CGFloat = 24
    static let listPadding: CGFloat = 6
    static let maxListHeight: CGFloat = 8 * rowHeight + 2 * headerHeight + 2 * listPadding

    static func listHeight(for items: [PaletteItem]) -> CGFloat {
        guard !items.isEmpty else { return 0 }
        let headers = items.indices.count { $0 == 0 || items[$0 - 1].section != items[$0].section }
        let total = CGFloat(items.count) * rowHeight + CGFloat(headers) * headerHeight + 2 * listPadding
        return min(total, maxListHeight)
    }
}

/// Owns the palette panel and its keyboard state. Rows come from the root
/// each time the query or the library changes.
@MainActor
@Observable
final class CommandPaletteController {
    var query = ""
    var selectedIndex = 0
    private(set) var isPresented = false
    /// Hover only moves the highlight after the mouse moves; the panel may
    /// open under the pointer and would otherwise steal the first row.
    private(set) var followsHover = false

    @ObservationIgnored weak var root: CompositionRoot?
    @ObservationIgnored private var panel: CommandPalettePanel?
    @ObservationIgnored private var resignObserver: (any NSObjectProtocol)?

    var items: [PaletteItem] {
        root?.paletteItems(for: query) ?? []
    }

    /// Never past the end, so the highlight survives the list shrinking.
    var clampedSelection: Int {
        min(selectedIndex, max(items.count - 1, 0))
    }

    func toggle() {
        if isPresented { dismiss() } else { present() }
    }

    func present() {
        guard !isPresented, let root else { return }
        let panel = panel ?? makePanel(shortcuts: root.shortcuts)
        query = ""
        selectedIndex = 0
        followsHover = false
        isPresented = true
        layout(panel)
        panel.makeKeyAndOrderFront(nil)
    }

    func dismiss() {
        guard isPresented else { return }
        isPresented = false
        panel?.orderOut(nil)
    }

    func moveSelection(by delta: Int) {
        let count = items.count
        guard count > 0 else { return }
        selectedIndex = (clampedSelection + delta + count) % count
    }

    /// Runs the highlighted row. The panel closes first so a command that
    /// looks at the key window sees the app's window, not the palette.
    func confirm() {
        let items = items
        guard items.indices.contains(clampedSelection) else { return }
        let item = items[clampedSelection]
        dismiss()
        root?.perform(item)
    }

    /// Re-fits the panel after the rows changed; the top edge stays put.
    func layout() {
        if let panel { layout(panel) }
    }

    private func layout(_ panel: NSPanel) {
        let height = PaletteMetrics.fieldHeight + PaletteMetrics.listHeight(for: items)
        let anchor = NSApp.mainWindow?.frame ?? NSScreen.main?.visibleFrame ?? .zero
        let top = anchor.maxY - anchor.height * 0.18
        let x = anchor.midX - PaletteMetrics.width / 2
        panel.setFrame(NSRect(x: x, y: top - height, width: PaletteMetrics.width, height: height), display: true)
        // The shadow is cut from the content's alpha; recompute it once the
        // glass has drawn or a rectangular ghost shows at the rounded corners.
        DispatchQueue.main.async { panel.invalidateShadow() }
    }

    private func makePanel(shortcuts: ShortcutSettingsStore) -> CommandPalettePanel {
        let panel = CommandPalettePanel(
            contentRect: NSRect(x: 0, y: 0, width: PaletteMetrics.width, height: PaletteMetrics.fieldHeight),
            styleMask: [.borderless], backing: .buffered, defer: false)
        panel.isFloatingPanel = true
        panel.level = .floating
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.hidesOnDeactivate = true
        panel.animationBehavior = .none
        panel.collectionBehavior = [.moveToActiveSpace, .fullScreenAuxiliary]
        panel.onKey = { [weak self] key in
            guard let self else { return false }
            switch key {
            case .up: moveSelection(by: -1)
            case .down: moveSelection(by: 1)
            case .escape: dismiss()
            }
            return true
        }
        panel.onMouseMoved = { [weak self] in self?.followsHover = true }
        let hosting = NSHostingView(rootView: CommandPaletteView(controller: self))
        panel.contentView = hosting
        resignObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.didResignKeyNotification, object: panel, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.dismiss() }
        }
        self.panel = panel
        return panel
    }
}

/// A borderless panel that can take keyboard focus and routes navigation
/// keys to the controller before the text field sees them.
@MainActor
final class CommandPalettePanel: NSPanel {
    enum Key { case up, down, escape }

    var onKey: ((Key) -> Bool)?
    var onMouseMoved: (() -> Void)?

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    override var acceptsMouseMovedEvents: Bool {
        get { true }
        set {}
    }

    override func sendEvent(_ event: NSEvent) {
        switch event.type {
        case .keyDown:
            if let key = Self.key(for: event), onKey?(key) == true { return }
        case .mouseMoved:
            onMouseMoved?()
        default:
            break
        }
        super.sendEvent(event)
    }

    override func cancelOperation(_ sender: Any?) {
        _ = onKey?(.escape)
    }

    /// Arrows, Escape, and the Emacs-style ⌃N/⌃P many terminal users expect.
    private static func key(for event: NSEvent) -> Key? {
        let control = event.modifierFlags.intersection(.deviceIndependentFlagsMask) == .control
        switch Int(event.keyCode) {
        case 0x7E: return .up
        case 0x7D: return .down
        case 0x35: return .escape
        case 0x23 where control: return .up
        case 0x2D where control: return .down
        default: return nil
        }
    }
}
