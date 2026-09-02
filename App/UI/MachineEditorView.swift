// SPDX-FileCopyrightText: 2026 Nick Wolff <nick@wolff.tech>
// SPDX-License-Identifier: GPL-3.0-only

import AppKit
import ConstellationCore
import SwiftUI

/// Adds or edits a machine. A new machine starts as a five-field form that
/// creates one address and one profile; "More Options" and Edit Machine open
/// the full editor, a list of the machine's parts beside a form for the
/// selected one.
struct MachineEditorView: View {
    @State private var draft: MachineDraft
    /// What the sheet opened with, so Cancel can tell whether anything changed.
    private let original: MachineDraft
    let store: MachineStore
    let onSaved: (MachineID) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var showsAllOptions: Bool
    @State private var selection: EditorSelection = .general
    @State private var saving = false
    @State private var confirmingDiscard = false
    @FocusState private var nameFocused: Bool

    init(draft: MachineDraft, store: MachineStore, onSaved: @escaping (MachineID) -> Void) {
        _draft = State(initialValue: draft)
        _showsAllOptions = State(initialValue: !draft.isNew)
        original = draft
        self.store = store
        self.onSaved = onSaved
    }

    private var hasChanges: Bool { draft != original }

    var body: some View {
        VStack(spacing: 0) {
            SheetTitle(draft.isNew ? "Add Machine" : "Edit Machine")
            Divider()
            if showsAllOptions {
                fullEditor
            } else {
                QuickSetupForm(draft: $draft, store: store, nameFocused: $nameFocused) { showsAllOptions = true }
            }
        }
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("Cancel", action: cancel)
                    .keyboardShortcut(.cancelAction)
            }
            ToolbarItem(placement: .confirmationAction) {
                Button(draft.isNew ? "Add Machine" : "Save") { Task { await save() } }
                    .keyboardShortcut(.defaultAction)
                    .disabled(saving)
            }
        }
        .frame(
            minWidth: showsAllOptions ? 820 : 520, idealWidth: showsAllOptions ? 860 : 520,
            minHeight: showsAllOptions ? 540 : 410, idealHeight: showsAllOptions ? 580 : 410)
        .interactiveDismissDisabled(saving || hasChanges)
        .defaultFocus($nameFocused, true)
        .onAppear { nameFocused = true }
        .onChange(of: selection) { _, new in
            if !draft.contains(new) { selection = .general }
        }
        .confirmationDialog("Discard changes?", isPresented: $confirmingDiscard, titleVisibility: .visible) {
            Button("Discard Changes", role: .destructive) { dismiss() }
            Button("Keep Editing", role: .cancel) {}
        } message: {
            Text("This machine has unsaved edits.")
        }
        .alert("Couldn’t Save", isPresented: Binding(get: { store.presentedError != nil }, set: { if !$0 { store.presentedError = nil } })) {
            Button("OK") {}
        } message: {
            Text(store.presentedError ?? "")
        }
    }

    private var fullEditor: some View {
        HStack(spacing: 0) {
            EditorSidebar(draft: $draft, selection: $selection)
                .frame(width: 220)
            Divider()
            detail
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    @ViewBuilder
    private var detail: some View {
        switch selection {
        case .general:
            GeneralForm(draft: $draft, store: store, nameFocused: $nameFocused)
        case .address(let id):
            if let index = draft.addresses.firstIndex(where: { $0.id == id }) {
                AddressForm(address: $draft.addresses[index])
            }
        case .profile(let id):
            let isDefault = draft.effectiveDefaultProfileID == id
            let makeDefault = { draft.machine.defaultProfileID = id }
            if let index = draft.profiles.firstIndex(where: { $0.id == id }) {
                SSHProfileForm(draft: $draft.profiles[index], addresses: draft.addresses, isDefault: isDefault, onMakeDefault: makeDefault)
            } else if let index = draft.vncProfiles.firstIndex(where: { $0.id == id }) {
                VNCProfileForm(draft: $draft.vncProfiles[index], addresses: draft.addresses, isDefault: isDefault, onMakeDefault: makeDefault)
            } else if let index = draft.rdpProfiles.firstIndex(where: { $0.id == id }) {
                RDPProfileForm(draft: $draft.rdpProfiles[index], addresses: draft.addresses, isDefault: isDefault, onMakeDefault: makeDefault)
            }
        }
    }

    private func cancel() {
        if hasChanges {
            confirmingDiscard = true
        } else {
            dismiss()
        }
    }

    private func save() async {
        saving = true
        defer { saving = false }
        if await store.save(draft) {
            onSaved(draft.machine.id)
            dismiss()
        }
    }
}

/// Which part of the machine the full editor is showing.
enum EditorSelection: Hashable {
    case general
    case address(AddressID)
    case profile(ProfileID)
}

private extension MachineDraft {
    func contains(_ selection: EditorSelection) -> Bool {
        switch selection {
        case .general: true
        case .address(let id): addresses.contains { $0.id == id }
        case .profile(let id): profileIDs.contains(id)
        }
    }
}

// MARK: - Quick setup

private struct QuickSetupForm: View {
    @Binding var draft: MachineDraft
    let store: MachineStore
    var nameFocused: FocusState<Bool>.Binding
    let onMoreOptions: () -> Void

    private static let protocols: [ConnectionProtocol] = [.ssh, .vnc, .rdp]

    var body: some View {
        Form {
            Section {
                TextField("Name", text: $draft.machine.name, prompt: Text("Machine name"))
                    .focused(nameFocused)
                TextField("Host", text: $draft.quickHost, prompt: Text("server.example.com"))
                Picker("Connect via", selection: $draft.quickProtocol) {
                    ForEach(Self.protocols, id: \.self) { Text($0.displayName).tag($0) }
                }
                .pickerStyle(.segmented)
                TextField("Username", text: $draft.quickUsername, prompt: Text(usernamePrompt))
                SecureField("Password", text: $draft.quickPassword, prompt: Text(passwordPrompt))
                GroupPicker(groupID: $draft.machine.groupID, store: store)
                TextField("Tags", text: $draft.tagsText, prompt: Text("Comma separated"))
            } footer: {
                Text(footer)
            }
            Section {
                Button(action: onMoreOptions) {
                    Label("More Options…", systemImage: "slider.horizontal.3")
                }
            }
        }
        .formStyle(.grouped)
    }

    private var usernamePrompt: String {
        switch draft.quickProtocol {
        case .ssh: "Optional"
        case .vnc: "Needed for Apple Remote Desktop"
        case .rdp, .appleScreenSharing: "Asked when connecting if empty"
        }
    }

    private var passwordPrompt: String {
        switch draft.quickProtocol {
        case .ssh: "Leave empty to use your SSH agent"
        case .vnc, .rdp, .appleScreenSharing: "Optional; asked when connecting if empty"
        }
    }

    private var footer: String {
        let hasPassword = !draft.quickPassword.isEmpty
        let connection = switch draft.quickProtocol {
        case .ssh: hasPassword ? "Connects on port 22 with the password." : "Connects on port 22 with your SSH agent."
        case .vnc: hasPassword ? "Connects on port 5900 with the password." : "Connects on port 5900; the password is asked when connecting."
        case .rdp, .appleScreenSharing: "Connects on port 3389 with Network Level Authentication."
        }
        let keychain = hasPassword ? " The password is kept in Keychain." : ""
        return connection + keychain + " Key files, more addresses and other profiles are under More Options."
    }
}

// MARK: - Full editor

private struct EditorSidebar: View {
    @Binding var draft: MachineDraft
    @Binding var selection: EditorSelection

    var body: some View {
        VStack(spacing: 0) {
            List(selection: $selection) {
                Label("General", systemImage: "info.circle")
                    .tag(EditorSelection.general)
                Section("Addresses") {
                    ForEach(draft.addresses) { address in
                        Label(address.displayLabel, systemImage: "network")
                            .badge(address.host.isEmpty ? Text(Image(systemName: "exclamationmark.circle")) : nil)
                            .tag(EditorSelection.address(address.id))
                            .contextMenu { Button("Remove Address", role: .destructive) { remove(.address(address.id)) } }
                    }
                    .onMove { draft.addresses.move(fromOffsets: $0, toOffset: $1) }
                }
                Section("Profiles") {
                    ForEach(draft.profiles) { profile in
                        profileRow(profile.id, name: profile.profile.name, kind: .ssh)
                    }
                    ForEach(draft.vncProfiles) { profile in
                        profileRow(profile.id, name: profile.profile.name, kind: .vnc)
                    }
                    ForEach(draft.rdpProfiles) { profile in
                        profileRow(profile.id, name: profile.profile.name, kind: .rdp)
                    }
                }
            }
            .listStyle(.sidebar)
            .onDeleteCommand { remove(selection) }
            Divider()
            HStack(spacing: 0) {
                Menu {
                    Button("Address") { add { $0.addAddress() } ; select(.address(draft.addresses.last!.id)) }
                    Divider()
                    Button("SSH Profile") { add { $0.addProfile() }; select(.profile(draft.profiles.last!.id)) }
                    Button("VNC Profile") { add { $0.addVNCProfile() }; select(.profile(draft.vncProfiles.last!.id)) }
                    Button("RDP Profile") { add { $0.addRDPProfile() }; select(.profile(draft.rdpProfiles.last!.id)) }
                } label: {
                    Image(systemName: "plus")
                        .frame(width: 28, height: 24)
                        .contentShape(Rectangle())
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
                .help("Add an address or profile")
                .accessibilityLabel("Add")
                Divider().frame(height: 16)
                Button { remove(selection) } label: {
                    Image(systemName: "minus")
                        .frame(width: 28, height: 24)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.borderless)
                .disabled(selection == .general)
                .help("Remove the selected address or profile")
                .accessibilityLabel("Remove")
                Spacer()
            }
            .frame(height: 26)
        }
    }

    private func profileRow(_ id: ProfileID, name: String, kind: ConnectionProtocol) -> some View {
        Label(name.isEmpty ? "\(kind.displayName) Profile" : name, systemImage: kind.symbolName)
            .badge(draft.effectiveDefaultProfileID == id ? Text("Default") : nil)
            .tag(EditorSelection.profile(id))
            .contextMenu {
                Button("Make Default") { draft.machine.defaultProfileID = id }
                    .disabled(draft.effectiveDefaultProfileID == id)
                Button("Remove Profile", role: .destructive) { remove(.profile(id)) }
            }
    }

    private func add(_ change: (inout MachineDraft) -> Void) {
        change(&draft)
    }

    private func select(_ target: EditorSelection) {
        selection = target
    }

    private func remove(_ target: EditorSelection) {
        switch target {
        case .general: return
        case .address(let id): draft.removeAddress(id)
        case .profile(let id): draft.removeProfile(id)
        }
        if selection == target { selection = .general }
    }
}

private struct GeneralForm: View {
    @Binding var draft: MachineDraft
    let store: MachineStore
    var nameFocused: FocusState<Bool>.Binding

    var body: some View {
        Form {
            Section {
                TextField("Name", text: $draft.machine.name, prompt: Text("Machine name"))
                    .focused(nameFocused)
                GroupPicker(groupID: $draft.machine.groupID, store: store)
                TextField("Tags", text: $draft.tagsText, prompt: Text("Comma separated"))
                Toggle("Favorite", isOn: $draft.machine.isFavorite)
            }
            Section {
                TextField("Notes", text: $draft.machine.notes, prompt: Text("Optional notes"), axis: .vertical)
                    .lineLimit(3...8)
            }
        }
        .formStyle(.grouped)
    }
}

/// Chooses the sidebar group. A group created here is saved right away,
/// even if the machine is later cancelled.
private struct GroupPicker: View {
    @Binding var groupID: GroupID?
    let store: MachineStore
    @State private var creating = false
    @State private var newName = ""

    var body: some View {
        LabeledContent("Group") {
            HStack {
                Picker("Group", selection: $groupID) {
                    Text("None").tag(GroupID?.none)
                    ForEach(store.snapshot.groups) { Text($0.name).tag(Optional($0.id)) }
                }
                .labelsHidden()
                Button("New…") { newName = ""; creating = true }
            }
        }
        .alert("New Group", isPresented: $creating) {
            TextField("Name", text: $newName)
            Button("Cancel", role: .cancel) {}
            Button("Create", action: create)
                .disabled(newName.trimmingCharacters(in: .whitespaces).isEmpty)
        }
    }

    private func create() {
        let group = MachineGroup(name: newName.trimmingCharacters(in: .whitespaces))
        Task {
            if await store.save(.upsertGroup(group)) { groupID = group.id }
        }
    }
}

private struct AddressForm: View {
    @Binding var address: MachineAddress

    var body: some View {
        Form {
            Section {
                TextField("Label", text: $address.label, prompt: Text("Optional, such as Home or Office"))
                TextField("Hostname or IP", text: $address.host, prompt: Text("server.example.com"))
                Picker("Network", selection: $address.kind) {
                    ForEach(AddressKind.allCases, id: \.self) { Text($0.displayName).tag($0) }
                }
            } footer: {
                Text("Profiles set to automatic try addresses in the order listed; drag to reorder.")
            }
        }
        .formStyle(.grouped)
    }
}

/// The name row and default control every profile form starts with.
private struct ProfileHeaderSection: View {
    @Binding var name: String
    let prompt: String
    let isDefault: Bool
    let onMakeDefault: () -> Void

    var body: some View {
        Section {
            TextField("Name", text: $name, prompt: Text(prompt))
            LabeledContent("Default profile") {
                if isDefault {
                    Chip("Default")
                } else {
                    Button("Make Default", action: onMakeDefault)
                        .controlSize(.small)
                }
            }
        }
    }
}

private struct AddressPicker: View {
    @Binding var selection: AddressSelection
    let addresses: [MachineAddress]

    var body: some View {
        Picker("Address", selection: $selection) {
            Text("Automatic (first reachable)").tag(AddressSelection.automatic)
            ForEach(addresses) { address in
                Text("\(address.displayLabel) — \(address.host)").tag(AddressSelection.pinned(address.id))
            }
        }
    }
}

private struct SSHProfileForm: View {
    @Binding var draft: SSHProfileDraft
    let addresses: [MachineAddress]
    let isDefault: Bool
    let onMakeDefault: () -> Void

    var body: some View {
        Form {
            ProfileHeaderSection(name: $draft.profile.name, prompt: "SSH", isDefault: isDefault, onMakeDefault: onMakeDefault)
            Section("Connection") {
                TextField("Username", text: username, prompt: Text("Optional"))
                TextField("Port", value: $draft.profile.port, format: .number.grouping(.never), prompt: Text("22"))
                AddressPicker(selection: $draft.profile.addressSelection, addresses: addresses)
            }
            Section("Authentication") {
                Picker("Method", selection: $draft.authMode) {
                    ForEach(SSHProfileDraft.AuthMode.allCases) { Text($0.label).tag($0) }
                }
                if draft.authMode == .keyFile {
                    LabeledContent("Private key") {
                        HStack {
                            TextField("Private key", text: $draft.keyFilePath, prompt: Text("Path to private key"))
                                .labelsHidden()
                            Button("Choose…") { chooseKeyFile() }
                        }
                    }
                }
                if draft.needsSecret {
                    SecretRow(
                        title: draft.authMode == .password ? "Password" : "Key passphrase",
                        prompt: draft.authMode == .password ? "Password" : "Leave empty if the key has none",
                        hasStoredSecret: draft.hasStoredSecret,
                        enteredSecret: $draft.enteredSecret,
                        onRemoveStored: { draft.removeStoredSecret() })
                }
            }
        }
        .formStyle(.grouped)
    }

    private var username: Binding<String> {
        Binding(
            get: { draft.profile.username ?? "" },
            set: { draft.profile.username = $0.isEmpty ? nil : $0 })
    }

    private func chooseKeyFile() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.showsHiddenFiles = true
        panel.directoryURL = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".ssh")
        panel.message = "Choose the private key for this profile"
        if panel.runModal() == .OK, let url = panel.url {
            draft.keyFilePath = url.path
        }
    }
}

