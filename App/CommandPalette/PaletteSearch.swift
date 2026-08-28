// SPDX-FileCopyrightText: 2026 Nick Wolff <nick@wolff.tech>
// SPDX-License-Identifier: GPL-3.0-only

import ConstellationCore
import Foundation

/// One row in the command palette.
struct PaletteItem: Identifiable, Equatable {
    enum Kind: Equatable {
        case session(SessionID)
        case profile(ProfileID)
        case command(ShortcutAction)
        case settings
        case quickConnect(QuickConnectTarget)
    }

    /// Rows are grouped in this order, whatever their scores.
    enum Section: Int, Comparable, CaseIterable {
        case sessions, machines, commands, quickConnect

        var title: String {
            switch self {
            case .sessions: "Open Sessions"
            case .machines: "Machines"
            case .commands: "Commands"
            case .quickConnect: "Quick Connect"
            }
        }

        static func < (lhs: Self, rhs: Self) -> Bool { lhs.rawValue < rhs.rawValue }
    }

    let kind: Kind
    let title: String
    let subtitle: String
    let symbolName: String
    /// Right-aligned text: a shortcut hint or a session state.
    let detail: String?

    var section: Section {
        switch kind {
        case .session: .sessions
        case .profile: .machines
        case .command, .settings: .commands
        case .quickConnect: .quickConnect
        }
    }

    var id: String {
        switch kind {
        case .session(let id): "session:\(id)"
        case .profile(let id): "profile:\(id)"
        case .command(let action): "command:\(action.rawValue)"
        case .settings: "settings"
        case .quickConnect(let target): "quick:\(target.displayName)"
        }
    }
}

/// Builds the palette's rows for a query. Pure over its inputs so ranking is testable.
@MainActor
struct PaletteSearch {
    var snapshot: MachineLibrarySnapshot
    var sessions: [SessionSummary]
    var isEnabled: (ShortcutAction) -> Bool
    var shortcutHint: (ShortcutAction) -> String?

    /// How many machine rows an empty query shows when nothing is a favorite.
    static let browseLimit = 12

    func items(for query: String) -> [PaletteItem] {
        let terms = query.split(whereSeparator: \.isWhitespace).map { $0.lowercased() }
        return terms.isEmpty ? browse() : search(terms, rawQuery: query)
    }

    /// Empty query: every open session, the favorites (or the first machines), then every command.
    private func browse() -> [PaletteItem] {
        var items = sessions.map(sessionItem)
        let favorites = snapshot.machines.filter(\.isFavorite)
        let machines = favorites.isEmpty ? Array(snapshot.machines.prefix(Self.browseLimit)) : favorites
        for machine in machines {
            for profile in snapshot.orderedProfiles(for: machine) {
                items.append(profileItem(profile, of: machine))
            }
        }
        items += commandItems()
        return items
    }

    private func search(_ terms: [String], rawQuery: String) -> [PaletteItem] {
        var scored: [(item: PaletteItem, score: Int, order: Int)] = []
        func consider(_ item: PaletteItem, haystack: [String], bonus: Int = 0) {
            guard let score = FuzzyMatch.score(terms, in: haystack) else { return }
            scored.append((item, score + bonus, scored.count))
        }

        for session in sessions {
            consider(sessionItem(session), haystack: [
                session.title, session.machineName ?? "", session.profileName,
                session.protocolKind.displayName, session.endpoint?.host ?? "",
            ])
        }
        for machine in snapshot.machines {
            let hosts = snapshot.addresses(for: machine.id).map(\.host)
            for profile in snapshot.orderedProfiles(for: machine) {
                var bonus = machine.isFavorite ? 3 : 0
                if sessions.contains(where: { $0.profileID == profile.id }) { bonus += 2 }
                consider(
                    profileItem(profile, of: machine),
                    haystack: [machine.name, profile.name, profile.protocolKind.displayName] + Array(machine.tags) + hosts,
                    bonus: bonus)
            }
        }
        for item in commandItems() {
            let menu: String = if case .command(let action) = item.kind { action.menu } else { "Preferences" }
            consider(item, haystack: [item.title, menu])
        }

        var items = scored
            .sorted { ($0.item.section, $1.score, $0.order) < ($1.item.section, $0.score, $1.order) }
            .map(\.item)

        // Offer Quick Connect when the text looks like an address, or when
        // nothing else matched and it parses as one.
        let looksLikeAddress = rawQuery.contains { "@:.".contains($0) }
        if looksLikeAddress || items.isEmpty, terms.count == 1, let target = try? QuickConnectTarget(parsing: rawQuery) {
            items.append(PaletteItem(
                kind: .quickConnect(target), title: "Quick Connect to \(target.displayName)",
                subtitle: "SSH using your agent or OpenSSH configuration", symbolName: "bolt.horizontal", detail: nil))
        }
        return items
    }

    private func sessionItem(_ session: SessionSummary) -> PaletteItem {
        var subtitle = session.profileName
        if let host = session.endpoint?.host { subtitle += " · \(host)" }
        return PaletteItem(
            kind: .session(session.id), title: session.title, subtitle: subtitle,
            symbolName: session.protocolKind.symbolName, detail: session.state.displayName)
    }

    private func profileItem(_ profile: ConnectionProfile, of machine: Machine) -> PaletteItem {
        var parts = [profile.name]
        if profile.name != profile.protocolKind.displayName { parts.append(profile.protocolKind.displayName) }
        let addresses = snapshot.addresses(for: machine.id)
        let host: String? = switch profile.addressSelection {
        case .pinned(let id): addresses.first { $0.id == id }?.host ?? addresses.first?.host
        case .automatic: addresses.first?.host
        }
        if let host { parts.append(host) }
        return PaletteItem(
            kind: .profile(profile.id), title: machine.name, subtitle: parts.joined(separator: " · "),
            symbolName: profile.protocolKind.symbolName, detail: machine.isFavorite ? "★" : nil)
    }

    /// Every enabled command except the palette itself, then Settings.
    private func commandItems() -> [PaletteItem] {
        var items = ShortcutAction.allCases
            .filter { $0 != .commandPalette && isEnabled($0) }
            .map { action in
                PaletteItem(
                    kind: .command(action), title: action.menuTitle, subtitle: action.menu,
                    symbolName: "command", detail: shortcutHint(action))
            }
        items.append(PaletteItem(kind: .settings, title: "Settings…", subtitle: "Constellation", symbolName: "gearshape", detail: "⌘,"))
        return items
    }
}

enum FuzzyMatch {
    /// Sum of each term's best match across `haystack`, or `nil` when a term
    /// matches nothing. Terms are lowercase.
    static func score(_ terms: [String], in haystack: [String]) -> Int? {
        let lowered = haystack.map { $0.lowercased() }
        var total = 0
        for term in terms {
            guard let best = lowered.compactMap({ score(term, in: $0) }).max() else { return nil }
            total += best
        }
        return total
    }

    /// Prefix beats word start beats substring beats scattered subsequence.
    /// Single characters only match as substrings; a subsequence of one
    /// character would match nearly everything.
    static func score(_ term: String, in text: String) -> Int? {
        if text.hasPrefix(term) { return 100 }
        let words = text.split { !$0.isLetter && !$0.isNumber }
        if words.contains(where: { $0.hasPrefix(term) }) { return 80 }
        if text.contains(term) { return 60 }
        guard term.count >= 2 else { return nil }
        var remaining = term[...]
        for character in text where character == remaining.first {
            remaining = remaining.dropFirst()
            if remaining.isEmpty { return 30 }
        }
        return nil
    }
}
