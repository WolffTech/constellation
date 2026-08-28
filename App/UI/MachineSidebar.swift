// SPDX-FileCopyrightText: 2026 Nick Wolff <nick@wolff.tech>
// SPDX-License-Identifier: GPL-3.0-only

import ConstellationCore
import SwiftUI

/// What a sidebar row stands for. Machines and their profiles share one selection.
enum SidebarItem: Hashable {
    case machine(MachineID)
    case profile(ProfileID)
}

struct MachineSidebar: View {
    let store: MachineStore
    let sessions: SessionCoordinator
    let ui: UIState
    let expansion: SidebarExpansionStore
    let trustedCertificates: TrustedCertificatesModel
    @Environment(ShortcutSettingsStore.self) private var shortcuts
    @Binding var searchText: String
    let onDelete: (Machine) -> Void

    var body: some View {
        List(selection: selection) {
            if !favorites.isEmpty {
                Section("Favorites") { ForEach(favorites) { machineRow($0) } }
            }
            ForEach(groups, id: \.name) { group in
                Section(group.name) { ForEach(group.machines) { machineRow($0) } }
            }
        }
        .searchable(text: $searchText, placement: .sidebar, prompt: "Search machines")
        .navigationTitle("Machines")
        .onDeleteCommand {
            // Profiles are removed in the editor; ⌫ only deletes whole machines.
            if ui.selectedProfileID == nil, let machine = selectedMachine { onDelete(machine) }
        }
        .onKeyPress(.return) {
            if let id = ui.selectedProfileID {
                connect(profileID: id)
            } else if let machine = selectedMachine {
                connectDefaultProfile(of: machine)
            } else {
                return .ignored
            }
            return .handled
        }
        .toolbar {
            ToolbarItem {
                Button { ui.editor = .new } label: { Label("New Machine", systemImage: "plus") }
                    .help("New Machine" + shortcuts.hintSuffix(for: .newMachine))
            }
        }
        .overlay {
            if store.snapshot.machines.isEmpty {
                ContentUnavailableView("No Machines", systemImage: "server.rack",
                                       description: Text(shortcuts.hint(for: .newMachine).map { "Press \($0) to add one." } ?? "Add one from the File menu."))
            } else if filtered.isEmpty {
                ContentUnavailableView.search(text: searchText)
            }
        }
    }

    private var selection: Binding<SidebarItem?> {
        Binding(
            get: {
                if let id = ui.selectedProfileID { return .profile(id) }
                return ui.selectedMachineID.map(SidebarItem.machine)
            },
            set: { item in
                switch item {
                case .machine(let id):
                    ui.selectedMachineID = id
                    ui.selectedProfileID = nil
                    sessions.select(nil)
                case .profile(let id):
                    guard sessions.selectFirstSession(forProfile: id) else { return }
                    ui.selectedMachineID = store.snapshot.profile(id)?.machineID
                    ui.selectedProfileID = id
                case nil:
                    ui.selectedMachineID = nil
                    ui.selectedProfileID = nil
                }
            })
    }

    private var selectedMachine: Machine? {
        ui.selectedMachineID.flatMap(store.snapshot.machine)
    }

    private var filtered: [Machine] {
        let query = searchText.trimmingCharacters(in: .whitespaces).lowercased()
        guard !query.isEmpty else { return store.snapshot.machines }
        return store.snapshot.machines.filter { machine in
            machine.name.lowercased().contains(query)
                || machine.tags.contains { $0.lowercased().contains(query) }
                || store.snapshot.addresses(for: machine.id).contains { $0.host.lowercased().contains(query) }
                || store.snapshot.profiles(for: machine.id).contains { $0.name.lowercased().contains(query) }
        }
    }

    private var favorites: [Machine] { filtered.filter(\.isFavorite) }

