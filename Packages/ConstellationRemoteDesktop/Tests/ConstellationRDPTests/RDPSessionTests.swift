// SPDX-FileCopyrightText: 2026 Nick Wolff <nick@wolff.tech>
// SPDX-License-Identifier: GPL-3.0-only

import AppKit
import CConstellationRDP
import ConstellationRemoteDesktop
import Testing
@testable import ConstellationRDP

@MainActor
struct RDPSessionTests {
    @Test func mapsFailureClasses() {
        #expect(RDPSession.failure(from: CRDP_FAILURE_NONE) == nil)
        #expect(RDPSession.failure(from: CRDP_FAILURE_CANCELLED) == nil)
        let auth = RDPSession.failure(from: CRDP_FAILURE_AUTHENTICATION)
        #expect(auth?.isAuthenticationFailure == true)
        #expect(RDPSession.failure(from: CRDP_FAILURE_DNS)?.message == RDPSession.dnsFailureMessage)
        #expect(RDPSession.failure(from: CRDP_FAILURE_TLS)?.message == RDPSession.tlsFailureMessage)
        #expect(RDPSession.failure(from: CRDP_FAILURE_CONNECT)?.message == RDPSession.connectFailureMessage)
        #expect(RDPSession.failure(from: CRDP_FAILURE_SIGN_IN)?.message == RDPSession.signInFailureMessage)
        #expect(RDPSession.failure(from: CRDP_FAILURE_GENERIC)?.isAuthenticationFailure == false)
    }

    @Test func translatesKnownMacKeycodes() {
        // Return key (macOS keyCode 36) has a non-zero, non-extended scancode.
        var extended = true
        let scancode = crdp_scancode_for_mac_keycode(36, &extended)
        #expect(scancode != 0)
        #expect(extended == false)
    }

    /// A closed port exercises the whole client-thread and callback path and
    /// proves disconnect tears the session down without hanging.
    @Test func connectingToAClosedPortReportsAFailure() async {
        let configuration = RDPSessionConfiguration(host: "127.0.0.1", port: 1, username: "tester", width: 640, height: 480)
        let session = RDPSession(
            configuration: configuration,
            password: { "unused" },
            verifyCertificate: { _ in .acceptOnce })

        let stream = AsyncStream<RemoteDesktopSessionState>.makeStream()
        session.eventHandler = { event in
            if case .stateChanged(let state) = event, !state.isLive, state != .idle {
                stream.continuation.yield(state)
            }
        }
        session.connect()

        let terminal = await withTimeout(seconds: 15) {
            for await state in stream.stream { return state }
            return nil
        }
        guard case .disconnected(let failure) = terminal else {
            Issue.record("expected a disconnected state, got \(String(describing: terminal))")
            return
        }
        // The connect message proves the client thread got as far as TCP; a
        // pre-connect failure (e.g. a missing channel) maps to the generic one.
        #expect(failure?.message == RDPSession.connectFailureMessage, "got \(String(describing: failure))")
    }

    /// Drives the Azure Virtual Desktop settings through FreeRDP's ARM
    /// transport. The gateway is reached before any token is asked for, so an
    /// unreachable one must fail without showing a sign-in page.
    @Test func anUnreachableAzureVirtualDesktopGatewayFailsBeforeSignIn() async {
        let resource = RDPAzureVirtualDesktopResource(
            endpointPool: "11112222-0815-1234-abcd-123456789abc",
            geo: "EU",
            armPath: "/subscriptions/s/resourcegroups/g/providers/Microsoft.DesktopVirtualization/hostpools/p",
            tenantID: "77064fd5-2634-4a0d-b310-2fa3c1d0472d",
            loadBalanceInfo: "mth://localhost/pool/resource",
            application: "||resource")
        let configuration = RDPSessionConfiguration(
            host: "rdgateway.invalid", username: "tester", width: 640, height: 480,
            gateway: RDPGatewayConfiguration(host: "127.0.0.1", port: 1, account: .azureVirtualDesktop(resource)))
        let signInShown = SignInFlag()
        let session = RDPSession(
            configuration: configuration,
            password: { "unused" },
            verifyCertificate: { _ in .acceptOnce },
            entraSignIn: { _ in
                signInShown.value = true
                return nil
            })

        let stream = AsyncStream<RemoteDesktopSessionState>.makeStream()
        session.eventHandler = { event in
            if case .stateChanged(let state) = event, !state.isLive, state != .idle {
                stream.continuation.yield(state)
            }
        }
        session.connect()

        let terminal = await withTimeout(seconds: 15) {
            for await state in stream.stream { return state }
            return nil
        }
        guard case .disconnected(let failure) = terminal else {
            Issue.record("expected a disconnected state, got \(String(describing: terminal))")
            return
        }
        #expect(failure != nil)
        #expect(!signInShown.value)
    }

    @Test func releasingWhileConnectingIgnoresQueuedCallbacks() async {
        let passwordRequested = AsyncStream<Void>.makeStream()
        let configuration = RDPSessionConfiguration(
            host: "127.0.0.1", port: 1, username: "tester", width: 640, height: 480)
        var session: RDPSession? = RDPSession(
            configuration: configuration,
            password: {
                passwordRequested.continuation.yield()
                return "unused"
            },
            verifyCertificate: { _ in .acceptOnce })
        weak let releasedSession = session

        session?.connect()
        for await _ in passwordRequested.stream { break }
        session = nil

        for _ in 0..<100 where releasedSession != nil {
            await Task.yield()
        }
        #expect(releasedSession == nil)
        // Drain the callbacks FreeRDP queued while its client thread stopped.
        for _ in 0..<10 { await Task.yield() }
    }

    private func withTimeout<T: Sendable>(seconds: Double, _ body: @escaping @MainActor @Sendable () async -> T?) async -> T? {
        await withTaskGroup(of: T?.self) { group in
            group.addTask { await body() }
            group.addTask {
                try? await Task.sleep(for: .seconds(seconds))
                return nil
            }
            let result = await group.next() ?? nil
            group.cancelAll()
            return result
        }
    }
}

@MainActor
private final class SignInFlag {
    var value = false
}
