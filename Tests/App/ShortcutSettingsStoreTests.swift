// SPDX-FileCopyrightText: 2026 Nick Wolff <nick@wolff.tech>
// SPDX-License-Identifier: GPL-3.0-only

import AppKit
import Foundation
import Testing
@testable import Constellation

@MainActor
struct ShortcutSettingsStoreTests {
    @Test func defaultsMatchTheDocumentedShortcuts() throws {
        let store = try makeStore()
        #expect(store.shortcut(for: .commandPalette) == Shortcut(.character("k"), [.command]))
        #expect(store.shortcut(for: .quickConnect) == Shortcut(.character("k"), [.command, .shift]))
        #expect(store.shortcut(for: .previousTab) == Shortcut(.tab, [.control, .shift]))
        #expect(store.shortcut(for: .disconnect) == nil)
        #expect(store.hint(for: .closeOtherSessions) == "⌥⌘W")
        #expect(store.hintSuffix(for: .disconnect) == "")
        #expect(ShortcutAction.allCases.allSatisfy(store.isDefault))
    }

    @Test func assignmentsAndClearedShortcutsPersist() throws {
        let (store, defaults) = try makeStoreAndDefaults()
        store.assign(Shortcut(.character("d"), [.command, .shift]), to: .disconnect)
        store.assign(nil, to: .findInSession)
        // Assigning the default again drops the override.
        store.assign(Shortcut(.character("k"), [.command, .shift]), to: .quickConnect)

        let reloaded = ShortcutSettingsStore(defaults: defaults)
        #expect(reloaded.shortcut(for: .disconnect) == Shortcut(.character("d"), [.command, .shift]))
        #expect(reloaded.shortcut(for: .findInSession) == nil)
        #expect(!reloaded.isDefault(.findInSession))
        #expect(reloaded.isDefault(.quickConnect))

        reloaded.resetToDefault(.findInSession)
        #expect(ShortcutSettingsStore(defaults: defaults).shortcut(for: .findInSession) == Shortcut(.character("f"), [.command]))
        reloaded.resetAll()
        #expect(ShortcutSettingsStore(defaults: defaults).shortcut(for: .disconnect) == nil)
    }

    @Test func conflictsAreReportedForEveryCommandSharingAShortcut() throws {
        let store = try makeStore()
        store.assign(Shortcut(.character("k"), [.command]), to: .reconnect)
        #expect(store.conflicts(with: .reconnect) == [.commandPalette])
        #expect(store.conflicts(with: .commandPalette) == [.reconnect])
        #expect(store.conflicts(with: .disconnect).isEmpty)
    }

    @Test func shortcutsRoundTripThroughText() throws {
        for shortcut in [
            Shortcut(.character("w"), [.command, .shift]),
            Shortcut(.tab, [.control]),
            Shortcut(.character("+"), [.command]),
            Shortcut(.function(5), []),
            Shortcut(.pageDown, [.command, .option, .control, .shift]),
        ] {
            #expect(Shortcut(stringValue: shortcut.stringValue) == shortcut)
        }
        #expect(Shortcut(.character("w"), [.command, .shift]).stringValue == "shift+cmd+w")
        #expect(Shortcut(stringValue: "hyper+w") == nil)
        #expect(Shortcut(stringValue: "cmd+") == nil)
        #expect(Shortcut(stringValue: "cmd+enter") == nil)
    }

    @Test func keyPressesBecomeShortcuts() throws {
        let shiftW = try #require(Shortcut(event: keyEvent(keyCode: 0x0D, characters: "W", ignoringModifiers: "w", flags: [.command, .shift])))
        #expect(shiftW == Shortcut(.character("w"), [.command, .shift]))
        #expect(shiftW.displayString == "⇧⌘W")

        let controlTab = try #require(Shortcut(event: keyEvent(keyCode: 0x30, characters: "\t", ignoringModifiers: "\t", flags: [.control])))
        #expect(controlTab == Shortcut(.tab, [.control]))

        let f5 = try #require(Shortcut(event: keyEvent(keyCode: 0x60, characters: "\u{F708}", ignoringModifiers: "\u{F708}", flags: [])))
        #expect(f5 == Shortcut(.function(5), []))
        #expect(f5.problem == nil)

        // A control character with no known key code is not a shortcut.
        let control = try keyEvent(keyCode: 0x7F, characters: "\u{1}", ignoringModifiers: "\u{1}", flags: [.control])
        #expect(Shortcut(event: control) == nil)
    }

    @Test func reservedAndUnmodifiedShortcutsAreRejected() {
        #expect(Shortcut(.character("q"), [.command]).problem != nil)
        #expect(Shortcut(.character("c"), [.command]).problem != nil)
        #expect(Shortcut(.character("c"), [.command, .shift]).problem == nil)
        #expect(Shortcut(.character("x"), []).problem != nil)
        #expect(Shortcut(.character("x"), [.option]).problem != nil)
        #expect(Shortcut(.character("x"), [.control]).problem == nil)
    }

    private func makeStore() throws -> ShortcutSettingsStore {
        try makeStoreAndDefaults().0
    }

    private func makeStoreAndDefaults() throws -> (ShortcutSettingsStore, UserDefaults) {
        let suiteName = "ShortcutSettingsStoreTests-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defaults.removePersistentDomain(forName: suiteName)
        return (ShortcutSettingsStore(defaults: defaults), defaults)
    }

    private func keyEvent(keyCode: UInt16, characters: String, ignoringModifiers: String, flags: NSEvent.ModifierFlags) throws -> NSEvent {
        try #require(NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: flags, timestamp: 0, windowNumber: 0, context: nil,
            characters: characters, charactersIgnoringModifiers: ignoringModifiers, isARepeat: false, keyCode: keyCode))
    }
}
