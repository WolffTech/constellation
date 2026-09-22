// SPDX-FileCopyrightText: 2026 Nick Wolff <nick@wolff.tech>
// SPDX-License-Identifier: GPL-3.0-only

import AppKit
import Testing
@testable import Constellation

@MainActor
@Suite(.serialized)
struct SessionWindowLayoutTests {
    @Test func tabsCanLeaveForTheirOwnWindowAndMergeBack() throws {
        let first = makeWindow()
        let second = makeWindow()
        let third = makeWindow()
        defer { [first, second, third].forEach { $0.close() } }

        first.makeKeyAndOrderFront(nil)
        first.addTabbedWindow(second, ordered: .above)
        second.addTabbedWindow(third, ordered: .above)
        let group = try #require(first.tabGroup)
        #expect(SessionWindowLayout.native(of: [first, second, third]) == [[first, second, third]])

        SessionWindowLayout.apply([[first, third], [second]])
        #expect(group.windows == [first, third])
        #expect(second.tabGroup !== group)
        #expect(second.isVisible)
        #expect(second.frame.origin != first.frame.origin)
        #expect(SessionWindowLayout.native(of: [first, second, third]) == [[first, third], [second]])

        // Applying the same layout again changes nothing.
        SessionWindowLayout.apply([[first, third], [second]])
        #expect(group.windows == [first, third])
        #expect(second.tabGroup !== group)

        SessionWindowLayout.apply([[second, first, third]])
        let merged = try #require(second.tabGroup)
        #expect(merged.windows == [second, first, third])
        #expect(first.tabGroup === merged)
        #expect(third.tabGroup === merged)
        #expect(SessionWindowLayout.native(of: [first, second, third]) == [[second, first, third]])
    }

    @Test func aTabCanMoveIntoAnotherWindow() throws {
        let first = makeWindow()
        let second = makeWindow()
        let third = makeWindow()
        defer { [first, second, third].forEach { $0.close() } }

        first.makeKeyAndOrderFront(nil)
        first.addTabbedWindow(second, ordered: .above)
        // Preferred tabbing would otherwise join the window to the existing group.
        third.tabbingMode = .disallowed
        third.makeKeyAndOrderFront(nil)
        third.tabbingMode = .preferred
        #expect(SessionWindowLayout.native(of: [first, second, third]).count == 2)

        SessionWindowLayout.apply([[first], [third, second]])
        #expect(first.tabGroup?.windows == [first])
        let other = try #require(third.tabGroup)
        #expect(other !== first.tabGroup)
        #expect(other.windows == [third, second])
    }

    private func makeWindow() -> NSWindow {
        _ = NSApplication.shared
        let window = NSWindow(
            contentRect: NSRect(x: 100, y: 100, width: 800, height: 600),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false)
        window.isReleasedWhenClosed = false
        window.tabbingMode = .preferred
        window.tabbingIdentifier = "SessionWindowLayoutTests"
        return window
    }
}
