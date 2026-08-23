import AppKit
import Testing
@testable import ConstellationTerminal

/// End-to-end tests against real surfaces running local commands. These need a
/// window server (they run on a developer Mac and on GitHub's macOS runners).
@MainActor
struct LocalShellSessionTests {
    /// One runtime per process; libghostty expects a single app instance.
    nonisolated(unsafe) private static var sharedRuntime: GhosttyRuntime?

    private static func runtime() throws -> GhosttyRuntime {
        if let sharedRuntime { return sharedRuntime }
        _ = NSApplication.shared
        let runtime = try GhosttyRuntime(appearance: .default)
        sharedRuntime = runtime
        return runtime
    }

    private func host(_ session: GhosttyTerminalSession) -> NSWindow {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 640, height: 400),
            styleMask: [.titled],
            backing: .buffered,
            defer: false)
        // Programmatic NSWindows release themselves on close; ARC would then over-release.
        window.isReleasedWhenClosed = false
        window.contentView = session.view
        window.orderFrontRegardless()
        window.makeFirstResponder(session.view)
        return window
    }

    private func waitUntil(_ timeout: Duration = .seconds(10), _ condition: () -> Bool) -> Bool {
        let deadline = ContinuousClock.now + timeout
        while ContinuousClock.now < deadline {
            if condition() { return true }
            RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.05))
        }
        return condition()
    }

    @Test func typedTextRoundTripsThroughThePty() throws {
        let session = try Self.runtime().makeSession(command: TerminalCommand(executable: "/bin/cat"))
        let window = host(session)
        defer { session.close(); window.close() }

        #expect(waitUntil { session.foregroundProcessID() != nil })
        session.send(.text("constellation-roundtrip\n"))
        #expect(waitUntil { session.visibleText().contains("constellation-roundtrip") })
    }

    /// libghostty wraps commands in `/usr/bin/login` on macOS, which reports the
    /// shell's exit status as 0, so only the transition is asserted here.
    @Test func processExitIsReported() throws {
        let session = try Self.runtime().makeSession(
            command: TerminalCommand(executable: "/bin/sh", arguments: ["-c", "exit 3"]))
        let window = host(session)
        defer { session.close(); window.close() }

        #expect(waitUntil { session.processState != .running }, "screen was: \(session.screenText())")
        guard case .exited = session.processState else {
            Issue.record("expected exited, got \(session.processState)")
            return
        }
    }

    @Test func closingTheSessionTerminatesAndReapsTheChild() throws {
        let session = try Self.runtime().makeSession(
            command: TerminalCommand(executable: "/bin/sh", arguments: ["-c", "echo ready; sleep 300"]))
        let window = host(session)
        defer { window.close() }

        #expect(waitUntil { session.visibleText().contains("ready") })
        // On macOS this is the `login` wrapper's pid; its shell and `sleep` hang off it.
        let pid = try #require(session.foregroundProcessID())
        #expect(kill(pid, 0) == 0)

        session.close()

        // kill(pid, 0) succeeds for zombies too, so this also proves the child was reaped.
        #expect(waitUntil(.seconds(5)) { kill(pid, 0) == -1 && errno == ESRCH })
        #expect(session.foregroundProcessID() == nil)
    }

    @Test func resizingTheViewChangesTheGrid() throws {
        let session = try Self.runtime().makeSession(command: TerminalCommand(executable: "/bin/cat"))
        let window = host(session)
        defer { session.close(); window.close() }

        #expect(waitUntil { session.surfaceView.cellSize != .zero })
        let before = session.surfaceView.gridSize
        window.setContentSize(NSSize(width: 1000, height: 700))
        #expect(waitUntil { session.surfaceView.gridSize != before })
        let after = session.surfaceView.gridSize
        #expect(after.columns > before.columns)
        #expect(after.rows > before.rows)
    }
}
