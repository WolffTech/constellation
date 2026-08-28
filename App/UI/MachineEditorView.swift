// SPDX-FileCopyrightText: 2026 Nick Wolff <nick@wolff.tech>
// SPDX-License-Identifier: GPL-3.0-only

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
        NavigationStack {
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
                ForEach($draft.vncProfiles) { $profile in
                    VNCProfileSection(
                        draft: $profile,
                        addresses: draft.addresses,
                        isDefault: draft.machine.defaultProfileID == profile.id,
                        onMakeDefault: { draft.machine.defaultProfileID = profile.id },
                        onRemove: { draft.removeProfile(profile.id) })
                }
                ForEach($draft.rdpProfiles) { $profile in
                    RDPProfileSection(
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
                    Button { draft.addVNCProfile() } label: {
                        Label("Add VNC Profile", systemImage: "plus")
                    }
                    Button { draft.addRDPProfile() } label: {
                        Label("Add RDP Profile", systemImage: "plus")
                    }
                }
            }
            .formStyle(.grouped)
            .navigationTitle(draft.isNew ? "Add Machine" : "Edit Machine")
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
                .accessibilityLabel("Remove \(address.displayLabel)")
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

    private var title: String { draft.profile.name.isEmpty ? "SSH Profile" : draft.profile.name }

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
                Label(title, systemImage: "terminal")
                if isDefault {
                    Chip("Default")
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
                .accessibilityLabel("Remove profile \(title)")
            }
        }
    }

    private var secretRow: some View {
        SecretRow(
            title: draft.authMode == .password ? "Password" : "Key passphrase",
            prompt: draft.authMode == .password ? "Password" : "Leave empty if the key has none",
            hasStoredSecret: draft.hasStoredSecret,
            enteredSecret: $draft.enteredSecret,
            onRemoveStored: { draft.removeStoredSecret() })
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

private struct VNCProfileSection: View {
    @Binding var draft: VNCProfileDraft
    let addresses: [MachineAddress]
    let isDefault: Bool
    let onMakeDefault: () -> Void
    let onRemove: () -> Void

    private var title: String { draft.profile.name.isEmpty ? "VNC Profile" : draft.profile.name }

    var body: some View {
        Section {
            TextField("Profile name", text: $draft.profile.name, prompt: Text("VNC"))
            TextField("Username", text: username, prompt: Text("Needed for Apple Remote Desktop"))
            TextField("Port", value: $draft.profile.port, format: .number.grouping(.never), prompt: Text("5900"))
            Picker("Address", selection: $draft.profile.addressSelection) {
                Text("Automatic (first reachable)").tag(AddressSelection.automatic)
                ForEach(addresses) { address in
                    Text("\(address.displayLabel) — \(address.host)").tag(AddressSelection.pinned(address.id))
                }
            }
            SecretRow(
                title: "Password",
                prompt: "Optional; asked when connecting if empty",
                hasStoredSecret: draft.hasStoredSecret,
                enteredSecret: $draft.enteredSecret,
                onRemoveStored: { draft.removeStoredSecret() })
            Toggle("Share clipboard with the remote desktop", isOn: $draft.profile.sharesClipboard)
        } header: {
            HStack(spacing: 8) {
                Label(title, systemImage: ConnectionProtocol.vnc.symbolName)
                if isDefault {
                    Chip("Default")
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
                .accessibilityLabel("Remove profile \(title)")
            }
        } footer: {
            Label(
                "VNC is not encrypted. Everything in this session, including the password, crosses the network in the clear. Use it only on a trusted LAN, VPN or Tailscale route.",
                systemImage: "lock.open")
        }
    }

    private var username: Binding<String> {
        Binding(
            get: { draft.profile.username ?? "" },
            set: { draft.profile.username = $0.isEmpty ? nil : $0 })
    }
}

private struct RDPProfileSection: View {
    @Binding var draft: RDPProfileDraft
    let addresses: [MachineAddress]
    let isDefault: Bool
    let onMakeDefault: () -> Void
    let onRemove: () -> Void

    private var title: String { draft.profile.name.isEmpty ? "RDP Profile" : draft.profile.name }

    var body: some View {
        Section {
            TextField("Profile name", text: $draft.profile.name, prompt: Text("RDP"))
            TextField("Username", text: username, prompt: Text("Asked when connecting if empty"))
            TextField("Domain", text: domain, prompt: Text("Optional; leave empty for a local account"))
            TextField("Port", value: $draft.profile.port, format: .number.grouping(.never), prompt: Text("3389"))
            Picker("Address", selection: $draft.profile.addressSelection) {
                Text("Automatic (first reachable)").tag(AddressSelection.automatic)
                ForEach(addresses) { address in
                    Text("\(address.displayLabel) — \(address.host)").tag(AddressSelection.pinned(address.id))
                }
            }
            SecretRow(
                title: "Password",
                prompt: "Optional; asked when connecting if empty",
                hasStoredSecret: draft.hasStoredSecret,
                enteredSecret: $draft.enteredSecret,
                onRemoveStored: { draft.removeStoredSecret() })
            Toggle("Share clipboard text with the remote desktop", isOn: $draft.profile.sharesClipboard)
        } header: {
            HStack(spacing: 8) {
                Label(title, systemImage: ConnectionProtocol.rdp.symbolName)
                if isDefault {
                    Chip("Default")
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
                .accessibilityLabel("Remove profile \(title)")
            }
        } footer: {
            Text("Connects with Network Level Authentication over TLS. The server's certificate is shown for approval on first use.")
        }
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
