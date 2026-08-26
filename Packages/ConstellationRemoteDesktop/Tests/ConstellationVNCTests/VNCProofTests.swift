// SPDX-FileCopyrightText: 2026 Nick Wolff <nick@wolff.tech>
// SPDX-License-Identifier: GPL-3.0-only

import AppKit
import ConstellationRemoteDesktop
import Testing
@testable import ConstellationVNC

/// Real connection against a VNC server. Gated on environment so CI skips it:
///   TEST_RUNNER_CONSTELLATION_TEST_VNC_HOST=127.0.0.1 (default)
///   TEST_RUNNER_CONSTELLATION_TEST_VNC_PORT=5900 (default)
///   TEST_RUNNER_CONSTELLATION_TEST_VNC_USERNAME=<account, for Screen Sharing / ARD>
///   TEST_RUNNER_CONSTELLATION_TEST_VNC_PASSWORD=<password>
@MainActor
struct VNCProofTests {
    private nonisolated static var password: String? {
        ProcessInfo.processInfo.environment["CONSTELLATION_TEST_VNC_PASSWORD"].flatMap { $0.isEmpty ? nil : $0 }
    }

    @Test(.enabled(if: password != nil, "set CONSTELLATION_TEST_VNC_PASSWORD to run"))
    func connectsAuthenticatesAndReceivesAFramebuffer() async throws {
        let env = ProcessInfo.processInfo.environment
        let password = try #require(Self.password)
        let username = env["CONSTELLATION_TEST_VNC_USERNAME"]
        let configuration = VNCSessionConfiguration(
            host: env["CONSTELLATION_TEST_VNC_HOST"] ?? "127.0.0.1",
            port: Int(env["CONSTELLATION_TEST_VNC_PORT"] ?? "") ?? 5900,
            username: username)
        let session = RoyalVNCSession(configuration: configuration) { request in
            switch request {
            case .password: .password(password)
            case .usernameAndPassword: username.map { .usernameAndPassword(username: $0, password: password) }
            }
        }
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 800, height: 600), styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = session.view

        var sizes: [(Int, Int)] = []
        let outcome = AsyncStream<RemoteDesktopSessionState>.makeStream()
        session.eventHandler = { event in
            switch event {
            case .framebufferSizeChanged(let width, let height):
                sizes.append((width, height))
                outcome.continuation.yield(.connected)
            case .stateChanged(.disconnected(let failure)):
                outcome.continuation.yield(.disconnected(failure))
            default:
                break
            }
        }
        session.connect()
        let first = await withTimeout(seconds: 20) { for await state in outcome.stream { return state }; return nil }
        #expect(first == .connected, "expected a framebuffer, got \(String(describing: first))")
        #expect(sizes.first.map { $0.0 > 0 && $0.1 > 0 } == true)
        #expect(session.state == .connected)

        session.disconnect()
        let last = await withTimeout(seconds: 10) {
            for await state in outcome.stream where !state.isLive { return state }
            return nil
        }
        #expect(last == .disconnected(nil))
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
