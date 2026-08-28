// SPDX-FileCopyrightText: 2026 Nick Wolff <nick@wolff.tech>
// SPDX-License-Identifier: GPL-3.0-only

import AppKit
import ConstellationCore
import ConstellationOpenSSH
import ConstellationRDP
import ConstellationRemoteDesktop
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
    private(set) var trustedCertificates: TrustedCertificatesModel?
    let ui = UIState()
    let palette = CommandPaletteController()
    let quickConnectHistory: QuickConnectHistory
    let terminalSettings: TerminalSettingsStore
    let shortcuts: ShortcutSettingsStore
    let vncSettings: VNCSettingsStore
    let rdpSettings: RDPSettingsStore
    let sidebarExpansion: SidebarExpansionStore

    private var runtime: GhosttyRuntime?
    private var askPass: AskPassService?

    init(defaults: UserDefaults = .standard) {
        terminalSettings = TerminalSettingsStore(defaults: defaults)
        shortcuts = ShortcutSettingsStore(defaults: defaults)
        vncSettings = VNCSettingsStore(defaults: defaults)
        rdpSettings = RDPSettingsStore(defaults: defaults)
        sidebarExpansion = SidebarExpansionStore(defaults: defaults)
        quickConnectHistory = QuickConnectHistory(defaults: defaults)
        do {
            let vault = KeychainCredentialVault()
            let library = try GRDBMachineLibrary(path: Self.libraryPath())
            let trustStore = try GRDBTrustStore(path: Self.trustStorePath())
            let store = MachineStore(library: library, vault: vault)
            self.store = store
            trustedCertificates = TrustedCertificatesModel(store: trustStore)

            let runtime = try GhosttyRuntime(appearance: terminalSettings.appearance)
            self.runtime = runtime
            terminalSettings.diagnostics = runtime.configDiagnostics
            terminalSettings.applyAppearance = { [weak runtime] appearance in
                try runtime?.updateAppearance(appearance) ?? []
            }
            let askPass = try AskPassService(secrets: VaultSecretProvider(vault: vault)) { request in
                AskPassPrompter.ask(request)
            }
            self.askPass = askPass
            let driver = GhosttySSHSessionDriver(runtime: runtime, askPass: askPass)
            let vncSettings = vncSettings
            let rdpSettings = rdpSettings
            sessions = SessionCoordinator(
                library: library,
                prober: TCPAddressProber(),
                driver: driver,
                vncDriver: RoyalVNCSessionDriver(vault: vault, settings: { vncSettings.value }),
                rdpDriver: FreeRDPSessionDriver(vault: vault, trustStore: trustStore, settings: { rdpSettings.value }))
        } catch {
            startupError = error.localizedDescription
        }
        palette.root = self
    }

    /// Runs a menu command. Menus and the command palette both come through here.
    func perform(_ action: ShortcutAction) {
        switch action {
        case .newMachine: ui.editor = .new
        case .editMachine: if let id = ui.selectedMachineID { ui.editor = .edit(id) }
        case .importMachines: Task { await ImportExportPanels.importMachines(into: store) }
        case .exportMachines: ImportExportPanels.exportMachines(from: store)
        case .commandPalette: palette.toggle()
        case .quickConnect: palette.present(mode: .connect)
        case .connectDefaultProfile: openDefaultProfile()
        case .closeSession: if let sessions, let id = sessions.selectedSessionID { sessions.requestClose(sessionID: id) }
        case .closeOtherSessions: if let sessions, let id = sessions.selectedSessionID { sessions.requestCloseOthers(keeping: id) }
        case .closeWindow: (NSApplication.shared.keyWindow ?? NSApplication.shared.mainWindow)?.performClose(nil)
        case .reconnect: reconnectSelectedSession()
        case .disconnect: if let sessions, let id = sessions.selectedSessionID { sessions.disconnect(sessionID: id) }
        case .nextTab: sessions?.cycleSelection()
        case .previousTab: sessions?.cycleSelection(reverse: true)
        case .findInSession: sessions?.performSearch()
        case .fitToWindow: setDisplayMode(.fit)
        case .actualSize: setDisplayMode(.actualSize)
        case .saveSupportBundle: SupportBundlePanel.save(root: self)
        }
    }

    /// Whether `perform(_:)` would do something right now; menus grey out the rest.
    func isEnabled(_ action: ShortcutAction) -> Bool {
        switch action {
        case .newMachine, .importMachines, .exportMachines, .commandPalette, .quickConnect, .closeWindow,
             .nextTab, .previousTab, .saveSupportBundle:
            true
        case .editMachine, .connectDefaultProfile:
            ui.selectedMachineID != nil
        case .closeSession, .findInSession:
            sessions?.selectedSessionID != nil
        case .closeOtherSessions:
            (sessions?.sessions.count ?? 0) >= 2
        case .reconnect:
            sessions?.selectedSession?.state.hasLiveProcess == false
        case .disconnect:
            sessions?.selectedSession?.state.hasLiveProcess == true
        case .fitToWindow, .actualSize:
            selectedSessionIsRemoteDesktop
        }
    }

    func paletteItems(for query: String) -> [PaletteItem] {
        PaletteSearch(
            snapshot: store?.snapshot ?? .empty,
            sessions: sessions?.sessions ?? [],
            isEnabled: { [unowned self] in isEnabled($0) },
            shortcutHint: { [shortcuts] in shortcuts.hint(for: $0) }
        ).items(for: query)
    }

    func quickConnectItems(for query: String) -> [PaletteItem] {
        PaletteSearch(
            snapshot: .empty, sessions: [], isEnabled: { _ in false }, shortcutHint: { _ in nil }
        ).connectItems(for: query, recents: quickConnectHistory.targets)
    }

    func perform(_ item: PaletteItem) {
        switch item.kind {
        case .session(let id):
            sessions?.select(id)
        case .profile(let id):
            guard let sessions else { return }
            Task {
                do { try await sessions.open(profileID: id) }
                catch { sessions.present(error, title: "Couldn’t Connect") }
            }
        case .command(let action):
            perform(action)
        case .settings:
            NSApplication.shared.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil)
        case .quickConnect(let target):
            guard let sessions else { return }
            quickConnectHistory.record(target)
            Task { _ = await sessions.openQuickConnect(target) }
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

    var selectedSessionIsRemoteDesktop: Bool {
        guard let sessions, let id = sessions.selectedSessionID else { return false }
        return sessions.remoteDesktop(for: id) != nil
    }

    func setDisplayMode(_ mode: RemoteDesktopDisplayMode) {
        guard let sessions, let id = sessions.selectedSessionID else { return }
        sessions.setDisplayMode(mode, for: id)
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
    static func libraryPath() -> String {
        if let override = ProcessInfo.processInfo.environment["CONSTELLATION_LIBRARY_PATH"], !override.isEmpty {
            return override
        }
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return support.appendingPathComponent("Constellation/library.sqlite").path
    }

    /// The Trust Store's own database, beside the library.
    /// `CONSTELLATION_TRUST_STORE_PATH` overrides it for development runs.
    static func trustStorePath() -> String {
        if let override = ProcessInfo.processInfo.environment["CONSTELLATION_TRUST_STORE_PATH"], !override.isEmpty {
            return override
        }
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return support.appendingPathComponent("Constellation/trust.sqlite").path
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
