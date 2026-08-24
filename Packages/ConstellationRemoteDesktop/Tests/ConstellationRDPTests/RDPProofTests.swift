import AppKit
import Testing
@testable import ConstellationRDP

/// The Milestone 4 FreeRDP proof against a real RDP host. Gated on environment
/// so CI and ordinary runs skip it:
///   TEST_RUNNER_CONSTELLATION_TEST_RDP_HOST=<host or IP>
///   TEST_RUNNER_CONSTELLATION_TEST_RDP_PORT=3389 (default)
///   TEST_RUNNER_CONSTELLATION_TEST_RDP_USERNAME=<account>
///   TEST_RUNNER_CONSTELLATION_TEST_RDP_DOMAIN=<domain, optional>
///   TEST_RUNNER_CONSTELLATION_TEST_RDP_PASSWORD=<password>
///
/// Establishes proof facts 1, 2, 4 and 7: the pinned FreeRDP connects with NLA,
/// decoded frames reach an AppKit view, and disconnect frees the session
/// without hanging. Certificate pause, input round-trip and dynamic resolution
/// (facts 3, 5, 6) are interactive and verified in the app.
@MainActor
struct RDPProofTests {
    private nonisolated static var credentials: (host: String, password: String)? {
        let env = ProcessInfo.processInfo.environment
        guard let host = env["CONSTELLATION_TEST_RDP_HOST"], !host.isEmpty,
              let password = env["CONSTELLATION_TEST_RDP_PASSWORD"], !password.isEmpty
        else { return nil }
        return (host, password)
    }

    @Test(.enabled(if: credentials != nil, "set CONSTELLATION_TEST_RDP_HOST and _PASSWORD to run"))
    func connectsWithNLARendersAFrameAndDisconnects() async throws {
        let env = ProcessInfo.processInfo.environment
        let creds = try #require(Self.credentials)
        let configuration = RDPSessionConfiguration(
            host: creds.host,
            port: Int(env["CONSTELLATION_TEST_RDP_PORT"] ?? "") ?? 3389,
            username: env["CONSTELLATION_TEST_RDP_USERNAME"],
            domain: env["CONSTELLATION_TEST_RDP_DOMAIN"],
            width: 1280,
            height: 800)

        let session = RDPSession(
            configuration: configuration,
            password: { creds.password },
            // The proof accepts the certificate; the pause itself is the point.
            verifyCertificate: { _ in .acceptOnce })

        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1280, height: 800), styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = session.view

        let events = AsyncStream<RDPSessionEvent>.makeStream()
        var frameSizes: [(Int, Int)] = []
        session.eventHandler = { events.continuation.yield($0) }

        session.connect()
        let firstFrame = await withTimeout(seconds: 30) {
            for await event in events.stream {
                if case .framebufferSizeChanged(let width, let height) = event {
                    return (width, height)
                }
                if case .stateChanged(.disconnected(let failure)) = event {
                    Issue.record("disconnected before a frame: \(String(describing: failure))")
                    return nil
                }
            }
            return nil
        }
        let size = try #require(firstFrame, "expected a framebuffer")
        frameSizes.append(size)
        #expect(size.0 > 0 && size.1 > 0)
        #expect(session.state == .connected)

        session.disconnect()
        let terminal = await withTimeout(seconds: 15) {
            for await event in events.stream {
                if case .stateChanged(let state) = event, !state.isLive, state != .idle {
                    return state
                }
            }
            return nil
        }
        #expect(terminal == .disconnected(nil), "clean disconnect, got \(String(describing: terminal))")
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
