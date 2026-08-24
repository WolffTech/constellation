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
}
