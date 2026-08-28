// SPDX-FileCopyrightText: 2026 Nick Wolff <nick@wolff.tech>
// SPDX-License-Identifier: GPL-3.0-only

import AppKit
import ConstellationCore
import ConstellationTerminal
import ConstellationRemoteDesktop
import SwiftUI

struct WorkspaceDetailView: View {
    let store: MachineStore
    let sessions: SessionCoordinator
    let ui: UIState
    @Environment(ShortcutSettingsStore.self) private var shortcuts

    var body: some View {
        VStack(spacing: 0) {
            if !sessions.sessions.isEmpty {
                SessionTabBar(sessions: sessions, ui: ui)
                Divider()
            }
            if let session = sessions.selectedSession {
                SessionContentView(summary: session, sessions: sessions, ui: ui)
            } else if let id = ui.selectedMachineID, let machine = store.snapshot.machine(id) {
                MachineOverviewView(machine: machine, store: store, sessions: sessions, ui: ui)
            } else {
                ContentUnavailableView(
                    "No Machine Selected",
                    systemImage: "server.rack",
                    description: Text(shortcuts.hint(for: .newMachine).map { "Choose a machine in the sidebar, or press \($0) to add one." }
                        ?? "Choose a machine in the sidebar, or add one from the File menu."))
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }
}

private struct SessionTabBar: View {
    let sessions: SessionCoordinator
    let ui: UIState
    @Environment(ShortcutSettingsStore.self) private var shortcuts

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView(.horizontal) {
                HStack(spacing: 4) {
                    ForEach(sessions.sessions) { session in
                        SessionTab(session: session, sessions: sessions, ui: ui)
                            .id(session.id)
                    }
                    Button { ui.showsQuickConnect = true } label: { Image(systemName: "plus") }
                        .buttonStyle(.borderless)
                        .padding(.horizontal, 8)
                        .help("Quick Connect" + shortcuts.hintSuffix(for: .quickConnect))
                        .accessibilityLabel("Quick Connect")
                }
                .padding(.horizontal, 7)
                .padding(.vertical, 4)
            }
            .frame(height: 38)
            .scrollIndicators(.hidden)
            .background(.bar)
            .accessibilityElement(children: .contain)
            .accessibilityLabel("Sessions")
            .onChange(of: sessions.selectedSessionID, initial: true) { _, id in
                if let id { proxy.scrollTo(id) }
            }
        }
    }
}

private struct SessionTab: View {
    let session: SessionSummary
    let sessions: SessionCoordinator
    let ui: UIState
    @State private var hovering = false

    private var isSelected: Bool { session.id == sessions.selectedSessionID }

    var body: some View {
        HStack(spacing: 5) {
            Circle()
                .fill(color(for: session.state))
                .frame(width: 7, height: 7)
            Text(session.title)
                .lineLimit(1)
                .truncationMode(.tail)
            Button {
                sessions.requestClose(sessionID: session.id)
            } label: {
                Image(systemName: "xmark").font(.caption2)
            }
            .buttonStyle(.borderless)
            .help("Close Session")
            .accessibilityLabel("Close \(session.title)")
            .opacity(hovering || isSelected ? 1 : 0)
            .accessibilityHidden(!(hovering || isSelected))
        }
        .padding(.horizontal, 9)
        .padding(.vertical, 5)
        .frame(maxWidth: 220)
        .background(
            isSelected ? Color.accentColor.opacity(0.16) : hovering ? Color.primary.opacity(0.05) : Color.clear,
            in: RoundedRectangle(cornerRadius: 6))
        .overlay {
            if isSelected {
                RoundedRectangle(cornerRadius: 6)
                    .stroke(Color.accentColor.opacity(0.22), lineWidth: 1)
            }
        }
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .onTapGesture { sessions.select(session.id) }
        .help(helpText)
        .contextMenu { SessionActions(summary: session, sessions: sessions, ui: ui, includesClose: true) }
        .draggable(session.id.description)
        .dropDestination(for: String.self) { items, _ in
            guard let value = items.first, let source = SessionID(uuidString: value) else { return false }
            sessions.move(sessionID: source, before: session.id)
            return true
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(session.title), \(session.state.displayName)")
        .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
        .accessibilityAction { sessions.select(session.id) }
    }

    private var helpText: String {
        var parts = [session.machineName ?? session.title, session.profileName, session.state.displayName]
        if case .connected(let facts) = session.state { parts.append("\(facts.host):\(facts.port)") }
        return parts.joined(separator: " · ")
    }

    private func color(for state: SessionState) -> Color {
        switch state {
        case .connected: .green
        case .connecting, .awaitingUserInput, .disconnecting: .orange
        case .failed: .red
        case .disconnected: .secondary
        }
    }
}

/// The actions a session offers, shared by the toolbar and the tab context menu.
private struct SessionActions: View {
    let summary: SessionSummary
    let sessions: SessionCoordinator
    let ui: UIState
    var includesClose = false
    @Environment(ShortcutSettingsStore.self) private var shortcuts