private struct VNCProfileForm: View {
    @Binding var draft: VNCProfileDraft
    let addresses: [MachineAddress]
    let isDefault: Bool
    let onMakeDefault: () -> Void

    var body: some View {
        Form {
            ProfileHeaderSection(name: $draft.profile.name, prompt: "VNC", isDefault: isDefault, onMakeDefault: onMakeDefault)
            Section("Connection") {
                TextField("Username", text: username, prompt: Text("Needed for Apple Remote Desktop"))
                TextField("Port", value: $draft.profile.port, format: .number.grouping(.never), prompt: Text("5900"))
                AddressPicker(selection: $draft.profile.addressSelection, addresses: addresses)
            }
            Section {
                SecretRow(
                    title: "Password",
                    prompt: "Optional; asked when connecting if empty",
                    hasStoredSecret: draft.hasStoredSecret,
                    enteredSecret: $draft.enteredSecret,
                    onRemoveStored: { draft.removeStoredSecret() })
                Toggle("Share clipboard with the remote desktop", isOn: $draft.profile.sharesClipboard)
            } footer: {
                Label(
                    "VNC is not encrypted. Everything in this session, including the password, crosses the network in the clear. Use it only on a trusted LAN, VPN or Tailscale route.",
                    systemImage: "lock.open")
            }
        }
        .formStyle(.grouped)
    }

