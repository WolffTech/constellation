// SPDX-FileCopyrightText: 2026 Nick Wolff <nick@wolff.tech>
// SPDX-License-Identifier: GPL-3.0-only

import GhosttyKit

/// Policy and data handling behind the libghostty clipboard callbacks. Kept
/// free of surface state so tests can exercise it directly.
enum TerminalClipboard {
    /// The only representation Constellation serves or accepts. libghostty
    /// normalizes text-like MIME aliases to this before calling back.
    static let textMIME = "text/plain"

    /// Only pastes the user initiated may be confirmed. Terminal-initiated
    /// reads (OSC 52, Kitty clipboard protocol) and paste-event listings are
    /// denied without a prompt.
    static func mayPrompt(_ request: ghostty_clipboard_request_e) -> Bool {
        request == GHOSTTY_CLIPBOARD_REQUEST_PASTE
    }

    /// Whether a read asks for the text representation.
    static func requestsText(_ mimes: UnsafePointer<UnsafePointer<CChar>?>?, count: Int) -> Bool {
        guard let mimes else { return false }
        return UnsafeBufferPointer(start: mimes, count: count).contains { mime in
            mime.map { String(cString: $0) == textMIME } ?? false
        }
    }

    /// The text representation, if present. Payloads carry an explicit byte
    /// length and are not null-terminated.
    static func text(in contents: UnsafePointer<ghostty_clipboard_content_s>?, count: Int) -> String? {
        guard let contents else { return nil }
        for item in UnsafeBufferPointer(start: contents, count: count) {
            guard let mime = item.mime, String(cString: mime) == textMIME, let data = item.data else { continue }
            return String(decoding: UnsafeRawBufferPointer(start: data, count: item.len), as: UTF8.self)
        }
        return nil
    }

    /// Completes a read with at most the text representation. libghostty
    /// copies what it needs, so the C memory lives only for the call.
    static func complete(
        _ surface: ghostty_surface_t,
        text: String?,
        listsText: Bool,
        state: UnsafeMutableRawPointer?,
        confirmed: Bool
    ) {
        textMIME.withCString { mime in
            (text ?? "").withCString { data in
                var contents: [ghostty_clipboard_content_s] = []
                if let text {
                    contents.append(ghostty_clipboard_content_s(mime: mime, data: data, len: text.utf8.count))
                }
                let available: [UnsafePointer<CChar>?] = listsText ? [mime] : []
                contents.withUnsafeBufferPointer { contents in
                    available.withUnsafeBufferPointer { available in
                        var complete = ghostty_clipboard_complete_s(
                            contents: contents.baseAddress,
                            contents_len: contents.count,
                            available: available.baseAddress,
                            available_len: available.count,
                            confirmed: confirmed,
                            remember: false)
                        ghostty_surface_complete_clipboard_request(surface, &complete, state)
                    }
                }
            }
        }
    }
}
