// SPDX-FileCopyrightText: 2026 Nick Wolff <nick@wolff.tech>
// SPDX-License-Identifier: GPL-3.0-only

import ConstellationCore
import SwiftUI

/// What a sidebar row stands for. Machines and their profiles share one selection.
enum SidebarItem: Hashable {
    case localMachine
    case localTerminal
    case machine(MachineID)
    case profile(ProfileID)
}

/// One row of the grouped machine list. `header(nil)` is the ungrouped section.
private enum SidebarRow: Hashable, Identifiable {
    case header(GroupID?)
    case machine(MachineID)

    var id: String {
        switch self {
        case .header(let group): "header-\(group?.description ?? "none")"
        case .machine(let id): "machine-\(id)"
        }
    }
}

private enum GroupPrompt: Identifiable {
    case new
    case rename(MachineGroup)

    var id: String {
        switch self {
        case .new: "new"
        case .rename(let group): group.id.description
        }
    }

    var title: String {
        switch self {
        case .new: "New Group"
        case .rename: "Rename Group"
        }
    }

    var confirmTitle: String {
        switch self {
        case .new: "Create"
        case .rename: "Rename"
        }
    }
}

/// Row styling shared by every sidebar section header.
private struct SectionRowChrome: ViewModifier {
    func body(content: Content) -> some View {
        content
            // Plain rows start inside the disclosure column; pull the title back to where a Section header sits.
            .padding(.leading, -13)
            .listRowInsets(EdgeInsets())
            .contentShape(Rectangle())
            .selectionDisabled()
            .accessibilityHeading(.h2)
    }
}

struct MachineSidebar: View {
    let store: MachineStore
    let sessions: SessionCoordinator
    let ui: UIState
    let expansion: SidebarExpansionStore
    let trustedCertificates: TrustedCertificatesModel
    let generalSettings: GeneralSettingsStore
    @Environment(ShortcutSettingsStore.self) private var shortcuts
    @Binding var searchText: String
    let onDelete: (Machine) -> Void
    @State private var localMachineExpanded = true
    @State private var groupPrompt: GroupPrompt?
    @State private var groupPromptName = ""
    @State private var dragSession = SidebarDragSession()

