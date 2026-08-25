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
        // The desktop is requested in pixels, so expect the point size scaled
        // by the display (2048x1408 on Retina).
        let scale = window.backingScaleFactor
        let target = CGSize(width: 1024 * scale, height: 704 * scale)
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

    /// Clipboard sharing loads the cliprdr channel and negotiates on connect;
    /// a missing addin or a bad capability exchange would fail the session
    /// before a frame arrives. Copy/paste itself needs a person on both ends.
    @Test(.enabled(if: credentials != nil, "set CONSTELLATION_TEST_RDP_HOST and _PASSWORD to run"))
    func connectsWithClipboardSharing() async throws {
        let env = ProcessInfo.processInfo.environment
        let creds = try #require(Self.credentials)
        let configuration = RDPSessionConfiguration(
            host: creds.host,
            port: Int(env["CONSTELLATION_TEST_RDP_PORT"] ?? "") ?? 3389,
            username: env["CONSTELLATION_TEST_RDP_USERNAME"],
            domain: env["CONSTELLATION_TEST_RDP_DOMAIN"],
            sharesClipboard: true)
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
                    Issue.record("disconnected before a frame with clipboard sharing: \(String(describing: f))")
                    return nil
                }
            }
            return nil
        }
        #expect(try #require(frame).0 > 0)
        // Give the channel's MonitorReady exchange a moment, then leave cleanly.
        try await Task.sleep(for: .seconds(2))
        #expect(session.state == .connected)
        session.disconnect()
        let terminal = await withTimeout(seconds: 15) {
            for await event in events.stream {
                if case .stateChanged(let state) = event, !state.isLive, state != .idle { return state }
            }
            return nil
        }
        #expect(terminal == .disconnected(nil))
    }

    private nonisolated static var profilingEnabled: Bool {
        credentials != nil && ProcessInfo.processInfo.environment["CONSTELLATION_TEST_RDP_PROFILE"] == "1"
    }

    /// Milestone 4 exit check: repeated connection cycles must not leak or
    /// hang. Each cycle connects, waits for a frame, idles, disconnects and
    /// frees the session (deinit joins FreeRDP's thread). Prints resident
    /// memory per cycle, teardown time and idle CPU; asserts the loose bounds
    /// that would flag a leak or a stuck thread. Opt in with
    /// CONSTELLATION_TEST_RDP_PROFILE=1; CONSTELLATION_TEST_RDP_CYCLES sets the
    /// count (default 5).
    @Test(.enabled(if: profilingEnabled, "set CONSTELLATION_TEST_RDP_PROFILE=1 to run"))
    func survivesRepeatedConnectionCycles() async throws {
        let env = ProcessInfo.processInfo.environment
        let creds = try #require(Self.credentials)
        let cycles = Int(env["CONSTELLATION_TEST_RDP_CYCLES"] ?? "") ?? 5
        let configuration = RDPSessionConfiguration(
            host: creds.host,
            port: Int(env["CONSTELLATION_TEST_RDP_PORT"] ?? "") ?? 3389,
            username: env["CONSTELLATION_TEST_RDP_USERNAME"],
            domain: env["CONSTELLATION_TEST_RDP_DOMAIN"],
            sharesClipboard: true)

        var residentAfterCycle: [Double] = []
        var teardownSeconds: [Double] = []
        var idleCPUPercent: [Double] = []
        let mainThread = mach_thread_self() // this test body runs on the main thread
        defer { mach_port_deallocate(mach_task_self_, mainThread) }
        for cycle in 1...cycles {
            var session: RDPSession? = RDPSession(configuration: configuration, password: { creds.password }, verifyCertificate: { _ in .acceptOnce })
            var window: NSWindow? = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1280, height: 800), styleMask: [.titled], backing: .buffered, defer: false)
            window?.contentView = session?.view
            let latest = SizeBox()
            let frames = Counter()
            session?.eventHandler = { event in
                if case .framebufferSizeChanged(let w, let h) = event { latest.set(CGSize(width: w, height: h)) }
                if case .framebufferSizeChanged = event { frames.increment() }
            }
            session?.connect()
            for _ in 0..<300 where latest.value == nil { try? await Task.sleep(for: .milliseconds(100)) }
            #expect(latest.value != nil, "cycle \(cycle): no frame")
            #expect(session?.state == .connected, "cycle \(cycle): not connected")

            // Idle load in 3 s buckets: right after the first frame the codec is
            // still refining the desktop, so only the tail is truly idle.
            var buckets: [Double] = []
            var frameRates: [String] = []
            for _ in 0..<4 {
                let cpuBefore = ProcessLoad.cpuSeconds()
                let wallBefore = Date()
                let statsBefore = session?.frameStatistics ?? (updates: 0, snapshots: 0)
                try await Task.sleep(for: .seconds(3))
                let elapsed = Date().timeIntervalSince(wallBefore)
                buckets.append((ProcessLoad.cpuSeconds() - cpuBefore) / elapsed * 100)
                let stats = session?.frameStatistics ?? (updates: 0, snapshots: 0)
                frameRates.append(String(format: "%.0f/%.0f", Double(stats.updates - statsBefore.updates) / elapsed, Double(stats.snapshots - statsBefore.snapshots) / elapsed))
            }
            let idle = buckets.last ?? .nan
            idleCPUPercent.append(idle)
            print("rdp profile cycle \(cycle): cpu% per 3 s bucket " + buckets.map { String(format: "%.1f", $0) }.joined(separator: " → ")
                + "; updates/snapshots per s " + frameRates.joined(separator: " → "))
            print("rdp profile cycle \(cycle): threads " + ProcessLoad.threadLoads(main: mainThread).map { "\($0.name) \(String(format: "%.1f", $0.percent))%" }.joined(separator: ", "))
            #expect(idle < 15, "cycle \(cycle): idle session costs \(idle)% CPU")

            session?.disconnect()
            for _ in 0..<150 where session?.state.isLive == true { try? await Task.sleep(for: .milliseconds(100)) }
            #expect(session?.state == .disconnected(nil), "cycle \(cycle): \(String(describing: session?.state))")

            // Releasing the last reference runs the isolated deinit inline,
            // which joins the client thread: that is the teardown cost.
            window?.contentView = nil
            window = nil
            weak var released = session
            let start = Date()
            session = nil
            let teardown = Date().timeIntervalSince(start)
            #expect(released == nil, "cycle \(cycle): session still retained after release")
            teardownSeconds.append(teardown)
            #expect(teardown < 5, "cycle \(cycle): teardown took \(teardown)s")

            let resident = ProcessLoad.residentMB()
            residentAfterCycle.append(resident)
            print(String(format: "rdp profile cycle %d: resident %.1f MB, teardown %.3f s, idle cpu %.1f%%, resizes %d", cycle, resident, teardown, idle, frames.value))
        }

        // The first cycles pay for codec tables and caches (observed: +14 MB,
        // +2 MB, +1 MB, then flat); steady growth over the second half of the
        // run points at a leak per session.
        if cycles >= 4, let last = residentAfterCycle.last {
            let half = cycles / 2
            let growthPerCycle = (last - residentAfterCycle[half]) / Double(cycles - 1 - half)
            print(String(format: "rdp profile: growth %.2f MB/cycle over the second half, max teardown %.3f s, mean idle cpu %.1f%%", growthPerCycle, teardownSeconds.max() ?? 0, idleCPUPercent.reduce(0, +) / Double(idleCPUPercent.count)))
            #expect(growthPerCycle < 2, "resident memory grows \(growthPerCycle) MB per cycle")
        }
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

