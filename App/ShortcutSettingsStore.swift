// SPDX-FileCopyrightText: 2026 Nick Wolff <nick@wolff.tech>
// SPDX-License-Identifier: GPL-3.0-only

import AppKit
import Foundation
import Observation
import SwiftUI

/// A menu command whose shortcut the user may change. Select Tab 1–9 keep
/// their fixed ⌘-digit shortcuts and are not listed here.
enum ShortcutAction: String, CaseIterable, Codable, CodingKeyRepresentable, Identifiable, Sendable {
    case newMachine
    case quickConnect
    case connectDefaultProfile
    case closeSession
    case closeOtherSessions
    case closeWindow
    case reconnect
    case disconnect
    case nextTab
    case previousTab
    case findInSession
    case fitToWindow
    case actualSize

    var id: String { rawValue }

    var title: String {
        switch self {
        case .newMachine: "New Machine"
        case .quickConnect: "Quick Connect"
        case .connectDefaultProfile: "Connect Default Profile"
        case .closeSession: "Close Session"
        case .closeOtherSessions: "Close Other Sessions"
        case .closeWindow: "Close Window"
        case .reconnect: "Reconnect"
        case .disconnect: "Disconnect"
        case .nextTab: "Next Tab"
        case .previousTab: "Previous Tab"
        case .findInSession: "Find in Session"
        case .fitToWindow: "Fit to Window"
        case .actualSize: "Actual Size"
        }
    }

    /// The menu the command lives in; Settings groups rows by it.
    var menu: String {
        switch self {
        case .newMachine, .closeSession, .closeOtherSessions, .closeWindow: "File"
        case .fitToWindow, .actualSize: "View"
        case .quickConnect, .connectDefaultProfile, .reconnect, .disconnect, .nextTab, .previousTab, .findInSession: "Session"
        }
    }

    var defaultShortcut: Shortcut? {
        switch self {
        case .newMachine: Shortcut(.character("n"), [.command])
        case .quickConnect: Shortcut(.character("k"), [.command])
        case .connectDefaultProfile: Shortcut(.character("t"), [.command])
        case .closeSession: Shortcut(.character("w"), [.command])
        case .closeOtherSessions: Shortcut(.character("w"), [.command, .option])
        case .closeWindow: Shortcut(.character("w"), [.command, .shift])
        case .reconnect: Shortcut(.character("r"), [.command])
        case .disconnect: nil
        case .nextTab: Shortcut(.tab, [.control])
        case .previousTab: Shortcut(.tab, [.control, .shift])
        case .findInSession: Shortcut(.character("f"), [.command])
        case .fitToWindow, .actualSize: nil
        }
    }
}

/// A key plus modifiers, stored as text (`"cmd+shift+w"`, `"ctrl+tab"`).
struct Shortcut: Hashable, Sendable {
    enum Key: Hashable, Sendable {
        /// A printable key, stored lowercase.
        case character(Character)
        case tab, `return`, escape, delete, space
        case upArrow, downArrow, leftArrow, rightArrow
        case home, end, pageUp, pageDown
        case function(Int)
    }

    struct Modifiers: OptionSet, Hashable, Sendable {
        let rawValue: UInt8
        static let control = Modifiers(rawValue: 1 << 0)
        static let option = Modifiers(rawValue: 1 << 1)
        static let shift = Modifiers(rawValue: 1 << 2)
        static let command = Modifiers(rawValue: 1 << 3)
    }

    var key: Key
    var modifiers: Modifiers

    init(_ key: Key, _ modifiers: Modifiers) {
        self.key = key
        self.modifiers = modifiers
    }

    /// The shortcut a key press represents, or `nil` for a lone modifier or
    /// a key the menu system cannot bind.
    init?(event: NSEvent) {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        var modifiers = Modifiers()
        if flags.contains(.control) { modifiers.insert(.control) }
        if flags.contains(.option) { modifiers.insert(.option) }
        if flags.contains(.shift) { modifiers.insert(.shift) }
        if flags.contains(.command) { modifiers.insert(.command) }

        let key: Key
        switch Int(event.keyCode) {
        case 0x30: key = .tab
        case 0x24, 0x4C: key = .return
        case 0x35: key = .escape
        case 0x33, 0x75: key = .delete
        case 0x31: key = .space
        case 0x7E: key = .upArrow
        case 0x7D: key = .downArrow
        case 0x7B: key = .leftArrow
        case 0x7C: key = .rightArrow
        case 0x73: key = .home
        case 0x77: key = .end
        case 0x74: key = .pageUp
        case 0x79: key = .pageDown
        default:
            if let number = Self.functionKeyNumbers[Int(event.keyCode)] {
                key = .function(number)
            } else {
                // Ignoring modifiers gives the key cap (`w` for ⌘⇧W) rather
                // than the shifted character; Option-layered symbols are kept.
                guard let scalar = event.charactersIgnoringModifiers?.unicodeScalars.first,
                      scalar.value >= 0x20, scalar.value != 0x7F else { return nil }
                key = .character(Character(scalar).lowercased().first ?? Character(scalar))
            }
        }
        self.init(key, modifiers)
    }

