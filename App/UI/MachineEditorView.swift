import AppKit
import ConstellationCore
import SwiftUI

struct MachineEditorView: View {
    @State var draft: MachineDraft
    let store: MachineStore
    let onSaved: (MachineID) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var saving = false

    var body: some View {
        VStack(spacing: 0) {
            Form {
                Section("Machine") {
                    TextField("Name", text: $draft.machine.name)
                    TextField("Tags (comma separated)", text: $draft.tagsText)
                    Toggle("Favorite", isOn: $draft.machine.isFavorite)
                    TextField("Notes", text: $draft.machine.notes, axis: .vertical)
                        .lineLimit(2...5)
                }

                Section {
                    ForEach($draft.addresses) { $address in
                        AddressRow(address: $address) { draft.removeAddress(address.id) }
                    }
                    Button("Add Address") { draft.addAddress() }
                } header: {
                    Text("Addresses")
                } footer: {
                    Text("Tried in this order when a profile uses automatic selection.")
                }

                Section("SSH Profiles") {
                    ForEach($draft.profiles) { $profile in
                        SSHProfileEditor(
                            draft: $profile,
                            addresses: draft.addresses,
                            isDefault: draft.machine.defaultProfileID == profile.id,
                            onMakeDefault: { draft.machine.defaultProfileID = profile.id },
                            onRemove: { draft.removeProfile(profile.id) })
                    }
                    Button("Add Profile") { draft.addProfile() }
                }
            }
            .formStyle(.grouped)

            Divider()
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button(draft.isNew ? "Add Machine" : "Save") { Task { await save() } }
                    .keyboardShortcut(.defaultAction)
                    .disabled(saving)
            }
            .padding()
        }
        .frame(minWidth: 600, idealWidth: 640, minHeight: 560)
        .alert("Couldn’t Save", isPresented: Binding(get: { store.presentedError != nil }, set: { if !$0 { store.presentedError = nil } })) {
            Button("OK") {}
        } message: {
            Text(store.presentedError ?? "")
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

private struct AddressRow: View {
    @Binding var address: MachineAddress
    let onRemove: () -> Void

    var body: some View {
        HStack {
            TextField("Label", text: $address.label)
                .frame(width: 110)
            TextField("Hostname or IP", text: $address.host)
                .monospaced()
            Picker("Kind", selection: $address.kind) {
                ForEach(AddressKind.allCases, id: \.self) { Text($0.displayName).tag($0) }
            }
            .labelsHidden()
            .frame(width: 110)
            Button(role: .destructive, action: onRemove) {
                Image(systemName: "minus.circle")
            }
            .buttonStyle(.borderless)
            .help("Remove address")
        }
    }
}

private struct SSHProfileEditor: View {
    @Binding var draft: SSHProfileDraft
    let addresses: [MachineAddress]
    let isDefault: Bool
    let onMakeDefault: () -> Void
    let onRemove: () -> Void

    var body: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    TextField("Profile name", text: $draft.profile.name)
                    if isDefault {
                        Text("default").font(.caption).foregroundStyle(.secondary)
                    } else {
                        Button("Make Default", action: onMakeDefault).controlSize(.small)
                    }
                    Button(role: .destructive, action: onRemove) { Image(systemName: "minus.circle") }
                        .buttonStyle(.borderless)
                        .help("Remove profile")
                }
                HStack {
                    TextField("Username", text: username)
                    Text("Port")
                    TextField("Port", value: $draft.profile.port, format: .number.grouping(.never))
                        .frame(width: 70)
                }
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
                    HStack {
                        TextField("Private key file", text: $draft.keyFilePath).monospaced()
                        Button("Choose…") { chooseKeyFile() }
                    }
                }
                if draft.needsSecret {
                    secretRow
                }
            }
            .padding(4)
        }
    }

    @ViewBuilder
    private var secretRow: some View {
        let title = draft.authMode == .password ? "Password" : "Key passphrase"
        if draft.hasStoredSecret, draft.enteredSecret == nil {
            HStack {
                Label("\(title) saved in Keychain", systemImage: "key.fill")
                Spacer()
                Button("Replace…") { draft.enteredSecret = "" }
                Button("Remove") { draft.removeStoredSecret() }
            }
        } else {
            HStack {
                SecureField(draft.authMode == .password ? "Password" : "Key passphrase (leave empty if none)", text: secret)
                if draft.hasStoredSecret {
                    Button("Keep Saved") { draft.enteredSecret = nil }
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