    private var groups: [(name: String, machines: [Machine])] {
        let tags = Set(filtered.flatMap(\.tags)).sorted()
        var groups: [(String, [Machine])] = tags.map { tag in
            (tag.capitalized, filtered.filter { $0.tags.contains(tag) })
        }
        let untagged = filtered.filter(\.tags.isEmpty)
        if !untagged.isEmpty { groups.append((tags.isEmpty ? "All" : "Other", untagged)) }
        return groups.map { (name: $0.0, machines: $0.1) }
    }

    private func machineRow(_ machine: Machine) -> some View {
        let profiles = store.snapshot.orderedProfiles(for: machine)
        return DisclosureGroup(isExpanded: expansion.binding(for: machine.id)) {
            ForEach(profiles) { profileRow($0, of: machine) }
        } label: {
            Label(machine.name, systemImage: "server.rack")
                .badge(sessions.openSessionCount(forMachine: machine.id))
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
                .help(hosts(of: machine))
                .contextMenu {
                    Button("Connect") { connectDefaultProfile(of: machine) }
                    if profiles.count > 1 {
                        Menu("Connect With") {
                            ForEach(profiles) { profile in
                                Button(profile.name, systemImage: profile.protocolKind.symbolName) { connect(profileID: profile.id) }
                            }
                        }
                    }
                    Button("Edit…") { ui.editor = .edit(machine.id) }
                    Button(machine.isFavorite ? "Remove from Favorites" : "Add to Favorites") {
                        var updated = machine
                        updated.isFavorite.toggle()
                        Task { await store.save(.upsertMachine(updated)) }
                    }
                    Divider()
                    Button("Delete…", role: .destructive) { onDelete(machine) }
                }
        }
        .tag(SidebarItem.machine(machine.id))
    }

    private func profileRow(_ profile: ConnectionProfile, of machine: Machine) -> some View {
        Label(profile.name, systemImage: profile.protocolKind.symbolName)
            .badge(sessions.openSessionCount(forProfile: profile.id))
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
            .onTapGesture(count: 2) { connect(profileID: profile.id) }
            .help(profileHelp(profile, of: machine))
            .contextMenu {
                Button("Connect") { connect(profileID: profile.id) }
                Button("Edit Machine…") { ui.editor = .edit(machine.id) }
                if case .rdp(let rdp) = profile {
                    Divider()
                    Button("Forget Trusted Certificate") { forgetCertificate(for: rdp, of: machine) }
                }
            }
            .tag(SidebarItem.profile(profile.id))
    }

    private func hosts(of machine: Machine) -> String {
        let hosts = store.snapshot.addresses(for: machine.id).map(\.host).joined(separator: ", ")
        return hosts.isEmpty ? "No addresses" : hosts
    }

    private func profileHelp(_ profile: ConnectionProfile, of machine: Machine) -> String {
        var parts = [profile.protocolKind.displayName]
        if let username = profile.username, !username.isEmpty { parts.append(username) }
        if let port = profile.port, port != profile.protocolKind.defaultPort { parts.append("port \(port)") }
        if machine.defaultProfileID == profile.id { parts.append("default") }
        parts.append("double-click to open a new session")
        return parts.joined(separator: " · ")
    }

    /// Revokes Always Trust for the RDP server, so the next connection prompts
    /// again. The profile may reach the machine through any of its addresses.
    private func forgetCertificate(for rdp: RDPProfile, of machine: Machine) {
        let hosts = store.snapshot.addresses(for: machine.id).map(\.host)
        Task { await trustedCertificates.forget(hosts: hosts, port: rdp.port) }
    }

    private func connect(profileID: ProfileID) {
        Task {
            do { try await sessions.open(profileID: profileID) }
            catch { sessions.present(error, title: "Couldn’t Connect") }
        }
    }

    private func connectDefaultProfile(of machine: Machine) {
        Task {
            do { try await sessions.openDefaultProfile(for: machine.id) }
            catch { sessions.present(error, title: "Couldn’t Connect") }
        }
    }
}
