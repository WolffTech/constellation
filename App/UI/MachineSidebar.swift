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
                    .help("New Machine (⌘N)")
            }
        }
        .overlay {
            if store.snapshot.machines.isEmpty {
                ContentUnavailableView("No Machines", systemImage: "server.rack", description: Text("Press ⌘N to add one."))
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
                case .profile(let id):
                    ui.selectedMachineID = store.snapshot.profile(id)?.machineID
                    ui.selectedProfileID = id
                case nil:
                    ui.selectedMachineID = nil
                    ui.selectedProfileID = nil
                }
                if item != nil { sessions.select(nil) }
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
            HStack {
                Label(machine.name, systemImage: "server.rack")
                Spacer()
                badge(sessions.count(for: machine.id))
            }
            .contentShape(Rectangle())
            .onTapGesture(count: 2) { connectDefaultProfile(of: machine) }
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
        HStack {
            Label(profile.name, systemImage: profile.protocolKind.symbolName)
            Spacer()
            badge(sessions.count(forProfile: profile.id))
        }
        .contentShape(Rectangle())
        .onTapGesture(count: 2) { connect(profileID: profile.id) }
        .help(profileHelp(profile, of: machine))
        .contextMenu {
            Button("Connect") { connect(profileID: profile.id) }
            Button("Edit Machine…") { ui.editor = .edit(machine.id) }
        }
        .tag(SidebarItem.profile(profile.id))
    }

    @ViewBuilder
    private func badge(_ count: Int) -> some View {
        if count > 0 {
            let description = "\(count) active \(count == 1 ? "session" : "sessions")"
            Text("\(count)")
                .font(.caption.monospacedDigit())
                .padding(.horizontal, 6)
                .padding(.vertical, 1)
                .background(Capsule().fill(Color.green.opacity(0.3)))
                .help(description)
                .accessibilityLabel(description)
        }
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
        return parts.joined(separator: " · ")
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