    var body: some View {
        if let machineID = summary.machineID {
            Button {
                ui.selectedMachineID = machineID
                ui.selectedProfileID = summary.profileID
                sessions.select(nil)
            } label: {
                Label("Show Machine", systemImage: "info.circle")
            }
            .help("Show Machine")
        }
        if case .quick = summary.target {
            Button { ui.saveQuickConnectSessionID = summary.id } label: {
                Label("Save as Machine…", systemImage: "square.and.arrow.down")
            }
            .help("Save as Machine")
        }
        if summary.state.hasLiveProcess {
            Button { sessions.disconnect(sessionID: summary.id) } label: {
                Label("Disconnect", systemImage: "stop.circle")
            }
            .help("Disconnect")
        } else {
            Button(action: reconnect) { Label("Reconnect", systemImage: "arrow.clockwise") }
                .help("Reconnect" + shortcuts.hintSuffix(for: .reconnect))
        }
        if sessions.remoteDesktop(for: summary.id) != nil {
            Picker("Display", selection: Binding(
                get: { summary.displayMode ?? .fit },
                set: { sessions.setDisplayMode($0, for: summary.id) })) {
                Label("Fit to Window", systemImage: "arrow.down.right.and.arrow.up.left").tag(RemoteDesktopDisplayMode.fit)
                Label("Actual Size", systemImage: "1.magnifyingglass").tag(RemoteDesktopDisplayMode.actualSize)
            }
            .pickerStyle(.menu)
            .help("Display")
        }
        if let url = screenSharingURL {
            Button { NSWorkspace.shared.open(url) } label: {
                Label("Open in Screen Sharing", systemImage: "macwindow.on.rectangle")
            }
            .help("Open in Apple’s Screen Sharing app")
        }
        if includesClose {
            Divider()
            Button("Close") { sessions.requestClose(sessionID: summary.id) }
            Button("Close Others") { sessions.requestCloseOthers(keeping: summary.id) }
                .disabled(sessions.sessions.count < 2)
        }
    }

    /// VNC sessions only, once an address has been resolved.
    private var screenSharingURL: URL? {
        guard summary.protocolKind == .vnc, let endpoint = summary.endpoint else { return nil }
        return endpoint.screenSharingURL(username: summary.username)
    }

    private func reconnect() {
        Task {
            do { try await sessions.reconnect(sessionID: summary.id) }
            catch { sessions.present(error, title: "Couldn’t Reconnect") }
        }
    }
}

private struct SessionContentView: View {
    let summary: SessionSummary
    let sessions: SessionCoordinator
    let ui: UIState

