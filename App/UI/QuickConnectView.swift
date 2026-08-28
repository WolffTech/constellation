// SPDX-FileCopyrightText: 2026 Nick Wolff <nick@wolff.tech>
// SPDX-License-Identifier: GPL-3.0-only

import ConstellationCore
import SwiftUI

struct QuickConnectView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var targetText = ""
    @State private var validationMessage: String?
    @FocusState private var targetFocused: Bool

    let onConnect: (QuickConnectTarget) -> Void

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Target", text: $targetText, prompt: Text("user@host:port"))
                        .focused($targetFocused)
                        .onSubmit(connect)
                        .onChange(of: targetText) { validationMessage = nil }
                    if let validationMessage {
                        Label(validationMessage, systemImage: "exclamationmark.triangle")
                            .foregroundStyle(.red)
                            .font(.callout)
                    }
                } footer: {
                    Text("Uses your SSH agent or OpenSSH configuration. Quick Connect tabs are not restored after relaunch.")
                }
            }
            .formStyle(.grouped)
            .navigationTitle("Quick Connect")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel", role: .cancel) { dismiss() }
                        .keyboardShortcut(.cancelAction)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Connect", action: connect)
                        .keyboardShortcut(.defaultAction)
                        .disabled(targetText.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
        }
        .frame(width: 460, height: 220)
        .defaultFocus($targetFocused, true)
        .onAppear { targetFocused = true }
    }

    private func connect() {
        do {
            onConnect(try QuickConnectTarget(parsing: targetText))
        } catch {
            validationMessage = error.localizedDescription
        }
    }
}

struct SaveQuickConnectView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var machineName = ""
    @State private var errorMessage: String?
    @FocusState private var nameFocused: Bool

    let sessionID: SessionID
    let sessions: SessionCoordinator
    let store: MachineStore
    let ui: UIState

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Name", text: $machineName, prompt: Text("Machine name"))
                        .focused($nameFocused)
                        .onSubmit(save)
                        .onChange(of: machineName) { errorMessage = nil }
                    if let errorMessage {
                        Label(errorMessage, systemImage: "exclamationmark.triangle")
                            .foregroundStyle(.red)
                            .font(.callout)
                    }
                } footer: {
                    Text("The session's host becomes the machine's first address and its profile is saved with it.")
                }
            }
            .formStyle(.grouped)
            .navigationTitle("Save as Machine")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel", role: .cancel) { dismiss() }
                        .keyboardShortcut(.cancelAction)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save", action: save)
                        .keyboardShortcut(.defaultAction)
                        .disabled(machineName.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
        }
        .frame(width: 440, height: 200)
        .defaultFocus($nameFocused, true)
        .onAppear {
            nameFocused = true
            guard let session = sessions.sessions.first(where: { $0.id == sessionID }),
                  case .quick(let target) = session.target else { return }
            machineName = target.host
        }
    }

    private func save() {
        Task {
            do {
                let id = try await sessions.saveQuickConnect(
                    sessionID: sessionID,
                    machineName: machineName.trimmingCharacters(in: .whitespaces))
                await store.reload()
                ui.selectedMachineID = id
                ui.saveQuickConnectSessionID = nil
                dismiss()
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }
}
