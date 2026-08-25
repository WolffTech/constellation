import AppKit
import ConstellationTerminal
import SwiftUI

struct TerminalPane: View {
    let session: any TerminalSession
    let state: SessionState
    @Binding var isSearchPresented: Bool
    let onReconnect: () -> Void
    @State private var query = ""
    @FocusState private var searchFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            if isSearchPresented {
                HStack(spacing: 8) {
                    Image(systemName: "magnifyingglass")
                        .foregroundStyle(.secondary)
                        .accessibilityHidden(true)
                    TextField("Find", text: $query)
                        .textFieldStyle(.roundedBorder)
                        .focused($searchFocused)
                        .onSubmit { navigate("next") }
                        .onExitCommand { isSearchPresented = false }
                        .onChange(of: query) { _, value in
                            _ = session.performBinding("search:\(value)")
                        }
                    Button { navigate("previous") } label: { Image(systemName: "chevron.up") }
                        .buttonStyle(.borderless)
                        .help("Previous Match")
                        .accessibilityLabel("Previous Match")
                    Button { navigate("next") } label: { Image(systemName: "chevron.down") }
                        .buttonStyle(.borderless)
                        .help("Next Match")
                        .accessibilityLabel("Next Match")
                    Button { isSearchPresented = false } label: { Image(systemName: "xmark") }
                        .buttonStyle(.borderless)
                        .help("Close Find (Escape)")
                        .accessibilityLabel("Close Find")
                }
                .padding(8)
                .background(.bar)
                Divider()
            }
            TerminalHostView(view: session.view)
                .overlay(alignment: .top) {
                    if !state.hasLiveProcess {
                        HStack(spacing: 10) {
                            Text(statusText)
                                .font(.callout)
                            Button("Reconnect", action: onReconnect)
                                .controlSize(.small)
                                .keyboardShortcut(.defaultAction)
                        }
                        .padding(.horizontal, 12)
                        .padding(.vertical, 6)
                        .background(.regularMaterial, in: Capsule())
                        .padding(.top, 8)
                        .accessibilityElement(children: .combine)
                        .accessibilityAddTraits(.updatesFrequently)
                    }
                }
        }
        .onChange(of: isSearchPresented) { _, presented in
            if presented {
                searchFocused = true
            } else {
                query = ""
                focusTerminal()
            }
        }
        .onAppear {
            if isSearchPresented { searchFocused = true }
        }
    }

    private var statusText: String {
        if case .failed(let failure) = state { return failure.localizedDescription }
        return "Session disconnected"
    }

    private func navigate(_ direction: String) {
        _ = session.performBinding("navigate_search:\(direction)")
    }

    /// Hands keyboard focus back to the terminal when the find bar goes away.
    private func focusTerminal() {
        let view = session.view
        DispatchQueue.main.async {
            view.window?.makeFirstResponder(view)
        }
    }
}
