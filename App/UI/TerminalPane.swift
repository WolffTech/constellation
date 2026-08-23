import ConstellationTerminal
import SwiftUI

struct TerminalPane: View {
    let session: GhosttyTerminalSession

    var body: some View {
        TerminalHostView(view: session.view)
            .overlay(alignment: .top) {
                if case .exited(let code) = session.processState {
                    Text("Session ended (exit code \(code))")
                        .font(.callout)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 6)
                        .background(.regularMaterial, in: Capsule())
                        .padding(.top, 8)
                }
            }
    }
}
