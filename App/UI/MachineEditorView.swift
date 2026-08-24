import AppKit
import ConstellationCore
import SwiftUI

struct MachineEditorView: View {
    @State private var draft: MachineDraft
    /// What the sheet opened with, so Cancel can tell whether anything changed.
    private let original: MachineDraft
    let store: MachineStore
    let onSaved: (MachineID) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var saving = false
    @State private var confirmingDiscard = false
    @FocusState private var nameFocused: Bool

    init(draft: MachineDraft, store: MachineStore, onSaved: @escaping (MachineID) -> Void) {
        _draft = State(initialValue: draft)
        original = draft
        self.store = store
        self.onSaved = onSaved
    }

    private var hasChanges: Bool { draft != original }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                Image(systemName: "server.rack")
                    .font(.title2)
                    .foregroundStyle(.secondary)
                VStack(alignment: .leading, spacing: 2) {
                    Text(draft.isNew ? "Add Machine" : "Edit Machine")
                        .font(.title2.bold())
                    Text("Define how Constellation finds and connects to this machine.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                Spacer()
            }
            .padding(.horizontal, 24)
            .padding(.top, 20)
            .padding(.bottom, 14)

            Divider()

            Form {
                Section("Machine") {
                    TextField("Name", text: $draft.machine.name, prompt: Text("Machine name"))
                        .focused($nameFocused)
                    TextField("Tags", text: $draft.tagsText, prompt: Text("Comma separated"))
                    Toggle("Favorite", isOn: $draft.machine.isFavorite)
                    TextField("Notes", text: $draft.machine.notes, prompt: Text("Optional notes"), axis: .vertical)
                        .lineLimit(2...5)
                }

                ForEach($draft.addresses) { $address in
                    AddressSection(address: $address) { draft.removeAddress(address.id) }
                }
                Section {
                    Button { draft.addAddress() } label: {
                        Label("Add Address", systemImage: "plus")
                    }
                } footer: {
                    Text("Addresses are tried in this order when a profile uses automatic selection.")
                }

                ForEach($draft.profiles) { $profile in
                    SSHProfileSection(
                        draft: $profile,
                        addresses: draft.addresses,
                        isDefault: draft.machine.defaultProfileID == profile.id,
                        onMakeDefault: { draft.machine.defaultProfileID = profile.id },
                        onRemove: { draft.removeProfile(profile.id) })
                }
                Section {
                    Button { draft.addProfile() } label: {
                        Label("Add SSH Profile", systemImage: "plus")
                    }
                }
            }
            .formStyle(.grouped)

            Divider()
            HStack {
                Spacer()
                Button("Cancel", action: cancel)
                    .keyboardShortcut(.cancelAction)
                Button(draft.isNew ? "Add Machine" : "Save") { Task { await save() } }
                    .keyboardShortcut(.defaultAction)
                    .disabled(saving)
            }
            .padding()
            .background(.bar)
        }
        .frame(minWidth: 680, idealWidth: 720, minHeight: 620, idealHeight: 700)
        .interactiveDismissDisabled(saving || hasChanges)
        .defaultFocus($nameFocused, true)
        .onAppear { nameFocused = true }
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

private struct AddressSection: View {
    @Binding var address: MachineAddress
    let onRemove: () -> Void

    var body: some View {
        Section {
            TextField("Label", text: $address.label, prompt: Text("Optional, such as Home or Office"))
            TextField("Hostname or IP", text: $address.host, prompt: Text("server.example.com"))
            Picker("Network", selection: $address.kind) {
                ForEach(AddressKind.allCases, id: \.self) { Text($0.displayName).tag($0) }
            }
        } header: {
            HStack {
                Label(address.displayLabel, systemImage: "network")
                Spacer()
                Button(role: .destructive, action: onRemove) {
                    Image(systemName: "trash")
                }
                .buttonStyle(.borderless)
                .help("Remove address")
            }
        }
    }
}

private struct SSHProfileSection: View {
    @Binding var draft: SSHProfileDraft
    let addresses: [MachineAddress]
    let isDefault: Bool
    let onMakeDefault: () -> Void
    let onRemove: () -> Void

    var body: some View {
        Section {
            TextField("Profile name", text: $draft.profile.name, prompt: Text("SSH"))
            TextField("Username", text: username, prompt: Text("Optional"))
            TextField("Port", value: $draft.profile.port, format: .number.grouping(.never), prompt: Text("22"))
            Picker("Address", selection: $draft.profile.addressSelection) {
                Text("Automatic (first reachable)").tag(AddressSelection.automatic)
                ForEach(addresses) { address in
                    Text("\(address.label) — \(address.host)").tag(AddressSelection.pinned(address.id))
                }
            }
            Picker("Authentication", selection: $draft.authMode) {
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
                secretRow
            }
        } header: {
            HStack(spacing: 8) {
                Label(draft.profile.name.isEmpty ? "SSH Profile" : draft.profile.name, systemImage: "terminal")
                if isDefault {
                    Text("Default")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 7)
                        .padding(.vertical, 2)
                        .background(.quaternary, in: Capsule())
                } else {
                    Button("Make Default", action: onMakeDefault)
                        .controlSize(.small)
                }
                Spacer()
                Button(role: .destructive, action: onRemove) {
                    Image(systemName: "trash")
                }
                .buttonStyle(.borderless)
                .help("Remove profile")
            }
        }
    }

    @ViewBuilder
    private var secretRow: some View {
        let title = draft.authMode == .password ? "Password" : "Key passphrase"
        if draft.hasStoredSecret, draft.enteredSecret == nil {
            LabeledContent(title) {
                HStack {
                    Label("\(title) saved in Keychain", systemImage: "key.fill")
                    Spacer()
                    Button("Replace…") { draft.enteredSecret = "" }
                    Button("Remove") { draft.removeStoredSecret() }
                }
            }
        } else {
            LabeledContent(title) {
                HStack {
                    SecureField(title, text: secret, prompt: Text(draft.authMode == .password ? "Password" : "Leave empty if the key has none"))
                        .labelsHidden()
                    if draft.hasStoredSecret {
                        Button("Keep Saved") { draft.enteredSecret = nil }
                    }
                }
            }
        }
    }

    private var username: Binding<String> {
        Binding(
            get: { draft.profile.username ?? "" },
            set: { draft.profile.username = $0.isEmpty ? nil : $0 })
    }

    private var secret: Binding<String> {
        Binding(get: { draft.enteredSecret ?? "" }, set: { draft.enteredSecret = $0 })
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
