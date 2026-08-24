import AppKit
import CConstellationRDP
import Testing
@testable import ConstellationRDP

@MainActor
struct RDPSessionTests {
    @Test func mapsFailureCodesToKinds() {
        #expect(RDPSession.failure(from: CRDP_FAILURE_NONE) == nil)
        #expect(RDPSession.failure(from: CRDP_FAILURE_CANCELLED) == nil)
        #expect(RDPSession.failure(from: CRDP_FAILURE_AUTHENTICATION)?.kind == .authentication)
        #expect(RDPSession.failure(from: CRDP_FAILURE_AUTHENTICATION)?.isAuthenticationFailure == true)
        #expect(RDPSession.failure(from: CRDP_FAILURE_DNS)?.kind == .dns)
        #expect(RDPSession.failure(from: CRDP_FAILURE_TLS)?.kind == .tls)
        #expect(RDPSession.failure(from: CRDP_FAILURE_CONNECT)?.kind == .connect)
        #expect(RDPSession.failure(from: CRDP_FAILURE_GENERIC)?.kind == .generic)
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

        let stream = AsyncStream<RDPSessionState>.makeStream()
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
        // `.connect` proves the client thread got as far as the TCP connect; a
        // pre-connect failure (e.g. a missing channel) maps to `.generic`.
        #expect(failure?.kind == .connect, "a refused connection should fail at connect, got \(String(describing: failure))")
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
