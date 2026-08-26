// SPDX-FileCopyrightText: 2026 Nick Wolff <nick@wolff.tech>
// SPDX-License-Identifier: GPL-3.0-only

import AppKit
import Observation

public enum TerminalProcessState: Sendable, Equatable {
    case running
    case exited(code: Int32)
}

public enum TerminalInput: Sendable, Equatable {
    /// Text delivered as if typed; libghostty encodes it for the pty.
    case text(String)
}

public enum TerminalEvent: Sendable, Equatable {
    case titleChanged(String)
    case processExited(code: Int32, runtime: Duration)
    case closeRequested(processAlive: Bool)
    case bell
    case rendererHealthChanged(Bool)
}

/// The app shell's view of one terminal. Protocol-specific behavior lives on the
/// concrete session, not here.
@MainActor
public protocol TerminalSession: AnyObject {
    var view: NSView { get }
    var title: String { get }
    var processState: TerminalProcessState { get }
    var eventHandler: (@MainActor (TerminalEvent) -> Void)? { get set }

    func send(_ input: TerminalInput)
    @discardableResult func performBinding(_ action: String) -> Bool
    func close()
}

/// A libghostty-backed terminal running one `TerminalCommand`.
@MainActor
@Observable
public final class GhosttyTerminalSession: TerminalSession {
    public let surfaceView: GhosttySurfaceView
    public var view: NSView { surfaceView }

    public private(set) var title: String = ""
    public private(set) var processState: TerminalProcessState = .running
    public private(set) var rendererHealthy = true
    public private(set) var isClosed = false
    public var eventHandler: (@MainActor (TerminalEvent) -> Void)?

    /// Called when libghostty asks to close the surface: the user pressed a key
    /// after the process exited, or a close binding fired.
    public var onCloseRequest: (@MainActor (_ processAlive: Bool) -> Void)?
    public var onBell: (@MainActor () -> Void)?

    init(runtime: GhosttyRuntime, command: TerminalCommand) throws {
        surfaceView = try GhosttySurfaceView(runtime: runtime, command: command)
        surfaceView.delegate = self
    }

    public func send(_ input: TerminalInput) {
        switch input {
        case .text(let text):
            surfaceView.sendText(text)
        }
    }

    /// Runs a Ghostty binding action such as `copy_to_clipboard`.
    @discardableResult
    public func performBinding(_ action: String) -> Bool {
        surfaceView.performBinding(action)
    }

    /// Text currently visible in the viewport.
    public func visibleText() -> String {
        surfaceView.readText(.viewport)
    }

    /// Full screen contents including scrollback.
    public func screenText() -> String {
        surfaceView.readText(.screen)
    }

    /// PID of the pty's foreground process group, or `nil` once closed.
    public func foregroundProcessID() -> pid_t? {
        surfaceView.foregroundProcessID()
    }

    /// Frees the surface. libghostty terminates and reaps the child.
    public func close() {
        guard !isClosed else { return }
        isClosed = true
        surfaceView.destroySurface()
    }
}

extension GhosttyTerminalSession: GhosttySurfaceViewDelegate {
    func surfaceView(_ view: GhosttySurfaceView, didSetTitle title: String) {
        self.title = title
        eventHandler?(.titleChanged(title))
    }

    func surfaceView(_ view: GhosttySurfaceView, childExitedWithCode code: Int32, runtime: Duration) {
        processState = .exited(code: code)
        eventHandler?(.processExited(code: code, runtime: runtime))
    }

    func surfaceViewDidRequestClose(_ view: GhosttySurfaceView, processAlive: Bool) {
        eventHandler?(.closeRequested(processAlive: processAlive))
        onCloseRequest?(processAlive)
    }

    func surfaceViewDidRingBell(_ view: GhosttySurfaceView) {
        eventHandler?(.bell)
        onBell?()
    }

    func surfaceView(_ view: GhosttySurfaceView, rendererHealthy healthy: Bool) {
        rendererHealthy = healthy
        eventHandler?(.rendererHealthChanged(healthy))
    }
}
