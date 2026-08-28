// SPDX-FileCopyrightText: 2026 Nick Wolff <nick@wolff.tech>
// SPDX-License-Identifier: GPL-3.0-only

import ConstellationCore
import Testing
@testable import Constellation

@MainActor
struct PaletteSearchTests {
    let web = Machine(name: "web-01", tags: ["prod"], isFavorite: true)
    let build = Machine(name: "build box", tags: ["lab"])
    let webSSH: ConnectionProfile
    let webRDP: ConnectionProfile
    let buildSSH: ConnectionProfile
    let snapshot: MachineLibrarySnapshot
    let buildSession: SessionSummary

    init() {
        webSSH = .ssh(SSHProfile(machineID: web.id))
        webRDP = .rdp(RDPProfile(machineID: web.id, name: "Desktop"))
        buildSSH = .ssh(SSHProfile(machineID: build.id))
        snapshot = MachineLibrarySnapshot(
            machines: [web, build],
            addresses: [
                MachineAddress(machineID: web.id, label: "", host: "192.0.2.10"),
                MachineAddress(machineID: build.id, label: "Tailscale", host: "build.tail.net", kind: .tailscale),
            ],
            profiles: [webSSH, webRDP, buildSSH])
        buildSession = SessionSummary(
            id: SessionID(), target: .saved(machineID: build.id, profileID: buildSSH.id), title: "build box",
            machineName: "build box", profileName: "SSH", state: .disconnected)
    }

    private func search(sessions: [SessionSummary] = [], disabled: Set<ShortcutAction> = []) -> PaletteSearch {
        PaletteSearch(
            snapshot: snapshot, sessions: sessions,
            isEnabled: { !disabled.contains($0) },
            shortcutHint: { $0 == .newMachine ? "⌘N" : nil })
    }

    @Test func emptyQueryListsSessionsThenFavoritesThenCommands() {
        let items = search(sessions: [buildSession], disabled: [.disconnect]).items(for: "")
        #expect(items.map(\.section) == items.map(\.section).sorted())
        #expect(items.first?.section == .sessions)
        // Profiles follow the sidebar order: default first, then by name.
        let machines = items.filter { $0.section == .machines }
        #expect(machines.map(\.kind) == [.profile(webRDP.id), .profile(webSSH.id)])
        #expect(items.contains { $0.kind == .command(.newMachine) && $0.detail == "⌘N" })
        #expect(!items.contains { $0.kind == .command(.disconnect) })
        #expect(!items.contains { $0.kind == .command(.commandPalette) })
        #expect(items.last?.kind == .settings)
        #expect(!items.contains { if case .quickConnect = $0.kind { true } else { false } })
    }

    @Test func emptyQueryFallsBackToEveryMachineWithoutFavorites() {
        var snapshot = snapshot
        snapshot.machines[0].isFavorite = false
        let items = PaletteSearch(snapshot: snapshot, sessions: [], isEnabled: { _ in true }, shortcutHint: { _ in nil }).items(for: "")
        #expect(items.filter { $0.section == .machines }.count == 3)
    }

    @Test func termsMatchNamesTagsHostsProfilesAndProtocols() {
        let search = search()
        #expect(search.items(for: "web").filter { $0.section == .machines }.count == 2)
        #expect(search.items(for: "prod").filter { $0.section == .machines }.count == 2)
        #expect(search.items(for: "tail").filter { $0.section == .machines }.map(\.kind) == [.profile(buildSSH.id)])
        #expect(search.items(for: "desktop").filter { $0.section == .machines }.map(\.kind) == [.profile(webRDP.id)])
        #expect(search.items(for: "web rdp").filter { $0.section == .machines }.map(\.kind) == [.profile(webRDP.id)])
        #expect(search.items(for: "web rdp lab").filter { $0.section == .machines }.isEmpty)
    }

    @Test func rankingPrefersPrefixesThenFavorites() {
        var snapshot = snapshot
        let alsoWeb = Machine(name: "old web")
        snapshot.machines.append(alsoWeb)
        let alsoWebSSH = ConnectionProfile.ssh(SSHProfile(machineID: alsoWeb.id))
        snapshot.profiles.append(alsoWebSSH)
        let search = PaletteSearch(snapshot: snapshot, sessions: [], isEnabled: { _ in true }, shortcutHint: { _ in nil })

        let byPrefix = search.items(for: "we").filter { $0.section == .machines }.map(\.kind)
        #expect(byPrefix == [.profile(webRDP.id), .profile(webSSH.id), .profile(alsoWebSSH.id)])

        // "ssh" matches every SSH profile equally; the favorite wins the tie.
        let tied = search.items(for: "ssh").filter { $0.section == .machines }.map(\.kind)
        #expect(tied.first == .profile(webSSH.id))
        #expect(FuzzyMatch.score("bb", in: "build box") == 30)
        #expect(FuzzyMatch.score("b", in: "web") == 60)
        #expect(FuzzyMatch.score("x", in: "web") == nil)
    }

    @Test func sessionsAndCommandsMatchTheirOwnText() {
        let items = search(sessions: [buildSession]).items(for: "build")
        #expect(items.first?.kind == .session(buildSession.id))
        #expect(items.first?.detail == "Disconnected")
        let commands = search().items(for: "close").filter { $0.section == .commands }.map(\.kind)
        #expect(commands == [.command(.closeSession), .command(.closeOtherSessions), .command(.closeWindow)])
        #expect(search().items(for: "prefer").map(\.kind) == [.settings])
    }

    @Test func quickConnectIsOfferedForAddressesAndAsALastResort() {
        let search = search()
        let address = search.items(for: "root@10.0.0.5:2222")
        #expect(address.count == 1)
        #expect(address.first?.kind == .quickConnect(QuickConnectTarget(host: "10.0.0.5", username: "root", port: 2222)))

        // "web" has matches, so no Quick Connect row; "zeta" has none.
        #expect(!search.items(for: "web").contains { $0.section == .quickConnect })
        #expect(search.items(for: "zeta").map(\.kind) == [.quickConnect(QuickConnectTarget(host: "zeta"))])
        #expect(search.items(for: "not a host").isEmpty)
    }
}
