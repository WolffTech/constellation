import SwiftUI

@main
struct ConstellationApp: App {
    @State private var root = CompositionRoot()

    var body: some Scene {
        WindowGroup {
            SessionView(root: root)
        }
        .defaultSize(width: 960, height: 640)
        .commands {
            CommandGroup(replacing: .newItem) {}
        }
    }
}
