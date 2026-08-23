import ConstellationCore
import SwiftUI

struct MachineSidebar: View {
    let store: MachineStore
    let hub: SessionHub
    let ui: UIState
    @Binding var searchText: String
    let onDelete: (Machine) -> Void

    var body: some View {
        List(selection: Binding(get: { ui.selectedMachineID }, set: { ui.selectedMachineID = $0 })) {
            if !favorites.isEmpty {
                Section("Favorites") {
                    ForEach(favorites) { row($0) }
                }
            }
            ForEach(groups, id: \.name) { group in
                Section(group.name) {
                    ForEach(group.machines) { row($0) }
                }
            }
        }
        .searchable(text: $searchText, placement: .sidebar, prompt: "Search machines")
        .navigationTitle("Machines")
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

    private var filtered: [Machine] {
        let query = searchText.trimmingCharacters(in: .whitespaces).lowercased()
        guard !query.isEmpty else { return store.snapshot.machines }
        return store.snapshot.machines.filter { machine in
            machine.name.lowercased().contains(query)
                || machine.tags.contains { $0.lowercased().contains(query) }
                || store.snapshot.addresses(for: machine.id).contains { $0.host.lowercased().contains(query) }
        }
    }

    private var favorites: [Machine] {
        filtered.filter(\.isFavorite)
    }

    /// One section per tag; untagged machines fall under "Other" (or "All" when nothing is tagged).
    private var groups: [(name: String, machines: [Machine])] {
        let tags = Set(filtered.flatMap(\.tags)).sorted()
        var groups: [(String, [Machine])] = tags.map { tag in
            (tag.capitalized, filtered.filter { $0.tags.contains(tag) })
        }
        let untagged = filtered.filter(\.tags.isEmpty)
        if !untagged.isEmpty {
            groups.append((tags.isEmpty ? "All" : "Other", untagged))
        }
        return groups.map { (name: $0.0, machines: $0.1) }
    }

    private func row(_ machine: Machine) -> some View {
        HStack {
            Label(machine.name, systemImage: "server.rack")
            Spacer()
            if let active = hub.session(for: machine.id) {
                Text("1")
                    .font(.caption.monospacedDigit())
                    .padding(.horizontal, 6)
                    .padding(.vertical, 1)
                    .background(Capsule().fill(active.session.processState == .running ? Color.green.opacity(0.3) : Color.secondary.opacity(0.3)))
                    .help(active.session.processState == .running ? "Connected" : "Disconnected")
            }
        }
        .tag(machine.id)
        .contextMenu {
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
}
