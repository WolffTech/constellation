// SPDX-FileCopyrightText: 2026 Nick Wolff <nick@wolff.tech>
// SPDX-License-Identifier: GPL-3.0-only

import ConstellationTerminal
import Foundation
import Testing
@testable import Constellation

@MainActor
struct TerminalSettingsStoreTests {
    @Test func updatesApplyAndPersist() throws {
        let suiteName = "TerminalSettingsStoreTests-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let store = TerminalSettingsStore(defaults: defaults)
        var applied: [TerminalAppearance] = []
        store.applyAppearance = { applied.append($0) }

        store.update {
            $0.fontFamily = "JetBrains Mono"
            $0.fontSize = 15
            $0.theme = "Catppuccin Mocha"
            $0.scrollbackLimitBytes = 50_000_000
        }

        #expect(applied == [store.appearance])
        #expect(TerminalSettingsStore(defaults: defaults).appearance == store.appearance)
    }

    @Test func rejectedUpdatesDoNotReplaceTheStoredAppearance() throws {
        let suiteName = "TerminalSettingsStoreTests-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let store = TerminalSettingsStore(defaults: defaults)
        store.applyAppearance = { _ in throw TestError.rejected }

        store.update { $0.fontSize = 20 }

        #expect(store.appearance == .default)
        #expect(store.presentedError != nil)
        #expect(TerminalSettingsStore(defaults: defaults).appearance == .default)
    }

    private enum TestError: Error { case rejected }
}
