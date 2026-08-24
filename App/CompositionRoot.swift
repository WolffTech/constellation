import AppKit
import ConstellationCore
import ConstellationOpenSSH
import ConstellationStorage
import ConstellationTerminal
import Foundation
import Observation

/// Builds the app's long-lived objects.
@MainActor
@Observable
final class CompositionRoot {
    private(set) var store: MachineStore?
    private(set) var sessions: SessionCoordinator?
    private(set) var startupError: String?
    let ui = UIState()
    let terminalSettings: TerminalSettingsStore
    let sidebarExpansion: SidebarExpansionStore

    private var runtime: GhosttyRuntime?
    private var askPass: AskPassService?

    init(defaults: UserDefaults = .standard) {
        terminalSettings = TerminalSettingsStore(defaults: defaults)
        sidebarExpansion = SidebarExpansionStore(defaults: defaults)
        do {
            let vault = KeychainCredentialVault()
            let library = try GRDBMachineLibrary(path: Self.libraryPath())
            let store = MachineStore(library: library, vault: vault)
            self.store = store

            let runtime = try GhosttyRuntime(appearance: terminalSettings.appearance)
            self.runtime = runtime
            terminalSettings.applyAppearance = { [weak runtime] appearance in
                try runtime?.updateAppearance(appearance)
            }
            let askPass = try AskPassService(secrets: VaultSecretProvider(vault: vault)) { request in
                AskPassPrompter.ask(request)
            }
            self.askPass = askPass
            let driver = GhosttySSHSessionDriver(runtime: runtime, askPass: askPass)
            sessions = SessionCoordinator(library: library, prober: TCPAddressProber(), driver: driver)
        } catch {
            startupError = error.localizedDescription
        }
    }

    /// ⌘T: the profile selected in the sidebar, else the machine's default.
    func openDefaultProfile() {
        guard let sessions, let machineID = ui.selectedMachineID else { return }
        let profileID = ui.selectedProfileID
        Task {
            do {
                if let profileID { try await sessions.open(profileID: profileID) }
                else { try await sessions.openDefaultProfile(for: machineID) }
            } catch { sessions.present(error, title: "Couldn’t Connect") }
        }
    }

    func reconnectSelectedSession() {
        guard let sessions, let id = sessions.selectedSessionID else { return }
        Task {
            do { try await sessions.reconnect(sessionID: id) }
            catch { sessions.present(error, title: "Couldn’t Reconnect") }
        }
    }

    /// Confirms when live sessions exist, then persists the workspace before
    /// AppKit finishes quitting.
    func prepareForTermination() -> NSApplication.TerminateReply {
        guard let sessions else { return .terminateNow }
        if sessions.needsQuitConfirmation {
            let alert = NSAlert()
            alert.messageText = "Quit with active sessions?"
            alert.informativeText = "Quitting will disconnect every active session."
            alert.addButton(withTitle: "Quit")
            alert.addButton(withTitle: "Cancel")
            guard alert.runModal() == .alertFirstButtonReturn else { return .terminateCancel }
        }
        sessions.disconnectAllForTermination()
        Task {
            try? await sessions.persistWorkspace()
            NSApplication.shared.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }

    /// `~/Library/Application Support/Constellation/library.sqlite`, or
    /// `CONSTELLATION_LIBRARY_PATH` for development runs.
    private static func libraryPath() -> String {
        if let override = ProcessInfo.processInfo.environment["CONSTELLATION_LIBRARY_PATH"], !override.isEmpty {
            return override
        }
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return support.appendingPathComponent("Constellation/library.sqlite").path
    }
}

/// Presentation state driven from menu commands and views alike.
@MainActor
@Observable
final class UIState {
    enum Editor: Identifiable {
        case new
        case edit(MachineID)
        var id: String {
            switch self {
            case .new: "new"
            case .edit(let id): id.description
            }
        }
    }

    var editor: Editor?
    var selectedMachineID: MachineID?
    /// The profile row highlighted in the sidebar; always belongs to `selectedMachineID`.
    var selectedProfileID: ProfileID?
    var showsQuickConnect = false
    var saveQuickConnectSessionID: SessionID?
}

/// Native dialogs for ssh prompts the vault cannot answer.
@MainActor
enum AskPassPrompter {
    static func ask(_ request: AskPass.Request) -> AskPass.Response {
        let alert = NSAlert()
        alert.messageText = request.kind == .confirm ? "SSH needs confirmation" : "SSH needs a secret"
        alert.informativeText = request.prompt
        switch request.kind {
        case .confirm:
            alert.addButton(withTitle: "Yes")
            alert.addButton(withTitle: "No")
            return .confirmed(alert.runModal() == .alertFirstButtonReturn)
        case .secret:
            let field = NSSecureTextField(frame: NSRect(x: 0, y: 0, width: 260, height: 24))
            alert.accessoryView = field
            alert.addButton(withTitle: "OK")
            alert.addButton(withTitle: "Cancel")
            alert.window.initialFirstResponder = field
            guard alert.runModal() == .alertFirstButtonReturn else { return .denied }
            return .secret(field.stringValue)
        case .none:
            alert.addButton(withTitle: "OK")
            alert.runModal()
            return .confirmed(true)
        }
    }
}
