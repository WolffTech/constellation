import ConstellationCore
import SwiftUI

struct QuickConnectView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var targetText = ""
    @State private var validationMessage: String?
    @FocusState private var targetFocused: Bool

    let onConnect: (QuickConnectTarget) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Quick Connect").font(.title2.bold())
            TextField("user@host:port", text: $targetText)
                .textFieldStyle(.roundedBorder)
                .focused($targetFocused)
                .onSubmit(connect)
                .onChange(of: targetText) { validationMessage = nil }
            Text("Uses your SSH agent or OpenSSH configuration. Quick Connect tabs are not restored after relaunch.")
                .font(.callout)
                .foregroundStyle(.secondary)
            if let validationMessage {
                Text(validationMessage).foregroundStyle(.red).font(.callout)
            }
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Connect", action: connect)
                    .keyboardShortcut(.defaultAction)
                    .disabled(targetText.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(20)
        .frame(width: 440)
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
        VStack(alignment: .leading, spacing: 16) {
            Text("Save as Machine").font(.title2.bold())
            TextField("Machine name", text: $machineName)
                .textFieldStyle(.roundedBorder)
                .focused($nameFocused)
                .onSubmit(save)
                .onChange(of: machineName) { errorMessage = nil }
            if let errorMessage { Text(errorMessage).foregroundStyle(.red).font(.callout) }
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Save", action: save)
                    .keyboardShortcut(.defaultAction)
                    .disabled(machineName.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(20)
        .frame(width: 400)
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
