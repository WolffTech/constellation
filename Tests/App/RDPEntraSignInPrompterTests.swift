// SPDX-FileCopyrightText: 2026 Nick Wolff <nick@wolff.tech>
// SPDX-License-Identifier: GPL-3.0-only

import AppKit
import ConstellationRDP
import Foundation
import Testing
@testable import Constellation

/// Drives the real sign-in window with a local page standing in for Microsoft's.
@MainActor
struct RDPEntraSignInPrompterTests {
    /// Signs in against a local page with this body, then deletes the page.
    private func signIn(pageBody: String, cancelAfter delay: Duration? = nil) async throws -> String? {
        let page = FileManager.default.temporaryDirectory.appendingPathComponent("constellation-sign-in-\(UUID().uuidString).html")
        try pageBody.write(to: page, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: page) }
        let authorizeURL = page.absoluteString + "?redirect_uri=ms-appx-web%3A%2F%2FMicrosoft.AAD.BrokerPlugin%2Fvm1"
        let request = try #require(RDPEntraSignInRequest(authorizeURL: authorizeURL))

        let task = Task { await RDPEntraSignInPrompter.ask(request, machineName: "Cloud PC") }
        if let delay {
            try await Task.sleep(for: delay)
            #expect(isSignInWindowOpen)
            task.cancel()
        }
        return await task.value
    }

    private var isSignInWindowOpen: Bool {
        NSApp.windows.contains { $0.title == "Sign in to Cloud PC" && $0.isVisible }
    }

    /// Goes straight to `redirect`, the way Entra ID does once the user has signed in.
    private func page(redirectingTo redirect: String) -> String {
        "<script>location.href = '\(redirect)'</script>"
    }

    @Test func returnsTheCodeFromTheRedirectAndClosesTheWindow() async throws {
        let code = try await signIn(pageBody: page(redirectingTo: "ms-appx-web://Microsoft.AAD.BrokerPlugin/vm1?code=abc123"))
        #expect(code == "abc123")
        #expect(!isSignInWindowOpen)
    }

    @Test func anErrorRedirectGivesUp() async throws {
        let code = try await signIn(pageBody: page(redirectingTo: "ms-appx-web://Microsoft.AAD.BrokerPlugin/vm1?error=access_denied"))
        #expect(code == nil)
        #expect(!isSignInWindowOpen)
    }

    @Test func cancellingTheTaskClosesTheWindow() async throws {
        // This page never redirects, like a sign-in the user has walked away from.
        let code = try await signIn(pageBody: "<p>waiting</p>", cancelAfter: .milliseconds(200))
        #expect(code == nil)
        #expect(!isSignInWindowOpen)
    }
}
