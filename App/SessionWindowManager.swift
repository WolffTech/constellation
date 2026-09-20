// SPDX-FileCopyrightText: 2026 Nick Wolff <nick@wolff.tech>
// SPDX-License-Identifier: GPL-3.0-only

import AppKit
import ConstellationCore
import SwiftUI

/// Keeps open sessions and AppKit's native window tabs in sync.
@MainActor
final class SessionWindowManager: NSObject, NSWindowDelegate {
    weak var root: CompositionRoot?

    private weak var browserWindow: NSWindow?
    private var windows: [SessionID: SessionWindow] = [:]
    private var isReconciling = false
    private weak var observedTabGroup: NSWindowTabGroup?
    private var tabWindowsObservation: NSKeyValueObservation?
    private var selectedWindowObservation: NSKeyValueObservation?
    private var reconciledSessionIDs: [SessionID] = []

    override init() {
        super.init()
        NotificationCenter.default.addObserver(
            self, selector: #selector(synchronizeNativeTabOrder),
            name: NSApplication.didUpdateNotification, object: nil)
    }

    func update(browserWindow: NSWindow) {
        // A native drag can reorder tabs without notifying observers of `windows`.
        synchronizeNativeTabOrder()
        guard let coordinator = root?.sessions else { return }
        self.browserWindow = browserWindow
        reconcile(sessions: coordinator.sessions)

        let selectedSessionID = coordinator.selectedSessionID
        if let selectedSessionID, let window = windows[selectedSessionID] {
            select(window)
            browserWindow.orderOut(nil)
        } else if selectedSessionID == nil {
            let activeWindow = orderedWindows.first(where: \.isKeyWindow)
                ?? orderedWindows.first(where: { $0.tabGroup?.selectedWindow === $0 })
                ?? orderedWindows.first
            SessionWindowHandoff.showBrowser(browserWindow, alongside: activeWindow)
        }
    }

    func requestClose(_ sessionID: SessionID) {
        root?.sessions?.requestClose(sessionID: sessionID)
        if let sessions = root?.sessions?.sessions {
            reconcile(sessions: sessions)
        }
    }

    func presentQuickConnect() {
        root?.perform(.quickConnect)
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        guard let window = sender as? SessionWindow else { return true }
        requestClose(window.sessionID)
        return false
    }

    private func reconcile(sessions: [SessionSummary]) {
        guard !isReconciling, let root, let browserWindow else { return }
        isReconciling = true
        defer { isReconciling = false }

        let sessionIDs = Set(sessions.map(\.id))
        let closedIDs = windows.keys.filter { !sessionIDs.contains($0) }
        let closingWindows = closedIDs.compactMap { windows[$0] }

        if sessions.isEmpty, let outgoingWindow = closingWindows.first(where: \.isKeyWindow)
            ?? closingWindows.first(where: { $0.tabGroup?.selectedWindow === $0 })
            ?? closingWindows.first {
            stopObservingTabGroup()
            showBrowserWindow(browserWindow, replacing: outgoingWindow)
        }

        for id in closedIDs {
            guard let window = windows.removeValue(forKey: id) else { continue }
            window.closeFromCoordinator()
        }

        for summary in sessions where windows[summary.id] == nil {
            windows[summary.id] = makeWindow(for: summary, root: root, matching: browserWindow)
        }

        for summary in sessions {
            guard let window = windows[summary.id] else { continue }
            window.tab.title = summary.tabTitle
            window.tab.toolTip = tabToolTip(for: summary)
            window.updateTabStatus(summary.tabStatus)
            window.revealsCloseButtonAsOnlyTab = sessions.count == 1
        }

        applyTabOrder(sessions.map(\.id))
        reconciledSessionIDs = sessions.map(\.id)
        observeTabGroupIfNeeded()

        if sessions.isEmpty {
            stopObservingTabGroup()
            if !browserWindow.isVisible {
                browserWindow.makeKeyAndOrderFront(nil)
            }
            hideTabBarIfNeeded(on: browserWindow)
            browserWindow.animationBehavior = .default
        }
    }

