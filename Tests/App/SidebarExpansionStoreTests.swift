// SPDX-FileCopyrightText: 2026 Nick Wolff <nick@wolff.tech>
// SPDX-License-Identifier: GPL-3.0-only

import ConstellationCore
import Foundation
import Testing
@testable import Constellation

@MainActor
struct SidebarExpansionStoreTests {
    @Test func machinesStartExpandedAndCollapsedStatePersists() throws {
        let suiteName = "SidebarExpansionStoreTests-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let machine = MachineID()
        let other = MachineID()

        let store = SidebarExpansionStore(defaults: defaults)
        #expect(store.isExpanded(machine))
        store.setExpanded(false, for: machine)
        #expect(!store.isExpanded(machine))
        #expect(store.isExpanded(other))

        let reloaded = SidebarExpansionStore(defaults: defaults)
        #expect(!reloaded.isExpanded(machine))
        reloaded.setExpanded(true, for: machine)
        #expect(SidebarExpansionStore(defaults: defaults).isExpanded(machine))
    }

    @Test func groupsCollapseIndependentlyAndPersist() throws {
        let suiteName = "SidebarExpansionStoreTests-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let group = GroupID()
        let other = GroupID()

        let store = SidebarExpansionStore(defaults: defaults)
        #expect(store.isExpanded(group: group))
        #expect(store.isExpanded(group: nil))
        store.setExpanded(false, group: group)
        store.setExpanded(false, group: nil)
        #expect(store.isExpanded(group: other))

        let reloaded = SidebarExpansionStore(defaults: defaults)
        #expect(!reloaded.isExpanded(group: group))
        #expect(!reloaded.isExpanded(group: nil))
        reloaded.setExpanded(true, group: group)
        #expect(SidebarExpansionStore(defaults: defaults).isExpanded(group: group))
    }
}
