import AppKit
import Foundation
import UniformTypeIdentifiers

/// File panels for secret-free machine export and import.
@MainActor
enum ImportExportPanels {
    static func exportMachines(from store: MachineStore?) {
        guard let store else { return }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.json]
        panel.nameFieldStringValue = "Constellation Machines.json"
        panel.message = "Machines, addresses and profiles are exported. Passwords and Keychain references are not."
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try store.exportData().write(to: url, options: .atomic)
        } catch {
            store.presentedError = error.localizedDescription
        }
    }

    static func importMachines(into store: MachineStore?) async {
        guard let store else { return }
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.json]
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.message = "Choose a Constellation machines export"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            await store.importData(try Data(contentsOf: url))
        } catch {
            store.presentedError = error.localizedDescription
        }
    }
}
