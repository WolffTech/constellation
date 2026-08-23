import ConstellationTerminal
import SwiftUI

struct SessionView: View {
    let root: CompositionRoot

    var body: some View {
        Group {
            if let session = root.session {
                TerminalPane(session: session)
            } else {
                ContentUnavailableView(
                    "Terminal unavailable",
                    systemImage: "exclamationmark.triangle",
                    description: Text(root.startupError ?? "Unknown error"))
            }
        }
    }
}

private struct TerminalPane: View {
    let session: GhosttyTerminalSession

    var body: some View {
        TerminalHostView(view: session.view)
            .overlay(alignment: .top) {
                if case .exited(let code) = session.processState {
                    Text("Process exited with code \(code)")
                        .font(.callout)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 6)
                        .background(.regularMaterial, in: Capsule())
                        .padding(.top, 8)
                }
            }
            .navigationTitle(session.title.isEmpty ? "Constellation" : session.title)
    }
}
