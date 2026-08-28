// SPDX-FileCopyrightText: 2026 Nick Wolff <nick@wolff.tech>
// SPDX-License-Identifier: GPL-3.0-only

import ConstellationCore
import Foundation
import Observation

/// The last few Quick Connect targets, newest first. Only host, user and
/// port are kept, as the text the user typed; secrets never pass through here.
@MainActor
@Observable
final class QuickConnectHistory {
    static let limit = 8
    private static let key = "quickConnectHistory"

    private(set) var targets: [QuickConnectTarget]
    @ObservationIgnored private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        let stored = defaults.stringArray(forKey: Self.key) ?? []
        targets = stored.compactMap { try? QuickConnectTarget(parsing: $0) }
    }

    func record(_ target: QuickConnectTarget) {
        targets.removeAll { $0 == target }
        targets.insert(target, at: 0)
        targets = Array(targets.prefix(Self.limit))
        defaults.set(targets.map(\.displayName), forKey: Self.key)
    }
}
