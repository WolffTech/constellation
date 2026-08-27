// SPDX-FileCopyrightText: 2026 Nick Wolff <nick@wolff.tech>
// SPDX-License-Identifier: GPL-3.0-only

import ConstellationTerminal
import Foundation
import Observation

@MainActor
@Observable
final class TerminalSettingsStore {
    private static let defaultsKey = "terminalAppearance"

    var appearance: TerminalAppearance {
        didSet {
            save()
        }
    }
    var presentedError: String?
    /// Warnings from the last applied configuration, shown in Settings so a
    /// typo in the user's Ghostty config is not silently ignored.
    var diagnostics: [String] = []

    @ObservationIgnored
    var applyAppearance: (@MainActor (TerminalAppearance) throws -> [String])?

    @ObservationIgnored
    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        if let data = defaults.data(forKey: Self.defaultsKey),
           let decoded = try? JSONDecoder().decode(TerminalAppearance.self, from: data) {
            appearance = decoded
        } else {
            appearance = .default
        }
    }

    func update(_ change: (inout TerminalAppearance) -> Void) {
        var updated = appearance
        change(&updated)
        do {
            diagnostics = try applyAppearance?(updated) ?? []
            appearance = updated
            presentedError = nil
        } catch {
            presentedError = error.localizedDescription
        }
    }

    func reset() {
        update { $0 = .default }
    }

    private func save() {
        guard let data = try? JSONEncoder().encode(appearance) else { return }
        defaults.set(data, forKey: Self.defaultsKey)
    }
}