private final class Counter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    var value: Int { lock.lock(); defer { lock.unlock() }; return count }
    func increment() { lock.lock(); count += 1; lock.unlock() }
}

/// Process-level load figures for the profiling proof.
private enum ProcessLoad {
    static func residentMB() -> Double {
        var info = mach_task_basic_info()
        var count = mach_msg_type_number_t(MemoryLayout<mach_task_basic_info>.size / MemoryLayout<natural_t>.size)
        let result = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(MACH_TASK_BASIC_INFO), $0, &count)
            }
        }
        guard result == KERN_SUCCESS else { return .nan }
        return Double(info.resident_size) / 1_048_576
    }

    /// Recent CPU share of every thread above 1%, by thread name, so the
    /// profiling proof can say who is busy (the client thread, the main
    /// thread's snapshots, or something else).
    static func threadLoads(main: thread_t) -> [(name: String, percent: Double)] {
        var threads: thread_act_array_t?
        var count: mach_msg_type_number_t = 0
        guard task_threads(mach_task_self_, &threads, &count) == KERN_SUCCESS, let threads else { return [] }
        defer {
            for index in 0..<Int(count) { mach_port_deallocate(mach_task_self_, threads[index]) }
            vm_deallocate(mach_task_self_, vm_address_t(bitPattern: threads), vm_size_t(count) * vm_size_t(MemoryLayout<thread_t>.stride))
        }
        var loads: [(name: String, percent: Double)] = []
        for index in 0..<Int(count) {
            let thread = threads[index]
            var info = thread_basic_info()
            var infoCount = mach_msg_type_number_t(MemoryLayout<thread_basic_info>.size / MemoryLayout<natural_t>.size)
            let result = withUnsafeMutablePointer(to: &info) { pointer in
                pointer.withMemoryRebound(to: integer_t.self, capacity: Int(infoCount)) {
                    thread_info(thread, thread_flavor_t(THREAD_BASIC_INFO), $0, &infoCount)
                }
            }
            guard result == KERN_SUCCESS, info.flags & TH_FLAGS_IDLE == 0 else { continue }
            let percent = Double(info.cpu_usage) / Double(TH_USAGE_SCALE) * 100
            guard percent >= 1 else { continue }
            var name = [CChar](repeating: 0, count: 64)
            if let pthread = pthread_from_mach_thread_np(thread) { pthread_getname_np(pthread, &name, name.count) }
            var label = String(cString: name)
            if label.isEmpty { label = thread == main ? "main" : "thread \(thread)" }
            loads.append((label, percent))
        }
        return loads.sorted { $0.percent > $1.percent }
    }

    /// User + system CPU time consumed by this process so far.
    static func cpuSeconds() -> Double {
        var usage = rusage()
        getrusage(RUSAGE_SELF, &usage)
        let seconds = { (time: timeval) in Double(time.tv_sec) + Double(time.tv_usec) / 1_000_000 }
        return seconds(usage.ru_utime) + seconds(usage.ru_stime)
    }
}

/// Thread-safe latest-value holder for the resolution proof's event handler.
private final class SizeBox: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: CGSize?
    var value: CGSize? { lock.lock(); defer { lock.unlock() }; return stored }
    func set(_ size: CGSize) { lock.lock(); stored = size; lock.unlock() }
}
