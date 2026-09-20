// SPDX-FileCopyrightText: 2026 Nick Wolff <nick@wolff.tech>
// SPDX-License-Identifier: GPL-3.0-only

import AppKit
import ConstellationRDP
import WebKit

/// Shows Microsoft's Entra ID sign-in page in a window and returns the
/// authorization code from its redirect. The page uses the shared website data
/// store, so an account that is still signed in passes straight through on the
/// next connection. Closing the window, or cancelling the calling task, gives
/// up and returns `nil`.
@MainActor
enum RDPEntraSignInPrompter {
    static func ask(_ request: RDPEntraSignInRequest, machineName: String) async -> String? {
        let controller = SignInWindowController(request: request, machineName: machineName)
        return await withTaskCancellationHandler {
            await withCheckedContinuation { controller.start($0) }
        } onCancel: {
            Task { @MainActor in controller.finish(nil) }
        }
    }
}

@MainActor
private final class SignInWindowController: NSObject, NSWindowDelegate, WKNavigationDelegate {
    private let request: RDPEntraSignInRequest
    private let window: NSWindow
    private let webView = WKWebView(frame: NSRect(x: 0, y: 0, width: 520, height: 680))
    private var continuation: CheckedContinuation<String?, Never>?
    /// Keeps the controller alive while its window is open.
    private var retainedSelf: SignInWindowController?

    init(request: RDPEntraSignInRequest, machineName: String) {
        self.request = request
        window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 520, height: 680),
            styleMask: [.titled, .closable, .resizable],
            backing: .buffered,
            defer: false)
        super.init()
        window.title = "Sign in to \(machineName)"
        window.contentView = webView
        window.isReleasedWhenClosed = false
        window.delegate = self
        webView.navigationDelegate = self
    }

    func start(_ continuation: CheckedContinuation<String?, Never>) {
        // Cancelled before the window opened.
        if Task.isCancelled {
            continuation.resume(returning: nil)
            return
        }
        self.continuation = continuation
        retainedSelf = self
        webView.load(URLRequest(url: request.authorizeURL))
        window.center()
        window.makeKeyAndOrderFront(nil)
    }

    func finish(_ code: String?) {
        guard let continuation else { return }
        self.continuation = nil
        continuation.resume(returning: code)
        window.delegate = nil
        window.close()
        retainedSelf = nil
    }

    func windowWillClose(_ notification: Notification) {
        finish(nil)
    }

    // The redirect address serves nothing, and for a desktop sign-in is not
    // even a scheme WebKit can load, so the code is read off the navigation.
    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction) async -> WKNavigationActionPolicy {
        guard let url = navigationAction.request.url, request.isRedirect(url) else { return .allow }
        finish(request.authorizationCode(from: url))
        return .cancel
    }
}
