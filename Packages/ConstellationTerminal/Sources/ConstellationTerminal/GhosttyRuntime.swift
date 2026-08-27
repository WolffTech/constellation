// SPDX-FileCopyrightText: 2026 Nick Wolff <nick@wolff.tech>
// SPDX-License-Identifier: GPL-3.0-only

import AppKit
import GhosttyKit

/// The single `ghostty_app_t` for the process. Creates terminal sessions and
/// receives libghostty's runtime callbacks, which it routes to the surface view
/// named by the callback's userdata.
@MainActor
public final class GhosttyRuntime {
    nonisolated(unsafe) private(set) static var libraryInitialized = false

    nonisolated(unsafe) private(set) var app: ghostty_app_t?
    private var config: GhosttyConfig
    private var observers: [NSObjectProtocol] = []

    public init(appearance: TerminalAppearance) throws {
        try Self.initializeLibrary()
        config = try GhosttyConfig(appearance: appearance)

        var runtime = ghostty_runtime_config_s()
        runtime.userdata = Unmanaged.passUnretained(self).toOpaque()
        runtime.supports_selection_clipboard = false
        runtime.wakeup_cb = { userdata in
            guard let userdata else { return }
            let runtime = Unmanaged<GhosttyRuntime>.fromOpaque(userdata).takeUnretainedValue()
            // Wakeups arrive on any thread. Schedule on the main run loop rather than
            // the main dispatch queue so ticks also run inside nested run loops
            // (modal panels, tests that spin RunLoop.main).
            CFRunLoopPerformBlock(CFRunLoopGetMain(), CFRunLoopMode.commonModes.rawValue) {
                MainActor.assumeIsolated { runtime.tick() }
            }
            CFRunLoopWakeUp(CFRunLoopGetMain())
        }
        runtime.action_cb = { _, target, action in
            MainActor.assumeIsolated {
                guard let view = GhosttySurfaceView.from(target: target) else { return false }
                return view.handle(action: action)
            }
        }
        runtime.read_clipboard_cb = { userdata, location, state in
            MainActor.assumeIsolated {
                GhosttySurfaceView.from(userdata: userdata)?
                    .readClipboard(location: location, state: state) ?? false
            }
        }
        runtime.confirm_read_clipboard_cb = { userdata, string, state, request in
            MainActor.assumeIsolated {
                GhosttySurfaceView.from(userdata: userdata)?
                    .confirmReadClipboard(string: string, state: state, request: request)
            }
        }
        runtime.write_clipboard_cb = { userdata, location, content, count, confirm in
            MainActor.assumeIsolated {
                GhosttySurfaceView.from(userdata: userdata)?
                    .writeClipboard(location: location, content: content, count: count, confirm: confirm)
            }
        }
        runtime.close_surface_cb = { userdata, processAlive in
            MainActor.assumeIsolated {
                GhosttySurfaceView.from(userdata: userdata)?
                    .closeRequested(processAlive: processAlive)
            }
        }

        guard let app = ghostty_app_new(&runtime, config.handle) else {
            throw TerminalError.appCreationFailed
        }
        self.app = app
        ghostty_app_set_focus(app, NSApp?.isActive ?? false)

        let center = NotificationCenter.default
        observers = [
            center.addObserver(forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.setAppFocus(true) }
            },
            center.addObserver(forName: NSApplication.didResignActiveNotification, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.setAppFocus(false) }
            },
            center.addObserver(forName: NSTextInputContext.keyboardSelectionDidChangeNotification, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.keyboardChanged() }
            },
        ]
    }

    isolated deinit {
        for observer in observers { NotificationCenter.default.removeObserver(observer) }
        if let app { ghostty_app_free(app) }
    }

    public func makeSession(command: TerminalCommand) throws -> GhosttyTerminalSession {
        try GhosttyTerminalSession(runtime: self, command: command)
    }

    /// Warnings libghostty raised while loading the current configuration,
    /// such as unknown keys in the user's Ghostty config. Empty when clean.
    public var configDiagnostics: [String] { config.diagnostics }

    /// Applies app-owned settings to existing and future surfaces and returns
    /// the diagnostics of the new configuration.
    @discardableResult
    public func updateAppearance(_ appearance: TerminalAppearance) throws -> [String] {
        let updated = try GhosttyConfig(appearance: appearance)
        guard let app else { throw TerminalError.appCreationFailed }
        ghostty_app_update_config(app, updated.handle)
        config = updated
        return updated.diagnostics
    }

    func tick() {
        guard let app else { return }
        ghostty_app_tick(app)
    }

    private func setAppFocus(_ focused: Bool) {
        guard let app else { return }
        ghostty_app_set_focus(app, focused)
    }

    private func keyboardChanged() {
        guard let app else { return }
        ghostty_app_keyboard_changed(app)
    }

    static func initializeLibrary() throws {
        guard !libraryInitialized else { return }
        let status = ghostty_init(UInt(CommandLine.argc), CommandLine.unsafeArgv)
        guard status == 0 else { throw TerminalError.libraryInitFailed(status) }
        libraryInitialized = true
    }
}
