// SPDX-FileCopyrightText: 2026 Nick Wolff <nick@wolff.tech>
// SPDX-License-Identifier: GPL-3.0-only

import Foundation
import GhosttyKit
import Testing
@testable import ConstellationTerminal

/// Loads a real user config through libghostty. libghostty snapshots the
/// environment in `ghostty_init`, so `XDG_CONFIG_HOME` only takes effect if
/// this test initializes the library. When another suite got there first the
/// test cannot observe anything and returns early; run it alone with
/// `swift test --filter GhosttyConfigTests` for a definitive result.
@MainActor
struct GhosttyConfigTests {
    @Test func loadsTheUsersGhosttyConfigOnlyWhenOptedIn() throws {
        let home = FileManager.default.temporaryDirectory
            .appendingPathComponent("constellation-xdg-\(UUID().uuidString)")
        let ghosttyDir = home.appendingPathComponent("ghostty")
        try FileManager.default.createDirectory(at: ghosttyDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: home) }
        try """
        font-size = 21
        keybind = super+t=new_tab
        not-a-real-key = 1
        """.write(to: ghosttyDir.appendingPathComponent("config"), atomically: true, encoding: .utf8)

        guard !GhosttyRuntime.libraryInitialized else { return }
        setenv("XDG_CONFIG_HOME", home.path, 1)
        try GhosttyRuntime.initializeLibrary()

        var appearance = TerminalAppearance.default
        appearance.usesGhosttyConfig = true
        let userConfig = try GhosttyConfig(appearance: appearance)
        #expect(fontSize(of: userConfig) == 21)
        #expect(userConfig.diagnostics.contains { $0.contains("not-a-real-key") })
        // Constellation's keybinds replace the user's.
        #expect(!isBound(userConfig, action: "new_tab"))
        #expect(isBound(userConfig, action: "copy_to_clipboard"))

        let appConfig = try GhosttyConfig(appearance: .default)
        #expect(fontSize(of: appConfig) == 13)
        #expect(appConfig.diagnostics.isEmpty)
    }

    private func fontSize(of config: GhosttyConfig) -> Float? {
        var value: Float = 0
        let key = "font-size"
        return ghostty_config_get(config.handle, &value, key, UInt(key.utf8.count)) ? value : nil
    }

    /// `ghostty_config_trigger` looks up the trigger bound to an action; an
    /// unbound action comes back with no modifiers and no key.
    private func isBound(_ config: GhosttyConfig, action: String) -> Bool {
        let trigger = ghostty_config_trigger(config.handle, action, UInt(action.utf8.count))
        return trigger.mods.rawValue != 0 || trigger.key.physical != GHOSTTY_KEY_UNIDENTIFIED
    }
}