    var body: some View {
        Group {
            if let terminal = sessions.terminal(for: summary.id) {
                TerminalPane(
                    session: terminal,
                    state: summary.state,
                    isSearchPresented: Binding(
                        get: { sessions.searchSessionID == summary.id },
                        set: { presented in
                            if presented { sessions.searchSessionID = summary.id }
                            else { sessions.dismissSearch(sessionID: summary.id) }
                        }),
                    onReconnect: reconnect)
                    .id(summary.id)
            } else if let desktop = sessions.remoteDesktop(for: summary.id) {
                RemoteDesktopPane(session: desktop, state: summary.state, onReconnect: reconnect)
                    .id(summary.id)
            } else {
                ContentUnavailableView {
                    Label(summary.state.displayName, systemImage: statusIcon)
                } description: {
                    if case .failed(let failure) = summary.state {
                        Text(failure.localizedDescription)
                    } else {
                        Text("Reconnect when you are ready. Restored tabs never connect on their own.")
                    }
                } actions: {
                    Button("Reconnect", action: reconnect)
                        .keyboardShortcut(.defaultAction)
                }
            }
        }
        .navigationTitle(summary.title)
        .navigationSubtitle(subtitle)
        .toolbar {
            ToolbarItemGroup {
                SessionActions(summary: summary, sessions: sessions, ui: ui)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }

    private var subtitle: String {
        if case .connected(let facts) = summary.state {
            return "\(summary.profileName) · \(facts.host):\(facts.port)"
        }
        return "\(summary.profileName) · \(summary.state.displayName)"
    }

    private var statusIcon: String {
        if case .failed = summary.state { "exclamationmark.triangle" } else { summary.protocolKind.symbolName }
    }

    private func reconnect() {
        Task {
            do { try await sessions.reconnect(sessionID: summary.id) }
            catch { sessions.present(error, title: "Couldn’t Reconnect") }
        }
    }
}

struct MachineOverviewView: View {
    let machine: Machine
    let store: MachineStore
    let sessions: SessionCoordinator
    let ui: UIState
    var prober: any AddressProbing = TCPAddressProber()

    private enum ProbeResult { case checking, reachable, unreachable }
    @State private var probes: [AddressID: ProbeResult] = [:]

    var body: some View {
        VStack(spacing: 0) {
            header
                .padding(.horizontal, 28)
                .padding(.top, 22)
                .padding(.bottom, 6)
            Form {
                let openSessions = sessions.sessions.filter { $0.machineID == machine.id }
                if !openSessions.isEmpty {
                    Section("Sessions") {
                        ForEach(openSessions) { session in
                            LabeledContent {
                                Button("Show") { sessions.select(session.id) }
                            } label: {
                                HStack(spacing: 8) {
                                    Circle()
                                        .fill(sessionColor(for: session.state))
                                        .frame(width: 8, height: 8)
                                    Text(session.title)
                                }
                                .accessibilityElement(children: .combine)
                                Text("\(session.profileName) · \(session.state.displayName)")
                            }
                        }
                    }
                }

                Section("Addresses") {
                    let addresses = store.snapshot.addresses(for: machine.id)
                    if addresses.isEmpty {
                        Text("No addresses yet. Edit the machine to add one.")
                            .foregroundStyle(.secondary)
                    }
                    ForEach(addresses) { address in
                        LabeledContent {
                            reachability(for: address)
                        } label: {
                            Text(address.host)
                            Text(addressDetail(for: address))
                        }
                    }
                }

                Section("Profiles") {
                    let profiles = store.snapshot.orderedProfiles(for: machine)
                    if profiles.isEmpty {
                        Text("No profiles yet. Edit the machine to add one.")
                            .foregroundStyle(.secondary)
                    }
                    ForEach(profiles) { profile in
                        LabeledContent {
                            HStack {
                                if case .vnc(let vnc) = profile, let url = screenSharingURL(for: vnc) {
                                    Button { NSWorkspace.shared.open(url) } label: {
                                        Image(systemName: "macwindow.on.rectangle")
                                    }
                                    .help("Open in Apple’s Screen Sharing app")
                                    .accessibilityLabel("Open in Screen Sharing")
                                }
                                Button("Connect") { connect(profile.id) }
                            }
                        } label: {
                            HStack(spacing: 7) {
                                Image(systemName: profile.protocolKind.symbolName)
                                    .foregroundStyle(.secondary)
                                    .accessibilityHidden(true)
                                Text(profile.name)
                                if machine.defaultProfileID == profile.id {
                                    Chip("Default")
                                }
                            }
                            Text(profileDetail(for: profile))
                        }
                        .listRowBackground(
                            ui.selectedProfileID == profile.id ? Color.accentColor.opacity(0.12) : nil)
                    }
                }
            }
            .formStyle(.grouped)
            .scrollContentBackground(.hidden)
        }
        .frame(maxWidth: 760, alignment: .leading)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .navigationTitle(machine.name)
        .navigationSubtitle("")
        .onChange(of: machine.id) { probes = [:] }
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 8) {
                    Text(machine.name).font(.title.bold())
                    Button {
                        var updated = machine
                        updated.isFavorite.toggle()
                        Task { await store.save(.upsertMachine(updated)) }
                    } label: {
                        Image(systemName: machine.isFavorite ? "star.fill" : "star")
                            .foregroundStyle(machine.isFavorite ? .yellow : .secondary)
                    }
                    .buttonStyle(.plain)
                    .help(machine.isFavorite ? "Remove from Favorites" : "Add to Favorites")
                    .accessibilityLabel(machine.isFavorite ? "Remove from Favorites" : "Add to Favorites")
                }
                if !machine.notes.isEmpty {
                    Text(machine.notes)
                        .foregroundStyle(.secondary)
                }
                if !machine.tags.isEmpty {
                    HStack(spacing: 6) {
                        ForEach(machine.tags.sorted(), id: \.self) { Chip($0) }
                    }
                }
            }
            Spacer()
            Button { ui.editor = .edit(machine.id) } label: {
                Label("Edit", systemImage: "pencil")
            }
            .keyboardShortcut("e")
        }
    }

    /// Label and network kind, without repeating one in the other.
    private func addressDetail(for address: MachineAddress) -> String {
        let label = address.label.trimmingCharacters(in: .whitespaces)
        let kind = address.kind.displayName
        if label.isEmpty || label.caseInsensitiveCompare(kind) == .orderedSame { return kind }
        return "\(label) · \(kind)"
    }

