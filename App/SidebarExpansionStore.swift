// SPDX-FileCopyrightText: 2026 Nick Wolff <nick@wolff.tech>
// SPDX-License-Identifier: GPL-3.0-only

import ConstellationCore
import Foundation
import Observation
import SwiftUI

/// Which machines and groups are collapsed in the sidebar. Everything starts
/// expanded, so only the collapsed sets are stored.
@MainActor
@Observable
final class SidebarExpansionStore {
    private static let machinesKey = "sidebarCollapsedMachines"
    private static let groupsKey = "sidebarCollapsedGroups"
    /// Stands in for the ungrouped section, which has no `GroupID`.
    private static let ungroupedKey = "ungrouped"

    private var collapsedMachines: Set<String>
    private var collapsedGroups: Set<String>
    @ObservationIgnored private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        collapsedMachines = Set(defaults.stringArray(forKey: Self.machinesKey) ?? [])
        collapsedGroups = Set(defaults.stringArray(forKey: Self.groupsKey) ?? [])
    }

    func isExpanded(_ id: MachineID) -> Bool {
        !collapsedMachines.contains(id.description)
    }

    func setExpanded(_ expanded: Bool, for id: MachineID) {
        Self.update(&collapsedMachines, key: id.description, expanded: expanded)
        defaults.set(collapsedMachines.sorted(), forKey: Self.machinesKey)
    }

    func binding(for id: MachineID) -> Binding<Bool> {
        Binding(get: { self.isExpanded(id) }, set: { self.setExpanded($0, for: id) })
    }

    /// `nil` is the ungrouped section.
    func isExpanded(group id: GroupID?) -> Bool {
        !collapsedGroups.contains(Self.key(for: id))
    }

    func setExpanded(_ expanded: Bool, group id: GroupID?) {
        Self.update(&collapsedGroups, key: Self.key(for: id), expanded: expanded)
        defaults.set(collapsedGroups.sorted(), forKey: Self.groupsKey)
    }

    private static func key(for group: GroupID?) -> String {
        group?.description ?? ungroupedKey
    }

    private static func update(_ collapsed: inout Set<String>, key: String, expanded: Bool) {
        if expanded { collapsed.remove(key) } else { collapsed.insert(key) }
    }
}