    private func makeWindow(for summary: SessionSummary, root: CompositionRoot, matching browserWindow: NSWindow) -> SessionWindow {
        let content = ContentView(root: root, sessionID: summary.id, managesSessionWindows: false)
            .environment(root)
            .environment(root.shortcuts)
        let hostingController = NSHostingController(rootView: content)
        let window = SessionWindow(
            sessionID: summary.id,
            contentRect: browserWindow.contentLayoutRect,
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false)
        window.manager = self
        window.delegate = self
        window.contentViewController = hostingController
        window.setFrame(browserWindow.frame, display: false)
        window.title = summary.tabTitle
        window.titlebarAppearsTransparent = browserWindow.titlebarAppearsTransparent
        window.titleVisibility = browserWindow.titleVisibility
        window.toolbarStyle = browserWindow.toolbarStyle
        window.tabbingIdentifier = "tech.wolff.Constellation.sessions"
        window.tabbingMode = .preferred
        window.isReleasedWhenClosed = false
        window.animationBehavior = .none

        if let anchor = orderedWindows.first {
            anchor.addTabbedWindow(window, ordered: .above)
        } else {
            // Keep the first session in the existing virtual window while the
            // browser tab is removed. This avoids presenting a second window.
            SessionWindowHandoff.prepare(window, replacing: browserWindow)
        }
        showTabBarIfNeeded(on: window)
        return window
    }

    private func applyTabOrder(_ orderedIDs: [SessionID]) {
        guard let anchor = orderedWindows.first,
              let group = anchor.tabGroup else { return }
        SessionWindowTabOrder.apply(orderedIDs.compactMap { windows[$0] }, to: group)
    }

    private func storeTabOrder(_ ids: [SessionID]) {
        guard !isReconciling, let sessions = root?.sessions,
              sessions.sessions.map(\.id) == reconciledSessionIDs else { return }
        sessions.reorderSessions(ids)
        reconciledSessionIDs = sessions.sessions.map(\.id)
    }

    @objc private func synchronizeNativeTabOrder() {
        guard let group = observedTabGroup else { return }
        // Do not overwrite a model-driven reorder that has not reached AppKit yet.
        storeTabOrder(group.windows.compactMap { ($0 as? SessionWindow)?.sessionID })
    }

    private func select(_ window: NSWindow) {
        if let group = window.tabGroup {
            group.selectedWindow = window
        }
        window.makeKeyAndOrderFront(nil)
    }

    private func showBrowserWindow(_ browserWindow: NSWindow, replacing window: SessionWindow) {
        SessionWindowHandoff.prepare(browserWindow, replacing: window)
        select(browserWindow)
    }

    private func showTabBarIfNeeded(on window: NSWindow) {
        DispatchQueue.main.async {
            if window.tabGroup?.isTabBarVisible != true {
                window.toggleTabBar(nil)
            }
        }
    }

    private func hideTabBarIfNeeded(on window: NSWindow) {
        DispatchQueue.main.async {
            if window.tabGroup?.isTabBarVisible == true {
                window.toggleTabBar(nil)
            }
        }
    }

    private func observeTabGroupIfNeeded() {
        let group = orderedWindows.first?.tabGroup
        guard observedTabGroup !== group else { return }
        stopObservingTabGroup()
        guard let group else { return }
        observedTabGroup = group
        tabWindowsObservation = group.observe(\.windows, options: [.new]) { [weak self] group, _ in
            let ids = group.windows.compactMap { ($0 as? SessionWindow)?.sessionID }
            MainActor.assumeIsolated {
                self?.storeTabOrder(ids)
                self?.observeTabGroupIfNeeded()
            }
        }
        selectedWindowObservation = group.observe(\.selectedWindow, options: [.new]) { [weak self] group, _ in
            let id = (group.selectedWindow as? SessionWindow)?.sessionID
            MainActor.assumeIsolated {
                guard let self, !self.isReconciling, let id else { return }
                self.root?.sessions?.select(id)
            }
        }
    }

    private func stopObservingTabGroup() {
        tabWindowsObservation = nil
        selectedWindowObservation = nil
        observedTabGroup = nil
    }

    private var orderedWindows: [SessionWindow] {
        guard let sessions = root?.sessions?.sessions else { return [] }
        return sessions.compactMap { windows[$0.id] }
    }

    private func tabToolTip(for summary: SessionSummary) -> String {
        var parts = [summary.tabTitle, summary.profileName, summary.tabStatus.accessibilityLabel]
        if case .connected(let facts) = summary.state {
            parts.append("\(facts.host):\(facts.port)")
        }
        return parts.joined(separator: " · ")
    }
}

@MainActor
enum SessionWindowTabOrder {
    static func apply(_ windows: [NSWindow], to group: NSWindowTabGroup) {
        let selectedWindow = group.selectedWindow
        for (index, window) in windows.enumerated() {
            guard group.windows[safe: index] !== window else { continue }
            // Reinserting an existing member without removing it first can leave
            // stale tab-bar items that crash a later browser window handoff.
            if group.windows.contains(where: { $0 === window }) {
                group.removeWindow(window)
            }
            group.insertWindow(window, at: index)
        }
        if let selectedWindow, group.windows.contains(where: { $0 === selectedWindow }) {
            group.selectedWindow = selectedWindow
        }
    }
}

