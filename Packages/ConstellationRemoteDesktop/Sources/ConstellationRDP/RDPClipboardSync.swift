import AppKit

/// Mirrors text between the local pasteboard and the remote clipboard without
/// echo: text the remote side put on the pasteboard is remembered by change
/// count so the next poll does not offer it straight back to the server.
@MainActor
final class RDPClipboardSync {
    private let pasteboard: NSPasteboard
    private var lastSeenChangeCount: Int

    init(pasteboard: NSPasteboard = .general) {
        self.pasteboard = pasteboard
        lastSeenChangeCount = pasteboard.changeCount
    }

    /// The pasteboard's current text, marking it seen. Used on connect so the
    /// remote side starts with what the user already copied.
    func currentText() -> String? {
        lastSeenChangeCount = pasteboard.changeCount
        return pasteboard.string(forType: .string)
    }

    /// Text copied locally since the last poll, or `nil` when nothing changed
    /// or the new contents are not text.
    func pollLocalChange() -> String? {
        guard pasteboard.changeCount != lastSeenChangeCount else { return nil }
        return currentText()
    }

    /// Puts remote text on the local pasteboard.
    func receive(remoteText: String) {
        pasteboard.clearContents()
        pasteboard.setString(remoteText, forType: .string)
        lastSeenChangeCount = pasteboard.changeCount
    }
}