    private var username: Binding<String> {
        Binding(
            get: { draft.profile.username ?? "" },
            set: { draft.profile.username = $0.isEmpty ? nil : $0 })
    }
}

private struct RDPProfileForm: View {
    @Binding var draft: RDPProfileDraft
    let addresses: [MachineAddress]
    let isDefault: Bool
    let onMakeDefault: () -> Void

    var body: some View {
        Form {
            ProfileHeaderSection(name: $draft.profile.name, prompt: "RDP", isDefault: isDefault, onMakeDefault: onMakeDefault)
            Section("Connection") {
                TextField("Username", text: username, prompt: Text("Asked when connecting if empty"))
                TextField("Domain", text: domain, prompt: Text("Optional; leave empty for a local account"))
                TextField("Port", value: $draft.profile.port, format: .number.grouping(.never), prompt: Text("3389"))
                AddressPicker(selection: $draft.profile.addressSelection, addresses: addresses)
            }
            Section {
                SecretRow(
                    title: "Password",
                    prompt: "Optional; asked when connecting if empty",
                    hasStoredSecret: draft.hasStoredSecret,
                    enteredSecret: $draft.enteredSecret,
                    onRemoveStored: { draft.removeStoredSecret() })
                Toggle("Share clipboard text with the remote desktop", isOn: $draft.profile.sharesClipboard)
            } footer: {
                Text("Connects with Network Level Authentication over TLS. The server's certificate is shown for approval on first use.")
            }
        }
        .formStyle(.grouped)
    }

