import SwiftUI

@main
struct ConstellationApp: App {
    @State private var root = CompositionRoot()

    var body: some Scene {
        WindowGroup {
            ContentView(root: root)
        }
        .defaultSize(width: 1100, height: 700)
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("New Machine") { root.ui.editor = .new }
                    .keyboardShortcut("n")
            }
            CommandGroup(after: .importExport) {
                Button("Import Machines…") { Task { await ImportExportPanels.importMachines(into: root.store) } }
                Button("Export Machines…") { ImportExportPanels.exportMachines(from: root.store) }
            }
        }
    }
}
