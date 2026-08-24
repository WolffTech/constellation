import AppKit
import ConstellationRemoteDesktop
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
/// Serialized: every test opens a real RDP session to the same single-session
/// host, and one test forces OpenSSL env vars process-wide, so they cannot run
/// in parallel.
@Suite(.serialized)
@MainActor
struct RDPProofTests {
    private nonisolated static var credentials: (host: String, password: String)? {
        let env = ProcessInfo.processInfo.environment
        guard let host = env["CONSTELLATION_TEST_RDP_HOST"], !host.isEmpty,
              let password = env["CONSTELLATION_TEST_RDP_PASSWORD"], !password.isEmpty
        else { return nil }
        return (host, password)
    }

    /// Proof fact 6: resizing the view makes the desktop follow over the
    /// Display Control channel. Drives the real path (view size -> request).
    private nonisolated static var dynamicResolutionEnabled: Bool {
        credentials != nil && ProcessInfo.processInfo.environment["CONSTELLATION_TEST_RDP_DYNRES"] == "1"
    }

    // Opt-in (CONSTELLATION_TEST_RDP_DYNRES=1) and needs a *fresh* server
    // session: Windows resumes a disconnected session at its existing size on a
    // quick reconnect, so repeated back-to-back runs against one single-session
    // host won't re-apply the layout. Verified interactively in the app.
    @Test(.enabled(if: dynamicResolutionEnabled, "set CONSTELLATION_TEST_RDP_DYNRES=1 (fresh session) to run"))
    func followsTheViewSizeWithDynamicResolution() async throws {
        let env = ProcessInfo.processInfo.environment
        let creds = try #require(Self.credentials)
        let configuration = RDPSessionConfiguration(
            host: creds.host,
            port: Int(env["CONSTELLATION_TEST_RDP_PORT"] ?? "") ?? 3389,
            username: env["CONSTELLATION_TEST_RDP_USERNAME"],
            domain: env["CONSTELLATION_TEST_RDP_DOMAIN"],
            width: 1280,
            height: 800,
            dynamicResolution: true)
        let session = RDPSession(configuration: configuration, password: { creds.password }, verifyCertificate: { _ in .acceptOnce })
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1280, height: 800), styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        window.contentView = session.view
        window.layoutIfNeeded()

        let latest = SizeBox()
        session.eventHandler = { event in
            if case .framebufferSizeChanged(let width, let height) = event {
                latest.set(CGSize(width: width, height: height))
            }
        }
        session.connect()
        var first: CGSize?
        for _ in 0..<300 where first == nil { first = latest.value; try? await Task.sleep(for: .milliseconds(100)) }
        #expect(first != nil, "expected an initial framebuffer")

        // Shrink the view; the host reports the new fit size and the desktop
        // follows. Re-request periodically: against a single-session host that
        // just handled another test's session, the server can take a moment to
        // accept the layout, and a real drag sends many requests too.
        window.setContentSize(NSSize(width: 1024, height: 704))
        session.view.layoutSubtreeIfNeeded()
        let target = CGSize(width: 1024, height: 704)
        var resized = false
        for i in 0..<40 where !resized {
            if i % 6 == 0 { session.requestResolution(width: 1024, height: 704) }
            if latest.value == target { resized = true; break }
            try? await Task.sleep(for: .milliseconds(500))
        }
        #expect(resized, "desktop did not follow the view size")

        session.disconnect()
        try await Task.sleep(for: .seconds(1))
        #expect(!session.state.isLive)
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

        let events = AsyncStream<RemoteDesktopSessionEvent>.makeStream()
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

    /// Regression for the hardened-runtime NLA failure: NTLM must not depend on
    /// OpenSSL's legacy provider (a dylib a signed app cannot dlopen). With the
    /// provider forced unavailable, WinPR's internal MD4/RC4 must still let NLA
    /// complete and a frame arrive. See `Scripts/build-freerdp.sh`
    /// (WITH_INTERNAL_MD4/MD5/RC4=ON) and ADR 0005.
    @Test(.enabled(if: credentials != nil, "set CONSTELLATION_TEST_RDP_HOST and _PASSWORD to run"))
    func connectsWithoutTheOpenSSLLegacyProvider() async throws {
        setenv("OPENSSL_MODULES", "/nonexistent-constellation", 1)
        setenv("OPENSSL_CONF", "/nonexistent-constellation.cnf", 1)
        defer { unsetenv("OPENSSL_MODULES"); unsetenv("OPENSSL_CONF") }
        let env = ProcessInfo.processInfo.environment
        let creds = try #require(Self.credentials)
        let configuration = RDPSessionConfiguration(
            host: creds.host,
            port: Int(env["CONSTELLATION_TEST_RDP_PORT"] ?? "") ?? 3389,
            username: env["CONSTELLATION_TEST_RDP_USERNAME"],
            domain: env["CONSTELLATION_TEST_RDP_DOMAIN"])
        let session = RDPSession(configuration: configuration, password: { creds.password }, verifyCertificate: { _ in .acceptOnce })
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1280, height: 800), styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = session.view
        let events = AsyncStream<RemoteDesktopSessionEvent>.makeStream()
        session.eventHandler = { events.continuation.yield($0) }
        session.connect()
        let frame = await withTimeout(seconds: 30) {
            for await event in events.stream {
                if case .framebufferSizeChanged(let w, let h) = event { return (w, h) }
                if case .stateChanged(.disconnected(let f)) = event {
                    Issue.record("NLA failed without the legacy provider: \(String(describing: f))")
                    return nil
                }
            }
            return nil
        }
        let size = try #require(frame, "expected a framebuffer without the legacy provider")
        #expect(size.0 > 0 && size.1 > 0)
        session.disconnect()
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

/// Thread-safe latest-value holder for the resolution proof's event handler.
private final class SizeBox: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: CGSize?
    var value: CGSize? { lock.lock(); defer { lock.unlock() }; return stored }
    func set(_ size: CGSize) { lock.lock(); stored = size; lock.unlock() }
}