    private var username: Binding<String> {
        Binding(
            get: { draft.profile.username ?? "" },
            set: { draft.profile.username = $0.isEmpty ? nil : $0 })
    }

    private var domain: Binding<String> {
        Binding(
            get: { draft.profile.domain ?? "" },
            set: { draft.profile.domain = $0.isEmpty ? nil : $0 })
    }
}

/// A secret that is never shown back: saved in Keychain, or typed now.
private struct SecretRow: View {
    let title: String
    let prompt: String
    let hasStoredSecret: Bool
    @Binding var enteredSecret: String?
    let onRemoveStored: () -> Void

    var body: some View {
        if hasStoredSecret, enteredSecret == nil {
            LabeledContent(title) {
                HStack {
                    Label("\(title) saved in Keychain", systemImage: "key.fill")
                    Spacer()
                    Button("Replace…") { enteredSecret = "" }
                    Button("Remove", action: onRemoveStored)
                }
            }
        } else {
            LabeledContent(title) {
                HStack {
                    SecureField(title, text: Binding(get: { enteredSecret ?? "" }, set: { enteredSecret = $0 }), prompt: Text(prompt))
                        .labelsHidden()
                    if hasStoredSecret {
                        Button("Keep Saved") { enteredSecret = nil }
                    }
                }
            }
        }
    }
}