@MainActor
enum SessionWindowHandoff {
    static func showBrowser(_ browserWindow: NSWindow, alongside sessionWindow: NSWindow?) {
        // Machine details share the session's native tab group without closing its connections.
        if let sessionWindow, browserWindow.tabGroup !== sessionWindow.tabGroup || browserWindow.tabGroup == nil {
            prepare(browserWindow, replacing: sessionWindow)
        }
        browserWindow.tabGroup?.selectedWindow = browserWindow
        browserWindow.makeKeyAndOrderFront(nil)
    }

    static func prepare(_ incomingWindow: NSWindow, replacing outgoingWindow: NSWindow) {
        incomingWindow.animationBehavior = .none
        outgoingWindow.animationBehavior = .none
        incomingWindow.setFrame(outgoingWindow.frame, display: false)
        // AppKit asserts when a window is added to a tab group it already belongs to.
        if incomingWindow.tabGroup == nil || incomingWindow.tabGroup !== outgoingWindow.tabGroup {
            outgoingWindow.addTabbedWindow(incomingWindow, ordered: .above)
        }
        incomingWindow.tabGroup?.selectedWindow = incomingWindow
    }
}

private final class SessionWindow: NSWindow {
    nonisolated let sessionID: SessionID
    weak var manager: SessionWindowManager?
    private var closesFromCoordinator = false
    private var tabStatus: SessionTabStatus?
    private lazy var tabAccessory = NSHostingView(rootView: SessionTabAccessory(status: .disconnected))
    private lazy var onlyTabCloseButton = OnlyTabCloseButton(window: self) { [weak self] in
        guard let self else { return }
        self.manager?.requestClose(self.sessionID)
    }

    /// Set on every reconcile, which also re-attaches after AppKit rebuilds the tab buttons.
    var revealsCloseButtonAsOnlyTab = false {
        didSet { refreshOnlyTabCloseButton() }
    }

    init(
        sessionID: SessionID,
        contentRect: NSRect,
        styleMask: NSWindow.StyleMask,
        backing: NSWindow.BackingStoreType,
        defer flag: Bool
    ) {
        self.sessionID = sessionID
        super.init(contentRect: contentRect, styleMask: styleMask, backing: backing, defer: flag)
    }

    override func performClose(_ sender: Any?) {
        if closesFromCoordinator {
            super.performClose(sender)
        } else {
            manager?.requestClose(sessionID)
        }
    }

    override func newWindowForTab(_ sender: Any?) {
        manager?.presentQuickConnect()
    }

    // AppKit installs the tab bar through this call, so its buttons exist afterwards.
    override func addTitlebarAccessoryViewController(_ childViewController: NSTitlebarAccessoryViewController) {
        super.addTitlebarAccessoryViewController(childViewController)
        refreshOnlyTabCloseButton()
    }

    func updateTabStatus(_ status: SessionTabStatus) {
        guard status != tabStatus else { return }
        tabStatus = status
        tabAccessory.rootView = SessionTabAccessory(status: status)
        tabAccessory.toolTip = status.accessibilityLabel
        tab.accessoryView = tabAccessory
    }

    private func refreshOnlyTabCloseButton() {
        // AppKit rebuilds tab buttons after the current layout pass.
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            if self.revealsCloseButtonAsOnlyTab {
                self.onlyTabCloseButton.attach()
            } else {
                self.onlyTabCloseButton.detach()
            }
        }
    }

    func closeFromCoordinator() {
        closesFromCoordinator = true
        close()
    }
}

enum SessionTabStatus: Equatable {
    case connecting
    case disconnecting
    case connected
    case running
    case attention
    case failed
    case disconnected

    var accessibilityLabel: String {
        switch self {
        case .connecting: "Connecting"
        case .disconnecting: "Disconnecting"
        case .connected: "Connected"
        case .running: "Running"
        case .attention: "Action needed"
        case .failed: "Failed"
        case .disconnected: "Disconnected"
        }
    }
}

extension SessionSummary {
    var tabStatus: SessionTabStatus {
        if case .failed = state { return .failed }
        if needsAttention { return .attention }
        return switch state {
        case .connecting: .connecting
        case .awaitingUserInput: .attention
        case .connected: .connected
        case .running: .running
        case .disconnecting: .disconnecting
        case .failed: .failed
        case .disconnected: .disconnected
        }
    }
}