    var body: some View {
        List(selection: selection) {
            if localMatchesSearch {
                Section { localMachineRow }
            }
            if !favorites.isEmpty {
                sectionTitle("Favorites")
                // Favorites mirror machines that live in a group; reordering happens there.
                ForEach(favorites) { machineRow($0, reorderable: false) }
            }
            ForEach(rows) { row in
                switch row {
                case .header(let groupID):
                    groupHeader(groupID)
                case .machine(let id):
                    if let machine = store.snapshot.machine(id) {
                        // Positions mean nothing in a filtered list.
                        machineRow(machine, reorderable: !isSearching)
                    }
                }
            }
        }
        .background(SidebarTableDropFeedback())
        .animation(.default, value: rows)
        .searchable(text: $searchText, placement: .sidebar, prompt: "Search machines")
        .navigationTitle("Machines")
        .onChange(of: groupPrompt?.id) { _, _ in
            if case .rename(let group) = groupPrompt { groupPromptName = group.name } else { groupPromptName = "" }
        }
        .alert(groupPrompt?.title ?? "", isPresented: groupPromptPresented) {
            TextField("Name", text: $groupPromptName)
            Button("Cancel", role: .cancel) {}
            Button(groupPrompt?.confirmTitle ?? "OK", action: commitGroupPrompt)
                .disabled(groupPromptName.trimmingCharacters(in: .whitespaces).isEmpty)
        }
        .onDeleteCommand {
            // Profiles are removed in the editor; ⌫ only deletes whole machines.
            if ui.selectedProfileID == nil, let machine = selectedMachine { onDelete(machine) }
        }
        .onKeyPress(.return) {
            if ui.localSelection != nil {
                openLocalTerminal()
            } else if let id = ui.selectedProfileID {
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
            ToolbarItem {
                Button { groupPrompt = .new } label: { Label("New Group", systemImage: "folder.badge.plus") }
                    .help("New Group")
            }
        }
        .overlay {
            if !localMatchesSearch && filtered.isEmpty {
                if searchText.trimmingCharacters(in: .whitespaces).isEmpty {
                    ContentUnavailableView(
                        "No Machines",
                        systemImage: "server.rack",
                        description: Text("Add a machine from the File menu."))
                } else {
                    ContentUnavailableView.search(text: searchText)
                }
            }
        }
    }

    private var selection: Binding<SidebarItem?> {
        Binding(
            get: {
                switch ui.localSelection {
                case .machine: return .localMachine
                case .terminal: return .localTerminal
                case nil: break
                }
                if let id = ui.selectedProfileID { return .profile(id) }
                return ui.selectedMachineID.map(SidebarItem.machine)
            },
            set: { item in
                switch item {
                case .localMachine:
                    ui.localSelection = .machine
                    ui.selectedMachineID = nil
                    ui.selectedProfileID = nil
                    sessions.select(nil)
                case .localTerminal:
                    guard sessions.selectFirstLocalSession() else { return }
                    ui.localSelection = .terminal
                    ui.selectedMachineID = nil
                    ui.selectedProfileID = nil
                case .machine(let id):
                    ui.localSelection = nil
                    ui.selectedMachineID = id
                    ui.selectedProfileID = nil
                    sessions.select(nil)
                case .profile(let id):
                    guard sessions.selectFirstSession(forProfile: id) else { return }
                    ui.localSelection = nil
                    ui.selectedMachineID = store.snapshot.profile(id)?.machineID
                    ui.selectedProfileID = id
                case nil:
                    ui.localSelection = nil
                    ui.selectedMachineID = nil
                    ui.selectedProfileID = nil
                }
            })
    }

    private var selectedMachine: Machine? {
        ui.selectedMachineID.flatMap(store.snapshot.machine)
    }

    private var computerName: String {
        ProcessInfo.processInfo.hostName
    }

    private var localMatchesSearch: Bool {
        guard generalSettings.value.showsLocalMachine else { return false }
        let query = searchText.trimmingCharacters(in: .whitespaces).lowercased()
        return query.isEmpty || ["this mac", "local", "terminal", computerName.lowercased()].contains {
            $0.contains(query)
        }
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

    private var isSearching: Bool { !searchText.trimmingCharacters(in: .whitespaces).isEmpty }

    /// Headers and machines as one flat list, so a single `onMove` covers
    /// reordering within a group and moving between groups. Empty groups
    /// stay visible as drop targets unless a search is narrowing the list.
    private var rows: [SidebarRow] {
        var rows: [SidebarRow] = []
        for group in store.snapshot.groups {
            let machines = filtered.filter { $0.groupID == group.id }
            if machines.isEmpty && isSearching { continue }
            rows.append(.header(group.id))
            rows += machines.map { .machine($0.id) }
        }
        let ungrouped = filtered.filter { $0.groupID == nil }
        if !ungrouped.isEmpty {
            rows.append(.header(nil))
            rows += ungrouped.map { .machine($0.id) }
        }
        return rows
    }

    // MARK: Drag and drop

    /// `itemProvider` is the row-level drag source; `onDrag` never fires on macOS List rows.
    private func dragSource<Content: View>(_ item: SidebarDragItem, _ content: Content) -> some View {
        content.itemProvider {
            dragSession.item = item
            return item.itemProvider()
        }
    }

    private func dropTarget<Content: View>(
        _ content: Content,
        accepts: @escaping (SidebarDragItem) -> Bool,
        edgeSensitive: @escaping (SidebarDragItem) -> Bool = { _ in true },
        perform: @escaping (SidebarDragItem, DropEdge) -> Void
    ) -> some View {
        content.modifier(SidebarDropModifier(
            session: dragSession, accepts: accepts, edgeSensitive: edgeSensitive, perform: perform))
    }

    /// Puts a machine before or after `anchor` in the anchor's group, or at the top of `groupID` without one.
    private func place(_ id: MachineID, in groupID: GroupID?, relativeTo anchor: Machine? = nil, edge: DropEdge) {
        var position = 0
        if let anchor {
            let siblings = store.snapshot.machines(in: anchor.groupID).filter { $0.id != id }
            let index = siblings.firstIndex { $0.id == anchor.id } ?? siblings.count
            position = edge == .above ? index : index + 1
        }
        Task { await store.save(.moveMachine(id, to: groupID, position: position)) }
    }

    /// Puts a group before or after `anchor`, or last without one.
    private func place(group id: GroupID, relativeTo anchor: GroupID?, edge: DropEdge) {
        let others = store.snapshot.groups.filter { $0.id != id }
        var position = others.count
        if let anchor, let index = others.firstIndex(where: { $0.id == anchor }) {
            position = edge == .above ? index : index + 1
        }
        Task { await store.save(.moveGroup(id, position: position)) }
    }

    private func groupHeader(_ groupID: GroupID?) -> some View {
        let group = groupID.flatMap(store.snapshot.group)
        let title = group?.name ?? (store.snapshot.groups.isEmpty ? "All" : "Other")
        let header = dropTarget(
            sectionTitleText(title),
            accepts: { item in
                switch item {
                case .machine: true
                case .group(let id): id != groupID
                }
            },
            // A machine dropped on a header goes to the top of that group; a group lands beside it.
            edgeSensitive: { item in
                if case .group = item, groupID != nil { true } else { false }
            },
            perform: { item, edge in
                switch item {
                case .machine(let id): place(id, in: groupID, edge: edge)
                case .group(let id): place(group: id, relativeTo: groupID, edge: groupID == nil ? .above : edge)
                }
            })
        return Group {
            if let groupID, !isSearching {
                dragSource(.group(groupID), header)
            } else {
                header
            }
        }
            .modifier(SectionRowChrome())
            .contextMenu {
                if let group {
                    let index = store.snapshot.groups.firstIndex(of: group) ?? 0
                    Button("Rename…") { groupPrompt = .rename(group) }
                    Button("Move Up") { Task { await store.save(.moveGroup(group.id, position: index - 1)) } }
                        .disabled(index == 0)
                    Button("Move Down") { Task { await store.save(.moveGroup(group.id, position: index + 1)) } }
                        .disabled(index == store.snapshot.groups.count - 1)
                    Divider()
                }
                Button("New Group…") { groupPrompt = .new }
                if let group {
                    Divider()
                    Button("Delete Group", role: .destructive) { Task { await store.save(.deleteGroup(group.id)) } }
                        .help("Its machines move to Other")
                }
            }
    }

    private var groupPromptPresented: Binding<Bool> {
        Binding(get: { groupPrompt != nil }, set: { if !$0 { groupPrompt = nil } })
    }

    private func commitGroupPrompt() {
        guard let prompt = groupPrompt else { return }
        let name = groupPromptName.trimmingCharacters(in: .whitespaces)
        groupPrompt = nil
        let group = switch prompt {
        case .new: MachineGroup(name: name)
        case .rename(var existing): { existing.name = name; return existing }()
        }
        Task { await store.save(.upsertGroup(group)) }
    }

    private func sectionTitle(_ title: String) -> some View {
        sectionTitleText(title).modifier(SectionRowChrome())
    }

    /// The header content alone; drag and drop wrap this so the drag image
    /// is not clipped by the chrome's negative padding.
    private func sectionTitleText(_ title: String) -> some View {
        Text(title)
            .font(.caption.weight(.semibold))
            .foregroundStyle(.secondary)
            // Inside the view, not row insets, so the whole row height takes drops.
            .padding(.top, 8)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var localMachineRow: some View {
        DisclosureGroup(isExpanded: $localMachineExpanded) {
            Label("Terminal", systemImage: "terminal")
                .badge(sessions.openLocalSessionCount)
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
                .onTapGesture(count: 2, perform: openLocalTerminal)
                .help("Local shell · double-click to open a new session")
                .contextMenu {
                    Button("Open Terminal", action: openLocalTerminal)
                }
                .tag(SidebarItem.localTerminal)
        } label: {
            Label("This Mac", systemImage: "desktopcomputer")
                .badge(sessions.openLocalSessionCount)
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
                .help(computerName)
                .contextMenu {
                    Button("Open Terminal", action: openLocalTerminal)
                }
        }
        .tag(SidebarItem.localMachine)
    }

    private func machineRow(_ machine: Machine, reorderable: Bool) -> some View {
        Group {
            if reorderable {
                dragSource(.machine(machine.id), machineDisclosure(machine, reorderable: true))
            } else {
                machineDisclosure(machine, reorderable: false)
            }
        }
        .tag(SidebarItem.machine(machine.id))
    }

    private func machineDisclosure(_ machine: Machine, reorderable: Bool) -> some View {
        let profiles = store.snapshot.orderedProfiles(for: machine)
        return DisclosureGroup(isExpanded: expansion.binding(for: machine.id)) {
            ForEach(profiles) { profileRow($0, of: machine, reorderable: reorderable) }
        } label: {
            let label = Label(machine.name, systemImage: "server.rack")
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
                    if !store.snapshot.groups.isEmpty {
                        Menu("Move to") {
                            ForEach(store.snapshot.groups) { group in
                                Button(group.name) { moveToEnd(machine, of: group.id) }
                                    .disabled(machine.groupID == group.id)
                            }
                            Divider()
                            Button("Other") { moveToEnd(machine, of: nil) }
                                .disabled(machine.groupID == nil)
                        }
                    }
                    Button(machine.isFavorite ? "Remove from Favorites" : "Add to Favorites") {
                        var updated = machine
                        updated.isFavorite.toggle()
                        Task { await store.save(.upsertMachine(updated)) }
                    }
                    Divider()
                    Button("Delete…", role: .destructive) { onDelete(machine) }
                }
            if reorderable {
                dropTarget(
                    label,
                    accepts: { $0 != .machine(machine.id) && $0 != machine.groupID.map(SidebarDragItem.group) },
                    edgeSensitive: { isMachine($0) },
                    perform: { item, edge in
                        switch item {
                        case .machine(let id): place(id, in: machine.groupID, relativeTo: machine, edge: edge)
                        // A group dropped in the middle of another group lands after it.
                        case .group(let id): place(group: id, relativeTo: machine.groupID, edge: .below)
                        }
                    })
            } else {
                label
            }
        }
    }

    private func isMachine(_ item: SidebarDragItem) -> Bool {
        if case .machine = item { true } else { false }
    }

    private func profileRow(_ profile: ConnectionProfile, of machine: Machine, reorderable: Bool) -> some View {
        let label = Label(profile.name, systemImage: profile.protocolKind.symbolName)
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
        // Profiles hang below their machine, so a drop here means "after that machine".
        return Group {
            if reorderable {
                dropTarget(
                    label,
                    accepts: { $0 != .machine(machine.id) && $0 != machine.groupID.map(SidebarDragItem.group) },
                    edgeSensitive: { _ in false },
                    perform: { item, _ in
                        switch item {
                        case .machine(let id): place(id, in: machine.groupID, relativeTo: machine, edge: .below)
                        case .group(let id): place(group: id, relativeTo: machine.groupID, edge: .below)
                        }
                    })
            } else {
                label
            }
        }
        .tag(SidebarItem.profile(profile.id))
    }

    private func moveToEnd(_ machine: Machine, of groupID: GroupID?) {
        Task { await store.save(.moveMachine(machine.id, to: groupID, position: .max)) }
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

    private func openLocalTerminal() {
        sessions.openLocalTerminal()
    }
}
