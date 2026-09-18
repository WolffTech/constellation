// SPDX-FileCopyrightText: 2026 Nick Wolff <nick@wolff.tech>
// SPDX-License-Identifier: GPL-3.0-only

import AppKit
import Testing
@testable import Constellation

@MainActor
@Suite(.serialized)
struct SessionWindowHandoffTests {
    @Test func reorderedSessionCanReturnToMachineDetailsRepeatedly() throws {
        let browser = makeWindow()
        let session = makeWindow()
        defer { [browser, session].forEach { $0.close() } }

        browser.makeKeyAndOrderFront(nil)
        SessionWindowHandoff.prepare(session, replacing: browser)
        let group = try #require(session.tabGroup)
        SessionWindowTabOrder.apply([session], to: group)
        session.makeKeyAndOrderFront(nil)
        if !group.isTabBarVisible {
            session.toggleTabBar(nil)
        }
        RunLoop.main.run(until: Date().addingTimeInterval(0.1))

        for _ in 0..<3 {
            group.selectedWindow = session
            session.makeKeyAndOrderFront(nil)
            SessionWindowTabOrder.apply([session], to: group)
            #expect(group.windows == [session, browser])
            #expect(group.selectedWindow === session)
            browser.orderOut(nil)
            #expect(!browser.isVisible)
            #expect(group.windows == [session])

            SessionWindowHandoff.showBrowser(browser, alongside: session)
            #expect(browser.tabGroup === group)
            #expect(group.windows == [session, browser])
            #expect(group.selectedWindow === browser)
            #expect(browser.isVisible)
        }
    }

    @Test func reorderingSessionsPreservesSelectionAndAllowsBrowserHandoffs() throws {
        let browser = makeWindow()
        let first = makeWindow()
        let second = makeWindow()
        defer { [browser, first, second].forEach { $0.close() } }

        browser.makeKeyAndOrderFront(nil)
        SessionWindowHandoff.prepare(first, replacing: browser)
        first.addTabbedWindow(second, ordered: .above)
        let group = try #require(first.tabGroup)
        group.selectedWindow = second
        second.makeKeyAndOrderFront(nil)
        if !group.isTabBarVisible {
            second.toggleTabBar(nil)
        }
        RunLoop.main.run(until: Date().addingTimeInterval(0.1))

        for order in [[second, first], [first, second], [second, first]] {
            SessionWindowTabOrder.apply(order, to: group)
            #expect(group.windows == order + [browser])
            #expect(group.selectedWindow === second)
            browser.orderOut(nil)
            #expect(group.windows == order)
            SessionWindowHandoff.showBrowser(browser, alongside: order.last)
            #expect(group.windows == order + [browser])
            #expect(group.selectedWindow === browser)
            group.selectedWindow = second
        }
    }

    @Test func machineDetailsReturnToTheExistingSessionTabGroup() throws {
        let browser = makeWindow()
        let first = makeWindow()
        let second = makeWindow()
        defer { [browser, first, second].forEach { $0.close() } }

        SessionWindowHandoff.prepare(first, replacing: browser)
        browser.orderOut(nil)
        first.addTabbedWindow(second, ordered: .above)
        second.tabGroup?.selectedWindow = second
        second.makeKeyAndOrderFront(nil)
        let frame = second.frame
        #expect(!browser.isVisible)

        SessionWindowHandoff.showBrowser(browser, alongside: second)

        let group = try #require(browser.tabGroup)
        #expect(group === first.tabGroup)
        #expect(group === second.tabGroup)
        #expect(group.selectedWindow === browser)
        #expect(browser.isVisible)
        #expect(browser.frame == frame)
        #expect(group.windows.count == 3)

        // Selecting another machine reuses the same overview tab.
        SessionWindowHandoff.showBrowser(browser, alongside: first)
        #expect(group.selectedWindow === browser)
        #expect(group.windows.count == 3)

        // The existing connection can be selected and its details revisited.
        group.selectedWindow = first
        first.makeKeyAndOrderFront(nil)
        browser.orderOut(nil)
        SessionWindowHandoff.showBrowser(browser, alongside: first)
        #expect(browser.tabGroup === first.tabGroup)
        #expect(browser.tabGroup?.selectedWindow === browser)
        #expect(browser.tabGroup?.windows.count == 3)
    }

    @Test func closingTheLastSessionAfterShowingMachineDetailsReusesTheSharedTab() throws {
        let browser = makeWindow()
        let session = makeWindow()
        defer { [browser, session].forEach { $0.close() } }

        SessionWindowHandoff.prepare(session, replacing: browser)
        browser.orderOut(nil)
        session.makeKeyAndOrderFront(nil)
        SessionWindowHandoff.showBrowser(browser, alongside: session)
        let group = try #require(browser.tabGroup)
        #expect(group === session.tabGroup)
        // Let AppKit build the tab bar so the group is in the same state as a running app.
        if !group.isTabBarVisible {
            session.toggleTabBar(nil)
        }
        RunLoop.main.run(until: Date().addingTimeInterval(0.1))

        // Closing the last session hands the group back to the browser without re-adding it.
        SessionWindowHandoff.prepare(browser, replacing: session)

        #expect(browser.tabGroup === group)
        #expect(group.selectedWindow === browser)
        #expect(group.windows.count == 2)
        #expect(browser.frame == session.frame)
    }

    @Test func machineDetailsCanBeShownWithoutAnySessionWindows() {
        let browser = makeWindow()
        defer { browser.close() }
        #expect(!browser.isVisible)

        SessionWindowHandoff.showBrowser(browser, alongside: nil)

        #expect(browser.isVisible)
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
        window.tabbingIdentifier = "SessionWindowHandoffTests"
        return window
    }
}