/// AppKit keeps a tab's close button hidden while it is the only tab. This reveals
/// that native button on hover so closing looks the same with any number of tabs.
@MainActor
private final class OnlyTabCloseButton: NSResponder {
    private weak var window: NSWindow?
    private let onClose: () -> Void
    private weak var tabButton: NSView?
    private weak var closeButton: NSButton?
    private var trackingArea: NSTrackingArea?
    private weak var nativeTarget: AnyObject?
    private var nativeAction: Selector?

    init(window: NSWindow, onClose: @escaping () -> Void) {
        self.window = window
        self.onClose = onClose
        super.init()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    /// The browser window can share the tab group, so the group decides, not the session count.
    private var isOnlyTab: Bool {
        guard let group = window?.tabGroup else { return true }
        return group.windows.count == 1
    }

    func attach() {
        guard let window, isOnlyTab else { return detach() }
        guard closeButton?.window !== window else { return }
        detach()
        // These are private AppKit views; without them the tab simply has no close button.
        guard let closeButton = window.contentView?.superview?
                .firstDescendant(withIdentifier: "_closeButton") as? NSButton,
              let tabButton = closeButton.firstAncestor(withClassName: "NSTabButton") else { return }

        let trackingArea = NSTrackingArea(
            rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self)
        tabButton.addTrackingArea(trackingArea)
        nativeTarget = closeButton.target
        nativeAction = closeButton.action
        closeButton.target = self
        closeButton.action = #selector(close(_:))
        self.trackingArea = trackingArea
        self.tabButton = tabButton
        self.closeButton = closeButton

        let mouse = tabButton.convert(window.mouseLocationOutsideOfEventStream, from: nil)
        setRevealed(tabButton.bounds.contains(mouse))
    }

    func detach() {
        if let trackingArea { tabButton?.removeTrackingArea(trackingArea) }
        if let closeButton, closeButton.target === self {
            closeButton.target = nativeTarget
            closeButton.action = nativeAction
        }
        trackingArea = nil
        tabButton = nil
        closeButton = nil
    }

    override func mouseEntered(with event: NSEvent) { setRevealed(true) }

    override func mouseExited(with event: NSEvent) { setRevealed(false) }

    @objc private func close(_ sender: Any?) {
        // A button that outlived the single-tab state belongs to AppKit again.
        guard isOnlyTab else {
            if let nativeAction { NSApp.sendAction(nativeAction, to: nativeTarget, from: sender) }
            return
        }
        onClose()
    }

    private func setRevealed(_ revealed: Bool) {
        // Deferred so AppKit's own hover update for the tab cannot land after this one.
        DispatchQueue.main.async { [weak self] in
            guard let self, self.isOnlyTab else { return }
            self.closeButton?.animator().alphaValue = revealed ? 1 : 0
        }
    }
}

private extension NSView {
    func firstDescendant(withIdentifier identifier: String) -> NSView? {
        for subview in subviews {
            if subview.identifier?.rawValue == identifier { return subview }
            if let match = subview.firstDescendant(withIdentifier: identifier) { return match }
        }
        return nil
    }

    func firstAncestor(withClassName className: String) -> NSView? {
        var view = superview
        while let candidate = view, candidate.className != className { view = candidate.superview }
        return view
    }
}

private struct SessionTabAccessory: View {
    let status: SessionTabStatus

    var body: some View {
        statusIndicator
            .fixedSize()
    }

    @ViewBuilder
    private var statusIndicator: some View {
        Group {
            switch status {
            case .connecting, .disconnecting:
                ProgressView()
                    .controlSize(.mini)
            case .connected, .running:
                Circle()
                    .fill(.green)
                    .frame(width: 7, height: 7)
            case .attention:
                Image(systemName: "exclamationmark.circle.fill")
                    .foregroundStyle(.orange)
                    .font(.system(size: 11))
            case .failed:
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.red)
                    .font(.system(size: 11))
            case .disconnected:
                Circle()
                    .fill(.secondary)
                    .frame(width: 7, height: 7)
            }
        }
        .frame(width: 13, height: 13)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(status.accessibilityLabel)
    }
}

struct SessionWindowBridge: NSViewRepresentable {
    let root: CompositionRoot
    let sessions: [SessionSummary]
    let selectedSessionID: SessionID?

    func makeNSView(context: Context) -> NSView {
        NSView()
    }

    func updateNSView(_ view: NSView, context: Context) {
        DispatchQueue.main.async {
            guard let window = view.window else { return }
            // Read the coordinator when this runs, rather than replaying a snapshot
            // captured before a native selection or reorder.
            root.sessionWindows.update(browserWindow: window)
        }
    }
}

private extension Array {
    subscript(safe index: Index) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}
