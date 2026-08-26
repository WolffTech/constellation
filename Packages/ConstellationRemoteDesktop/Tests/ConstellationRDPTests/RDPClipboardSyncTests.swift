// SPDX-FileCopyrightText: 2026 Nick Wolff <nick@wolff.tech>
// SPDX-License-Identifier: GPL-3.0-only

import AppKit
import Testing
@testable import ConstellationRDP

@MainActor
struct RDPClipboardSyncTests {
    @Test func offersLocalCopiesOnce() {
        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }
        let sync = RDPClipboardSync(pasteboard: pasteboard)
        #expect(sync.pollLocalChange() == nil)

        pasteboard.clearContents()
        pasteboard.setString("hello", forType: .string)
        #expect(sync.pollLocalChange() == "hello")
        #expect(sync.pollLocalChange() == nil, "an unchanged pasteboard is not offered again")
    }

    @Test func remoteTextIsNotEchoedBack() {
        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }
        let sync = RDPClipboardSync(pasteboard: pasteboard)
        sync.receive(remoteText: "from windows")
        #expect(pasteboard.string(forType: .string) == "from windows")
        #expect(sync.pollLocalChange() == nil)
    }

    @Test func currentTextMarksTheContentsSeen() {
        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }
        pasteboard.clearContents()
        pasteboard.setString("already copied", forType: .string)
        let sync = RDPClipboardSync(pasteboard: pasteboard)
        #expect(sync.currentText() == "already copied")
        #expect(sync.pollLocalChange() == nil)
    }
}