    private static let functionKeyNumbers: [Int: Int] = [
        0x7A: 1, 0x78: 2, 0x63: 3, 0x76: 4, 0x60: 5, 0x61: 6, 0x62: 7, 0x64: 8,
        0x65: 9, 0x6D: 10, 0x67: 11, 0x6F: 12,
    ]

    /// Why a shortcut cannot be used, or `nil` when it can.
    var problem: String? {
        if Self.reserved.contains(self) {
            return "\(displayString) is reserved by macOS or the terminal."
        }
        if case .function = key { return nil }
        if modifiers.isDisjoint(with: [.command, .control]) {
            return "Include ⌘ or ⌃ so the shortcut does not take keys from the terminal."
        }
        return nil
    }

    /// Combinations the app must not steal: quitting, Settings, hiding, and
    /// the clipboard bindings the terminal handles itself.
    static let reserved: Set<Shortcut> = [
        Shortcut(.character("q"), [.command]),
        Shortcut(.character(","), [.command]),
        Shortcut(.character("h"), [.command]),
        Shortcut(.character("m"), [.command]),
        Shortcut(.character("c"), [.command]),
        Shortcut(.character("v"), [.command]),
        Shortcut(.character("x"), [.command]),
        Shortcut(.character("a"), [.command]),
        Shortcut(.character("z"), [.command]),
    ]

    /// Menu-style rendering, such as `⌃⇧⇥` or `⌘⇧W`.
    var displayString: String {
        var text = ""
        if modifiers.contains(.control) { text += "⌃" }
        if modifiers.contains(.option) { text += "⌥" }
        if modifiers.contains(.shift) { text += "⇧" }
        if modifiers.contains(.command) { text += "⌘" }
        let keyText: String = switch key {
        case .character(let character): String(character).uppercased()
        case .tab: "⇥"
        case .return: "↩"
        case .escape: "⎋"
        case .delete: "⌫"
        case .space: "Space"
        case .upArrow: "↑"
        case .downArrow: "↓"
        case .leftArrow: "←"
        case .rightArrow: "→"
        case .home: "↖"
        case .end: "↘"
        case .pageUp: "⇞"
        case .pageDown: "⇟"
        case .function(let number): "F\(number)"
        }
        return text + keyText
    }

    var keyboardShortcut: KeyboardShortcut {
        let equivalent: KeyEquivalent = switch key {
        case .character(let character): KeyEquivalent(character)
        case .tab: .tab
        case .return: .return
        case .escape: .escape
        case .delete: .delete
        case .space: .space
        case .upArrow: .upArrow
        case .downArrow: .downArrow
        case .leftArrow: .leftArrow
        case .rightArrow: .rightArrow
        case .home: .home
        case .end: .end
        case .pageUp: .pageUp
        case .pageDown: .pageDown
        case .function(let number): KeyEquivalent(Character(UnicodeScalar(0xF704 + number - 1)!))
        }
        var eventModifiers: EventModifiers = []
        if modifiers.contains(.control) { eventModifiers.insert(.control) }
        if modifiers.contains(.option) { eventModifiers.insert(.option) }
        if modifiers.contains(.shift) { eventModifiers.insert(.shift) }
        if modifiers.contains(.command) { eventModifiers.insert(.command) }
        return KeyboardShortcut(equivalent, modifiers: eventModifiers)
    }
}

extension Shortcut: Codable {
    private static let keyNames: [String: Key] = [
        "tab": .tab, "return": .return, "escape": .escape, "delete": .delete, "space": .space,
        "up": .upArrow, "down": .downArrow, "left": .leftArrow, "right": .rightArrow,
        "home": .home, "end": .end, "pageup": .pageUp, "pagedown": .pageDown,
    ]

