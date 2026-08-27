// SPDX-FileCopyrightText: 2026 Nick Wolff <nick@wolff.tech>
// SPDX-License-Identifier: GPL-3.0-only

import AppKit
import Foundation
import Testing
@testable import ConstellationTerminal

/// Proves a light/dark theme pair follows the color scheme end to end: the
/// scheme reaches the surface, libghostty asks for its config back, and the
/// re-applied config carries the other theme's background. Bundled themes are
/// not reachable under `swift test`, so the pair points at theme files the
/// test writes itself.
@MainActor
struct ColorSchemeTests {
    @Test func surfacesSwitchThemeWithTheColorScheme() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("constellation-themes-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let light = directory.appendingPathComponent("day")
        let dark = directory.appendingPathComponent("night")
        try "background = #faf4ed\n".write(to: light, atomically: true, encoding: .utf8)
        try "background = #191724\n".write(to: dark, atomically: true, encoding: .utf8)

        _ = NSApplication.shared
        let runtime = try GhosttyRuntime(appearance: .default)
        let session = try runtime.makeSession(command: TerminalCommand(executable: "/bin/cat"))
        defer { session.close() }
        let view = session.surfaceView

        // Applying the pair to a live surface reports the background for the
        // scheme the runtime picked up from the system at init.
        let diagnostics = try runtime.updateAppearance(TerminalAppearance(theme: light.path, darkTheme: dark.path))
        #expect(diagnostics.isEmpty)
        #expect(waitUntil { view.backgroundColor != nil })
        let startedDark = view.backgroundColor == Self.night
        #expect(view.backgroundColor == (startedDark ? Self.night : Self.day))

        runtime.setColorScheme(dark: !startedDark)
        #expect(waitUntil { view.backgroundColor == (startedDark ? Self.day : Self.night) })

        runtime.setColorScheme(dark: startedDark)
        #expect(waitUntil { view.backgroundColor == (startedDark ? Self.night : Self.day) })
    }

    private static let day = NSColor(srgbRed: 0xfa / 255, green: 0xf4 / 255, blue: 0xed / 255, alpha: 1)
    private static let night = NSColor(srgbRed: 0x19 / 255, green: 0x17 / 255, blue: 0x24 / 255, alpha: 1)

    private func waitUntil(_ timeout: Duration = .seconds(5), _ condition: () -> Bool) -> Bool {
        let deadline = ContinuousClock.now + timeout
        while ContinuousClock.now < deadline {
            if condition() { return true }
            RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.05))
        }
        return condition()
    }
}
