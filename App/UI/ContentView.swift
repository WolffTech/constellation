import ConstellationCore
import SwiftUI

struct ContentView: View {
    let root: CompositionRoot

    var body: some View {
        if let store = root.store, let sessions = root.sessions {
            MainSplitView(store: store, sessions: sessions, ui: root.ui, expansion: root.sidebarExpansion)
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
    let sessions: SessionCoordinator
    let ui: UIState
    let expansion: SidebarExpansionStore

    @State private var searchText = ""
    @State private var pendingDelete: Machine?
    @State private var orphanedCredentials: [CredentialReference] = []

    var body: some View {
        NavigationSplitView {
            MachineSidebar(store: store, sessions: sessions, ui: ui, expansion: expansion, searchText: $searchText) { pendingDelete = $0 }
                .navigationSplitViewColumnWidth(min: 220, ideal: 260, max: 320)
        } detail: {
            WorkspaceDetailView(store: store, sessions: sessions, ui: ui)
        }
        .task {
            await store.reload()
            sessions.restoreWorkspace(from: store.snapshot)
            if ui.selectedMachineID == nil && sessions.selectedSessionID == nil {
                ui.selectedMachineID = (store.snapshot.machines.first(where: \.isFavorite) ?? store.snapshot.machines.first)?.id
            }
        }
        // The sidebar highlight follows whichever session is showing, however it was selected.
        .onChange(of: sessions.selectedSessionID) { _, id in
            guard let id, let session = sessions.sessions.first(where: { $0.id == id }) else { return }
            ui.selectedMachineID = session.machineID
            ui.selectedProfileID = session.profileID
        }
        .sheet(item: Binding(get: { ui.editor }, set: { ui.editor = $0 })) { editor in
            MachineEditorView(draft: draft(for: editor), store: store) { savedID in
                ui.selectedMachineID = savedID
                ui.selectedProfileID = nil
                sessions.select(nil)
            }
        }
        .sheet(isPresented: Binding(get: { ui.showsQuickConnect }, set: { ui.showsQuickConnect = $0 })) {
            QuickConnectView { target in
                ui.showsQuickConnect = false
                Task { _ = await sessions.openQuickConnect(target) }
            }
        }
        .sheet(item: Binding(
            get: { ui.saveQuickConnectSessionID.map(IdentifiedSession.init) },
            set: { ui.saveQuickConnectSessionID = $0?.id })) { item in
                SaveQuickConnectView(sessionID: item.id, sessions: sessions, store: store, ui: ui)
            }
        .alert(
            "Delete \"\(pendingDelete?.name ?? "")\"?",
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
        .alert(
            closeAlertTitle,
            isPresented: Binding(
                get: { sessions.pendingClose != nil },
                set: { if !$0 { sessions.pendingClose = nil } })
        ) {
            Button(closeAlertAction, role: .destructive) { sessions.confirmPendingClose() }
            Button("Cancel", role: .cancel) { sessions.pendingClose = nil }
        } message: {
            Text(closeAlertMessage)
        }
        .alert("Couldn’t Update Library", isPresented: storeErrorPresented) {
            Button("OK") {}
        } message: {
            Text(store.presentedError ?? "")
        }
        .alert(sessions.presentedError?.title ?? "", isPresented: sessionErrorPresented) {
            Button("OK") {}
        } message: {
            Text(sessions.presentedError?.message ?? "")
        }
    }

    private var closeAlertTitle: String {
        if case .others = sessions.pendingClose { "Close other sessions?" } else { "Close active session?" }
    }

    private var closeAlertAction: String {
        if case .others = sessions.pendingClose { "Close Others" } else { "Close Session" }
    }

    private var closeAlertMessage: String {
        guard case .others(let keeping) = sessions.pendingClose else {
            return "Closing the tab will disconnect its process."
        }
        let live = sessions.sessions.count { $0.id != keeping && $0.state.hasLiveProcess }
        return "\(live) other \(live == 1 ? "session is" : "sessions are") still connected and will be disconnected."
    }

    /// The editor sheet shows library errors itself while it is open.
    private var storeErrorPresented: Binding<Bool> {
        Binding(
            get: { ui.editor == nil && store.presentedError != nil },
            set: { if !$0 { store.presentedError = nil } })
    }

    private var sessionErrorPresented: Binding<Bool> {
        Binding(
            get: { sessions.presentedError != nil },
            set: { if !$0 { sessions.presentedError = nil } })
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
        sessions.closeSessions(for: machine.id)
        if ui.selectedMachineID == machine.id {
            ui.selectedMachineID = nil
            ui.selectedProfileID = nil
        }
        let orphans = await store.deleteMachine(machine.id)
        if !orphans.isEmpty { orphanedCredentials = orphans }
    }
}

private struct IdentifiedSession: Identifiable {
    let id: SessionID
}
