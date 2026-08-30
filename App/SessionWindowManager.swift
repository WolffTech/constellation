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

    func update(browserWindow: NSWindow, sessions: [SessionSummary], selectedSessionID: SessionID?) {
        self.browserWindow = browserWindow
        reconcile(sessions: sessions)

        if let selectedSessionID, let window = windows[selectedSessionID] {
            browserWindow.orderOut(nil)
            select(window)
        } else if selectedSessionID == nil, browserWindow.isVisible {
            browserWindow.makeKeyAndOrderFront(nil)
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
            window.updateTabStatus(summary.tabStatus, showsAccessoryCloseButton: sessions.count == 1)
        }

        applyTabOrder(sessions.map(\.id))
        observeTabGroupIfNeeded()

        if sessions.isEmpty {
            stopObservingTabGroup()
            browserWindow.makeKeyAndOrderFront(nil)
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

        if let anchor = orderedWindows.first {
            anchor.addTabbedWindow(window, ordered: .above)
        }
        window.makeKeyAndOrderFront(nil)
        showTabBarIfNeeded(on: window)
        return window
    }

    private func applyTabOrder(_ orderedIDs: [SessionID]) {
        guard let anchor = orderedWindows.first,
              let group = anchor.tabGroup else { return }
        for (index, id) in orderedIDs.enumerated() {
            guard let window = windows[id], group.windows[safe: index] !== window else { continue }
            group.insertWindow(window, at: index)
        }
    }

    private func storeTabOrder(_ ids: [SessionID]) {
        guard !isReconciling, let sessions = root?.sessions else { return }
        sessions.reorderSessions(ids)
    }

    private func select(_ window: NSWindow) {
        if let group = window.tabGroup {
            group.selectedWindow = window
        }
        window.makeKeyAndOrderFront(nil)
    }

    private func showTabBarIfNeeded(on window: NSWindow) {
        DispatchQueue.main.async {
            if window.tabGroup?.isTabBarVisible != true {
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
                guard let self, let id else { return }
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

private final class SessionWindow: NSWindow {
    nonisolated let sessionID: SessionID
    weak var manager: SessionWindowManager?
    private var closesFromCoordinator = false
    private var tabStatus: SessionTabStatus?
    private var showsAccessoryCloseButton = false
    private lazy var tabAccessory = NSHostingView(
        rootView: SessionTabAccessory(status: .disconnected, showsCloseButton: false) { [weak self] in
            guard let self else { return }
            self.manager?.requestClose(self.sessionID)
        })

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

    func updateTabStatus(_ status: SessionTabStatus, showsAccessoryCloseButton: Bool) {
        guard status != tabStatus || showsAccessoryCloseButton != self.showsAccessoryCloseButton else { return }
        tabStatus = status
        self.showsAccessoryCloseButton = showsAccessoryCloseButton
        tabAccessory.rootView = SessionTabAccessory(
            status: status,
            showsCloseButton: showsAccessoryCloseButton
        ) { [weak self] in
            guard let self else { return }
            self.manager?.requestClose(self.sessionID)
        }
        tabAccessory.toolTip = status.accessibilityLabel
        tab.accessoryView = tabAccessory
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

private struct SessionTabAccessory: View {
    let status: SessionTabStatus
    let showsCloseButton: Bool
    let onClose: () -> Void
    @State private var closeHovered = false

    var body: some View {
        HStack(spacing: 4) {
            statusIndicator
            if showsCloseButton {
                Button(action: onClose) {
                    Image(systemName: "xmark")
                        .font(.system(size: 8, weight: .bold))
                        .frame(width: 13, height: 13)
                        .background(closeHovered ? Color.primary.opacity(0.12) : .clear, in: Circle())
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .onHover { closeHovered = $0 }
                .help("Close Session")
                .accessibilityLabel("Close Session")
            }
        }
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
            root.sessionWindows.update(
                browserWindow: window,
                sessions: sessions,
                selectedSessionID: selectedSessionID)
        }
    }
}

private extension Array {
    subscript(safe index: Index) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}
