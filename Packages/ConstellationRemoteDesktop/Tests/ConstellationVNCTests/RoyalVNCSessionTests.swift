// SPDX-FileCopyrightText: 2026 Nick Wolff <nick@wolff.tech>
// SPDX-License-Identifier: GPL-3.0-only

import AppKit
import ConstellationRemoteDesktop
import RoyalVNCKit
import Testing
@testable import ConstellationVNC

@MainActor
struct RoyalVNCSessionTests {
    @Test func cleanClosesAndCancellationsAreNotFailures() {
        #expect(RoyalVNCSession.failure(from: nil) == nil)
        #expect(RoyalVNCSession.failure(from: VNCError.connection(.cancelled)) == nil)
        #expect(RoyalVNCSession.failure(from: VNCError.connection(.closed)) == nil)
    }

    @Test func authenticationErrorsAreFlagged() throws {
        let failure = try #require(RoyalVNCSession.failure(from: VNCError.authentication(.ardAuthenticationFailed)))
        #expect(failure.isAuthenticationFailure)
        #expect(failure.message.contains("Authentication failed"))

        let refused = try #require(RoyalVNCSession.failure(from: VNCError.connection(.failed(nil))))
        #expect(!refused.isAuthenticationFailure)
    }

    @Test func configurationMapsOntoRoyalVNCKitSettings() {
        let configuration = VNCSessionConfiguration(
            host: "vnc.box", port: 5901, sharesClipboard: true,
            colorDepth: .bits16, sharesSession: false, keyboardMode: .forwardAllShortcuts)
        let settings = RoyalVNCSession.connectionSettings(for: configuration)

        #expect(settings.hostname == "vnc.box")
        #expect(settings.port == 5901)
        #expect(settings.isClipboardRedirectionEnabled)
        #expect(settings.colorDepth == .depth16Bit)
        #expect(!settings.isShared)
        #expect(settings.inputMode == .forwardKeyboardShortcutsEvenIfInUseLocally)

        let defaults = RoyalVNCSession.connectionSettings(for: VNCSessionConfiguration(host: "vnc.box"))
        #expect(defaults.colorDepth == .depth24Bit)
        #expect(defaults.isShared)
        #expect(defaults.inputMode == .forwardKeyboardShortcutsIfNotInUseLocally)
        #expect(RoyalVNCSession.connectionSettings(for: VNCSessionConfiguration(host: "h", keyboardMode: .local)).inputMode == .none)
    }

    @Test func connectingToAClosedPortEndsDisconnectedWithAFailure() async throws {
        let session = RoyalVNCSession(configuration: VNCSessionConfiguration(host: "127.0.0.1", port: 1)) { _ in nil }
        var states: [RemoteDesktopSessionState] = []
        let finished = AsyncStream<Void>.makeStream()
        session.eventHandler = { event in
            if case .stateChanged(let state) = event {
                states.append(state)
                if case .disconnected = state { finished.continuation.finish() }
            }
        }
        session.connect()
        #expect(session.state == .connecting)
        for await _ in finished.stream {}
        guard case .disconnected(let failure) = session.state else {
            Issue.record("expected disconnected, got \(session.state)")
            return
        }
        #expect(failure != nil)
        #expect(states.first == .connecting)
    }
}