    private func profileDetail(for profile: ConnectionProfile) -> String {
        var parts: [String] = []
        if let username = profile.username, !username.isEmpty { parts.append(username) }
        if let port = profile.port, port != profile.protocolKind.defaultPort { parts.append("port \(port)") }
        if case .ssh(let ssh) = profile { parts.append(ssh.authentication.displayName) }
        if case .vnc(let vnc) = profile {
            parts.append("unencrypted")
            if vnc.sharesClipboard { parts.append("clipboard shared") }
        }
        if case .rdp(let rdp) = profile {
            if let domain = rdp.domain, !domain.isEmpty { parts.append("domain \(domain)") }
            if rdp.sharesClipboard { parts.append("clipboard shared") }
        }
        switch profile.addressSelection {
        case .automatic:
            parts.append("first reachable address")
        case .pinned(let id):
            if let address = store.snapshot.addresses(for: machine.id).first(where: { $0.id == id }) {
                parts.append("via \(address.displayLabel)")
            }
        }
        return parts.joined(separator: " · ")
    }

    /// The pinned address, else the first one: enough for a `vnc://` handoff.
    private func screenSharingURL(for vnc: VNCProfile) -> URL? {
        let addresses = store.snapshot.addresses(for: machine.id)
        let address: MachineAddress? = switch vnc.addressSelection {
        case .automatic: addresses.first
        case .pinned(let id): addresses.first { $0.id == id }
        }
        guard let address else { return nil }
        return SessionEndpoint(host: address.host, port: vnc.port).screenSharingURL(username: vnc.username)
    }

    /// Probes the port the default profile uses; addresses carry no port of their own.
    private var probePort: Int {
        let profiles = store.snapshot.orderedProfiles(for: machine)
        let profile = machine.defaultProfileID.flatMap { id in profiles.first { $0.id == id } } ?? profiles.first
        return profile?.port ?? profile?.protocolKind.defaultPort ?? 22
    }

    @ViewBuilder
    private func reachability(for address: MachineAddress) -> some View {
        switch probes[address.id] {
        case .checking:
            ProgressView()
                .controlSize(.small)
                .accessibilityLabel("Checking reachability")
        case .reachable:
            Label("Reachable", systemImage: "checkmark.circle.fill")
                .foregroundStyle(.green)
                .help("Port \(probePort) accepted a TCP connection")
        case .unreachable:
            Label("Unreachable", systemImage: "xmark.circle.fill")
                .foregroundStyle(.red)
                .help("Port \(probePort) did not accept a TCP connection")
        case nil:
            Button("Check") { probe(address) }
                .help("Try a TCP connection to port \(probePort)")
        }
    }

    private func probe(_ address: MachineAddress) {
        probes[address.id] = .checking
        let port = probePort
        Task {
            let reachable = await prober.canConnect(host: address.host, port: port, timeout: .seconds(3))
            probes[address.id] = reachable ? .reachable : .unreachable
        }
    }

    private func connect(_ profileID: ProfileID) {
        Task {
            do { try await sessions.open(profileID: profileID) }
            catch { sessions.present(error, title: "Couldn’t Connect") }
        }
    }

    private func sessionColor(for state: SessionState) -> Color {
        switch state {
        case .connected: .green
        case .connecting, .awaitingUserInput, .disconnecting: .orange
        case .failed: .red
        case .disconnected: .secondary
        }
    }
}

/// Hosts a remote desktop view with connection state on top.
private struct RemoteDesktopPane: View {
    let session: any RemoteDesktopSession
    let state: SessionState
    let onReconnect: () -> Void

    var body: some View {
        RemoteDesktopHostRepresentable(view: session.view)
            .overlay {
                if case .connecting = state {
                    VStack(spacing: 10) {
                        ProgressView()
                        Text("Connecting…").foregroundStyle(.secondary)
                    }
                    .padding(20)
                    .glassSurface(in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                    .accessibilityElement(children: .combine)
                    .accessibilityAddTraits(.updatesFrequently)
                }
            }
            .overlay(alignment: .top) {
                if !state.hasLiveProcess {
                    HStack(spacing: 10) {
                        Text(statusText).font(.callout)
                        Button("Reconnect", action: onReconnect)
                            .controlSize(.small)
                            .keyboardShortcut(.defaultAction)
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .glassSurface(in: Capsule())
                    .padding(.top, 8)
                    .accessibilityElement(children: .combine)
                    .accessibilityAddTraits(.updatesFrequently)
                }
            }
            .onAppear { session.focus() }
    }

    private var statusText: String {
        if case .failed(let failure) = state { return failure.localizedDescription }
        return "Session disconnected"
    }
}

private struct RemoteDesktopHostRepresentable: NSViewRepresentable {
    let view: NSView

    func makeNSView(context: Context) -> NSView { view }
    func updateNSView(_ nsView: NSView, context: Context) {}
}
