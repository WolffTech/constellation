import ConstellationCore
import SwiftUI

/// Shows the selected machine; switches to the terminal while a session is open.
struct MachineDetailView: View {
    let machine: Machine
    let store: MachineStore
    let hub: SessionHub
    let ui: UIState

    var body: some View {
        if let active = hub.session(for: machine.id) {
            VStack(spacing: 0) {
                HStack {
                    Label("\(machine.name) · \(active.profile.name)", systemImage: "terminal")
                    Text(statusText(active.session.processState))
                        .foregroundStyle(.secondary)
                    Spacer()
                    if case .exited = active.session.processState {
                        Button("Reconnect") { hub.connect(active.profile, machine: machine, snapshot: store.snapshot) }
                    }
                    Button("Disconnect") { hub.disconnect(machine.id) }
                }
                .padding(8)
                .background(.bar)
                Divider()
                TerminalPane(session: active.session)
            }
            .navigationTitle(active.session.title.isEmpty ? machine.name : active.session.title)
        } else {
            MachineOverviewView(machine: machine, store: store, hub: hub, ui: ui)
        }
    }

    private func statusText(_ state: ConstellationTerminal.TerminalProcessState) -> String {
        switch state {
        case .running: "connected"
        case .exited: "disconnected"
        }
    }
}

import ConstellationTerminal

struct MachineOverviewView: View {
    let machine: Machine
    let store: MachineStore
    let hub: SessionHub
    let ui: UIState

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                HStack(alignment: .firstTextBaseline) {
                    Text(machine.name).font(.largeTitle.bold())
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
                    Spacer()
                    Button("Edit…") { ui.editor = .edit(machine.id) }
                        .keyboardShortcut("e")
                }

                if !machine.tags.isEmpty {
                    HStack {
                        ForEach(machine.tags.sorted(), id: \.self) { tag in
                            Text(tag)
                                .font(.caption)
                                .padding(.horizontal, 8)
                                .padding(.vertical, 3)
                                .background(Capsule().fill(.quaternary))
                        }
                    }
                }

                if !machine.notes.isEmpty {
                    Text(machine.notes).foregroundStyle(.secondary)
                }

                GroupBox("Addresses") {
                    let addresses = store.snapshot.addresses(for: machine.id)
                    if addresses.isEmpty {
                        Text("No addresses. Edit the machine to add one.").foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    ForEach(addresses) { address in
                        HStack {
                            Text(address.label).bold().frame(width: 110, alignment: .leading)
                            Text(address.host).monospaced()
                            Spacer()
                            Text(address.kind.displayName).foregroundStyle(.secondary)
                        }
                        .padding(.vertical, 2)
                    }
                }

                GroupBox("Profiles") {
                    let profiles = store.snapshot.profiles(for: machine.id)
                    if profiles.isEmpty {
                        Text("No profiles. Edit the machine to add one.").foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    ForEach(profiles) { profile in
                        HStack {
                            VStack(alignment: .leading) {
                                HStack(spacing: 6) {
                                    Text(profile.name).bold()
                                    if machine.defaultProfileID == profile.id {
                                        Text("default").font(.caption).foregroundStyle(.secondary)
                                    }
                                }
                                Text(summary(for: profile)).font(.callout).foregroundStyle(.secondary)
                            }
                            Spacer()
                            Button("Connect") { hub.connect(profile, machine: machine, snapshot: store.snapshot) }
                                .keyboardShortcut(machine.defaultProfileID == profile.id ? KeyboardShortcut("t") : nil)
                        }
                        .padding(.vertical, 2)
                    }
                }
            }
            .padding()
        }
        .navigationTitle(machine.name)
    }

    private func summary(for profile: ConnectionProfile) -> String {
        var parts = [profile.protocolKind.displayName]
        if let username = profile.username, !username.isEmpty { parts.append(username) }
        if let port = profile.port, port != profile.protocolKind.defaultPort { parts.append("port \(port)") }
        if case .ssh(let ssh) = profile {
            parts.append(ssh.authentication.displayName)
            if let id = ssh.credentialID, let credential = store.snapshot.credential(id) {
                parts.append("🔑 \(credential.label)")
            }
        }
        if case .pinned(let id) = profile.addressSelection,
           let address = store.snapshot.addresses(for: machine.id).first(where: { $0.id == id }) {
            parts.append("via \(address.label)")
        }
        return parts.joined(separator: " · ")
    }
}
