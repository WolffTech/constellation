import ConstellationCore
import SwiftUI

struct ContentView: View {
    let root: CompositionRoot

    var body: some View {
        if let store = root.store, let hub = root.sessions {
            MainSplitView(store: store, hub: hub, ui: root.ui)
        } else {
            ContentUnavailableView(
                "Constellation could not start",
                systemImage: "exclamationmark.triangle",
                description: Text(root.startupError ?? "Unknown error"))
        }
    }
}

struct MainSplitView: View {
    let store: MachineStore
    let hub: SessionHub
    let ui: UIState

    @State private var searchText = ""
    @State private var pendingDelete: Machine?
    @State private var orphanedCredentials: [CredentialReference] = []

    var body: some View {
        NavigationSplitView {
            MachineSidebar(store: store, hub: hub, ui: ui, searchText: $searchText) { pendingDelete = $0 }
                .navigationSplitViewColumnWidth(min: 200, ideal: 240)
        } detail: {
            if let id = ui.selectedMachineID, let machine = store.snapshot.machine(id) {
                MachineDetailView(machine: machine, store: store, hub: hub, ui: ui)
            } else {
                ContentUnavailableView(
                    "No Machine Selected",
                    systemImage: "server.rack",
                    description: Text("Choose a machine in the sidebar, or press ⌘N to add one."))
            }
        }
        .task {
            await store.reload()
            if ui.selectedMachineID == nil {
                ui.selectedMachineID = (store.snapshot.machines.first(where: \.isFavorite) ?? store.snapshot.machines.first)?.id
            }
        }
        .sheet(item: Binding(get: { ui.editor }, set: { ui.editor = $0 })) { editor in
            MachineEditorView(draft: draft(for: editor), store: store) { savedID in
                ui.selectedMachineID = savedID
            }
        }
        .alert(
            "Delete “\(pendingDelete?.name ?? "")”?",
            isPresented: Binding(get: { pendingDelete != nil }, set: { if !$0 { pendingDelete = nil } }),
            presenting: pendingDelete
        ) { machine in
            Button("Delete", role: .destructive) { Task { await delete(machine) } }
            Button("Cancel", role: .cancel) {}
        } message: { _ in
            Text("Its addresses and profiles are removed and any open session is closed.")
        }
        .alert(
            "Remove unused credentials from Keychain?",
            isPresented: Binding(get: { !orphanedCredentials.isEmpty }, set: { if !$0 { orphanedCredentials = [] } })
        ) {
            Button("Remove", role: .destructive) {
                let credentials = orphanedCredentials
                Task { await store.removeCredentials(credentials) }
            }
            Button("Keep", role: .cancel) {}
        } message: {
            Text("No profile uses:\n" + orphanedCredentials.map(\.label).joined(separator: "\n"))
        }
        .alert("Something went wrong", isPresented: errorPresented) {
            Button("OK") {}
        } message: {
            Text(store.presentedError ?? hub.presentedError ?? "")
        }
    }

    private var errorPresented: Binding<Bool> {
        Binding(
            get: { ui.editor == nil && (store.presentedError != nil || hub.presentedError != nil) },
            set: { if !$0 { store.presentedError = nil; hub.presentedError = nil } })
    }

    private func draft(for editor: UIState.Editor) -> MachineDraft {
        switch editor {
        case .new:
            return MachineDraft(newMachine: "")
        case .edit(let id):
            guard let machine = store.snapshot.machine(id) else { return MachineDraft(newMachine: "") }
            return MachineDraft(editing: machine, in: store.snapshot)
        }
    }

    private func delete(_ machine: Machine) async {
        hub.disconnect(machine.id)
        if ui.selectedMachineID == machine.id { ui.selectedMachineID = nil }
        let orphans = await store.deleteMachine(machine.id)
        if !orphans.isEmpty { orphanedCredentials = orphans }
    }
}
