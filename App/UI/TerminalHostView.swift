import AppKit
import SwiftUI

/// Places a terminal's NSView in SwiftUI and gives it keyboard focus.
struct TerminalHostView: NSViewRepresentable {
    let view: NSView

    func makeNSView(context: Context) -> NSView {
        DispatchQueue.main.async {
            view.window?.makeFirstResponder(view)
        }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {}
}