    /// `ctrl+shift+tab`, `cmd+w`, `f5`. Modifiers come in a fixed order.
    var stringValue: String {
        var parts: [String] = []
        if modifiers.contains(.control) { parts.append("ctrl") }
        if modifiers.contains(.option) { parts.append("opt") }
        if modifiers.contains(.shift) { parts.append("shift") }
        if modifiers.contains(.command) { parts.append("cmd") }
        let keyText: String = switch key {
        case .character(let character): String(character)
        case .function(let number): "f\(number)"
        default: Self.keyNames.first { $0.value == key }?.key ?? ""
        }
        return (parts + [keyText]).joined(separator: "+")
    }

    init?(stringValue: String) {
        var parts = stringValue.split(separator: "+", omittingEmptySubsequences: false).map(String.init)
        // A trailing "+" is the plus key itself.
        if parts.count >= 2, parts.last == "", parts[parts.count - 2] == "" {
            parts.removeLast(2)
            parts.append("+")
        }
        guard let last = parts.popLast(), !last.isEmpty else { return nil }
        var modifiers = Modifiers()
        for part in parts {
            switch part {
            case "ctrl": modifiers.insert(.control)
            case "opt": modifiers.insert(.option)
            case "shift": modifiers.insert(.shift)
            case "cmd": modifiers.insert(.command)
            default: return nil
            }
        }
        let key: Key
        if let named = Self.keyNames[last] {
            key = named
        } else if last.count > 1, last.hasPrefix("f"), let number = Int(last.dropFirst()), (1...12).contains(number) {
            key = .function(number)
        } else if last.count == 1, let character = last.first {
            key = .character(character)
        } else {
            return nil
        }
        self.init(key, modifiers)
    }

    init(from decoder: any Decoder) throws {
        let text = try decoder.singleValueContainer().decode(String.self)
        guard let shortcut = Shortcut(stringValue: text) else {
            throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "Unknown shortcut \(text)"))
        }
        self = shortcut
    }

    func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(stringValue)
    }
}

/// The user's shortcut assignments. Only departures from the defaults are
/// stored, so a new default in a later release reaches everyone who did not
/// change that command.
@MainActor
@Observable
final class ShortcutSettingsStore {
    private static let defaultsKey = "shortcutAssignments"

    /// `nil` inside the optional records a deliberately cleared shortcut.
    private(set) var overrides: [ShortcutAction: Shortcut?]

    @ObservationIgnored
    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        if let data = defaults.data(forKey: Self.defaultsKey),
           let decoded = try? JSONDecoder().decode([ShortcutAction: Shortcut?].self, from: data) {
            overrides = decoded
        } else {
            overrides = [:]
        }
    }

    func shortcut(for action: ShortcutAction) -> Shortcut? {
        if let override = overrides[action] { override } else { action.defaultShortcut }
    }

    func keyboardShortcut(for action: ShortcutAction) -> KeyboardShortcut? {
        shortcut(for: action)?.keyboardShortcut
    }

    /// The shortcut in menu notation for tooltips and hints, or `nil` when unassigned.
    func hint(for action: ShortcutAction) -> String? {
        shortcut(for: action)?.displayString
    }

    /// `" (⌘N)"` for appending to a tooltip, or `""` when unassigned.
    func hintSuffix(for action: ShortcutAction) -> String {
        hint(for: action).map { " (\($0))" } ?? ""
    }

    func isDefault(_ action: ShortcutAction) -> Bool {
        overrides[action] == nil
    }

    /// Assigns a shortcut, or clears it with `nil`. Conflicts are allowed and
    /// reported by `conflicts(with:)`; validity is the caller's check.
    func assign(_ shortcut: Shortcut?, to action: ShortcutAction) {
        if shortcut == action.defaultShortcut {
            overrides.removeValue(forKey: action)
        } else {
            overrides[action] = .some(shortcut)
        }
        save()
    }

    func resetToDefault(_ action: ShortcutAction) {
        overrides.removeValue(forKey: action)
        save()
    }

    func resetAll() {
        overrides = [:]
        save()
    }

    /// Other commands currently using the same shortcut as `action`.
    func conflicts(with action: ShortcutAction) -> [ShortcutAction] {
        guard let shortcut = shortcut(for: action) else { return [] }
        return ShortcutAction.allCases.filter { $0 != action && self.shortcut(for: $0) == shortcut }
    }

    private func save() {
        guard let data = try? JSONEncoder().encode(overrides) else { return }
        defaults.set(data, forKey: Self.defaultsKey)
    }
}
