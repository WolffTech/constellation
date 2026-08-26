// SPDX-FileCopyrightText: 2026 Nick Wolff <nick@wolff.tech>
// SPDX-License-Identifier: GPL-3.0-only

import ConstellationCore
import Foundation
import Observation
import SwiftUI

/// Which machines are collapsed in the sidebar. Machines start expanded, so
/// only the collapsed set is stored.
@MainActor
@Observable
final class SidebarExpansionStore {
    private static let defaultsKey = "sidebarCollapsedMachines"

    private var collapsed: Set<String>
    @ObservationIgnored private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        collapsed = Set(defaults.stringArray(forKey: Self.defaultsKey) ?? [])
    }

    func isExpanded(_ id: MachineID) -> Bool {
        !collapsed.contains(id.description)
    }

    func setExpanded(_ expanded: Bool, for id: MachineID) {
        if expanded { collapsed.remove(id.description) } else { collapsed.insert(id.description) }
        defaults.set(collapsed.sorted(), forKey: Self.defaultsKey)
    }

    func binding(for id: MachineID) -> Binding<Bool> {
        Binding(get: { self.isExpanded(id) }, set: { self.setExpanded($0, for: id) })
    }
}
