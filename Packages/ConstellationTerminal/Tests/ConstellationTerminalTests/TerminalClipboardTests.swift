// SPDX-FileCopyrightText: 2026 Nick Wolff <nick@wolff.tech>
// SPDX-License-Identifier: GPL-3.0-only

import Foundation
import GhosttyKit
import Testing
@testable import ConstellationTerminal

struct TerminalClipboardTests {
    /// Runs `body` with a C clipboard payload built from `(mime, bytes)` pairs.
    private func withContents<T>(
        _ items: [(mime: String, bytes: [UInt8])],
        _ body: (UnsafePointer<ghostty_clipboard_content_s>, Int) -> T
    ) -> T {
        let mimes = items.map { strdup($0.mime)! }
        let datas = items.map { item -> UnsafeMutablePointer<CChar> in
            let buffer = UnsafeMutablePointer<CChar>.allocate(capacity: max(item.bytes.count, 1))
            for (index, byte) in item.bytes.enumerated() { buffer[index] = CChar(bitPattern: byte) }
            return buffer
        }
        defer {
            mimes.forEach { free($0) }
            datas.forEach { $0.deallocate() }
        }
        let contents = items.indices.map { index in
            ghostty_clipboard_content_s(mime: mimes[index], data: datas[index], len: items[index].bytes.count)
        }
        return contents.withUnsafeBufferPointer { body($0.baseAddress!, $0.count) }
    }

    @Test func onlyUserInitiatedPastesMayPrompt() {
        #expect(TerminalClipboard.mayPrompt(GHOSTTY_CLIPBOARD_REQUEST_PASTE))
        for request in [
            GHOSTTY_CLIPBOARD_REQUEST_OSC_52_READ,
            GHOSTTY_CLIPBOARD_REQUEST_OSC_52_WRITE,
            GHOSTTY_CLIPBOARD_REQUEST_KITTY_READ,
            GHOSTTY_CLIPBOARD_REQUEST_KITTY_WRITE,
            GHOSTTY_CLIPBOARD_REQUEST_LIST,
        ] {
            #expect(!TerminalClipboard.mayPrompt(request), "\(request.rawValue) must be denied")
        }
    }

    @Test func textHonorsExplicitLengthInsteadOfNullTermination() {
        // No terminator inside the payload: only `len` bounds the read.
        withContents([(TerminalClipboard.textMIME, Array("hello world".utf8))]) { contents, _ in
            #expect(TerminalClipboard.text(in: contents, count: 1) == "hello world")
        }
        // A NUL inside the payload is data, not a terminator.
        withContents([(TerminalClipboard.textMIME, [0x61, 0x00, 0x62])]) { contents, _ in
            #expect(TerminalClipboard.text(in: contents, count: 1) == "a\u{0}b")
        }
        withContents([(TerminalClipboard.textMIME, [])]) { contents, _ in
            #expect(TerminalClipboard.text(in: contents, count: 1) == "")
        }
    }

    @Test func textIgnoresNonTextRepresentations() {
        withContents([("image/png", [0x89, 0x50]), (TerminalClipboard.textMIME, Array("copied".utf8))]) { contents, count in
            #expect(TerminalClipboard.text(in: contents, count: count) == "copied")
        }
        withContents([("image/png", [0x89, 0x50])]) { contents, count in
            #expect(TerminalClipboard.text(in: contents, count: count) == nil)
        }
        #expect(TerminalClipboard.text(in: nil, count: 0) == nil)
    }

    @Test func readsServeOnlyTextRequests() {
        var requested: [UnsafePointer<CChar>?] = []
        for mime in ["image/png", "text/plain"] {
            let copy: UnsafeMutablePointer<CChar> = strdup(mime)
            requested.append(UnsafePointer(copy))
        }
        defer { requested.forEach { free(UnsafeMutablePointer(mutating: $0)) } }
        requested.withUnsafeBufferPointer { mimes in
            #expect(TerminalClipboard.requestsText(mimes.baseAddress, count: 2))
            #expect(!TerminalClipboard.requestsText(mimes.baseAddress, count: 1))
            #expect(!TerminalClipboard.requestsText(mimes.baseAddress, count: 0))
        }
        #expect(!TerminalClipboard.requestsText(nil, count: 0))
    }
}
