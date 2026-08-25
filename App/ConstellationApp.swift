import AppKit
import ConstellationRemoteDesktop
import SwiftUI

@main
struct ConstellationApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @State private var root = CompositionRoot()

    var body: some Scene {
        WindowGroup {
            ContentView(root: root)
                .onAppear { appDelegate.root = root }
        }
        .defaultSize(width: 1100, height: 700)
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("New Machine") { root.ui.editor = .new }
                    .keyboardShortcut("n")
            }
            // Replaces File › Close: AppKit dispatches ⌘W to the first enabled
            // menu item, so the window's own Close would otherwise win.
            CommandGroup(replacing: .saveItem) {
                Button("Close Session") {
                    if let id = root.sessions?.selectedSessionID { root.sessions?.requestClose(sessionID: id) }
                }
                .keyboardShortcut("w")
                .disabled(root.sessions?.selectedSessionID == nil)
                Button("Close Other Sessions") {
                    if let id = root.sessions?.selectedSessionID { root.sessions?.requestCloseOthers(keeping: id) }
                }
                .keyboardShortcut("w", modifiers: [.command, .option])
                .disabled((root.sessions?.sessions.count ?? 0) < 2)
                Button("Close Window") { NSApplication.shared.keyWindow?.performClose(nil) }
                    .keyboardShortcut("w", modifiers: [.command, .shift])
            }
            CommandGroup(after: .toolbar) {
                Button("Fit to Window") { root.setDisplayMode(.fit) }
                    .disabled(!root.selectedSessionIsRemoteDesktop)
                Button("Actual Size") { root.setDisplayMode(.actualSize) }
                    .disabled(!root.selectedSessionIsRemoteDesktop)
                Divider()
            }
            CommandGroup(after: .importExport) {
                Button("Import Machines…") { Task { await ImportExportPanels.importMachines(into: root.store) } }
                Button("Export Machines…") { ImportExportPanels.exportMachines(from: root.store) }
            }
            CommandMenu("Session") {
                Button("Quick Connect…") { root.ui.showsQuickConnect = true }
                    .keyboardShortcut("k")
                Button("Connect Default Profile") { root.openDefaultProfile() }
                    .keyboardShortcut("t")
                    .disabled(root.ui.selectedMachineID == nil)
                Divider()
                Button("Reconnect") { root.reconnectSelectedSession() }
                    .keyboardShortcut("r")
                    .disabled(root.sessions?.selectedSession?.state.hasLiveProcess != false)
                Button("Disconnect") {
                    if let id = root.sessions?.selectedSessionID { root.sessions?.disconnect(sessionID: id) }
                }
                .disabled(root.sessions?.selectedSession?.state.hasLiveProcess != true)
                Divider()
                ForEach(1...9, id: \.self) { number in
                    Button("Select Tab \(number)") { root.sessions?.select(number: number) }
                        .keyboardShortcut(KeyEquivalent(Character(String(number))), modifiers: .command)
                        .disabled(root.sessions?.sessions.indices.contains(number - 1) != true)
                }
                Button("Next Tab") { root.sessions?.cycleSelection() }
                    .keyboardShortcut(.tab, modifiers: .control)
                Button("Previous Tab") { root.sessions?.cycleSelection(reverse: true) }
                    .keyboardShortcut(.tab, modifiers: [.control, .shift])
                Divider()
                Button("Find in Session") { root.sessions?.performSearch() }
                    .keyboardShortcut("f")
                    .disabled(root.sessions?.selectedSessionID == nil)
            }
            CommandGroup(after: .help) {
                AcknowledgementsCommand()
                Button("Save Support Bundle…") { SupportBundlePanel.save(root: root) }
            }
        }

        Window("Acknowledgements", id: "acknowledgements") {
            AcknowledgementsView()
        }
        .defaultSize(width: 760, height: 520)

        Settings {
            TerminalSettingsView(settings: root.terminalSettings)
        }
    }
}

/// Menu content gets the environment, so this is where `openWindow` lives.
private struct AcknowledgementsCommand: View {
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Button("Acknowledgements") { openWindow(id: "acknowledgements") }
    }
}

/// Routes every quit path (menu, Dock, logout) through the session confirmation.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    var root: CompositionRoot?

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        root?.prepareForTermination() ?? .terminateNow
    }
}
