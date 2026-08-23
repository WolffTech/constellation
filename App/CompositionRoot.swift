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
    private(set) var sessions: SessionHub?
    private(set) var startupError: String?
    let ui = UIState()

    private var runtime: GhosttyRuntime?
    private var askPass: AskPassService?

    init() {
        do {
            let vault = KeychainCredentialVault()
            let library = try GRDBMachineLibrary(path: Self.libraryPath())
            let store = MachineStore(library: library, vault: vault)
            self.store = store

            let runtime = try GhosttyRuntime(appearance: .default)
            self.runtime = runtime
            let askPass = try AskPassService(secrets: VaultSecretProvider(vault: vault)) { request in
                AskPassPrompter.ask(request)
            }
            self.askPass = askPass
            sessions = SessionHub(runtime: runtime, askPass: askPass)
        } catch {
            startupError = error.localizedDescription
        }
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
