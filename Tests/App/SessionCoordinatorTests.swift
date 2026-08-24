import AppKit
import ConstellationCore
import ConstellationOpenSSH
import ConstellationStorage
import ConstellationTerminal
import Testing
@testable import Constellation

@MainActor
struct SessionCoordinatorTests {
    @Test func probesInPriorityOrderAndStartsSSHOnce() async throws {
        let library = try GRDBMachineLibrary.inMemory()
        let machine = Machine(name: "box")
        let slow = MachineAddress(machineID: machine.id, label: "VPN", host: "vpn.box", kind: .vpn, priority: 1)
        let lan = MachineAddress(machineID: machine.id, label: "LAN", host: "lan.box", kind: .lan, priority: 0)
        let profile = SSHProfile(machineID: machine.id, username: "nick", port: 2222)
        try await library.save(.batch([
            .upsertMachine(machine), .upsertAddress(slow), .upsertAddress(lan), .upsertProfile(.ssh(profile)),
        ]))
        let prober = StubProber(results: ["lan.box": false, "vpn.box": true])
        let driver = StubSSHDriver()
        let coordinator = SessionCoordinator(library: library, prober: prober, driver: driver)

        let id = try await coordinator.open(profileID: profile.id)

        #expect(await prober.hosts == ["lan.box", "vpn.box"])
        #expect(driver.requests.count == 1)
        #expect(driver.requests[0].destination.host == "vpn.box")
        #expect(driver.requests[0].hostKeyAlias == "constellation-\(machine.id)")
        let session = try #require(driver.sessions.last)
        #expect(coordinator.sessions.first(where: { $0.id == id })?.state.isConnecting == true)
        session.terminal.emit(.titleChanged("constellation-connected:\(session.exitStatusChannel.token)"))
        #expect(coordinator.sessions.first(where: { $0.id == id })?.state.isConnected == true)
        #expect(coordinator.count(for: machine.id) == 1)
        #expect(coordinator.count(forProfile: profile.id) == 1)
        #expect(coordinator.count(forProfile: ProfileID()) == 0)
    }

    @Test func pinnedProfilesNeverProbeFallbackAddresses() async throws {
        let library = try GRDBMachineLibrary.inMemory()
        let machine = Machine(name: "box")
        let pinned = MachineAddress(machineID: machine.id, label: "LAN", host: "lan.box", priority: 0)
        let fallback = MachineAddress(machineID: machine.id, label: "VPN", host: "vpn.box", priority: 1)
        let profile = SSHProfile(machineID: machine.id, addressSelection: .pinned(pinned.id))
        try await library.save(.batch([
            .upsertMachine(machine), .upsertAddress(pinned), .upsertAddress(fallback), .upsertProfile(.ssh(profile)),
        ]))
        let prober = StubProber(results: ["lan.box": false, "vpn.box": true])
        let driver = StubSSHDriver()
        let coordinator = SessionCoordinator(library: library, prober: prober, driver: driver)

        let id = try await coordinator.open(profileID: profile.id)

        #expect(await prober.hosts == ["lan.box"])
        #expect(driver.requests.isEmpty)
        #expect(coordinator.sessions.first(where: { $0.id == id })?.state == .failed(.unreachable))
    }

    @Test func realExitStatusBeatsLoginWrapperStatus() async throws {
        let (coordinator, _, profile, driver) = try await coordinatorWithOneMachine()
        let id = try await coordinator.open(profileID: profile.id)
        let session = try #require(driver.sessions.last)

        session.terminal.emit(.titleChanged("constellation-exit:\(session.exitStatusChannel.token):255"))
        session.terminal.emit(.processExited(code: 0, runtime: .seconds(1)))

        #expect(coordinator.sessions.first(where: { $0.id == id })?.state == .failed(.sshExited(255)))
        #expect(session.didFinish)
    }

    @Test func restoresSavedTabsDisconnectedAndExcludesQuickConnect() async throws {
        let (coordinator, library, profile, _) = try await coordinatorWithOneMachine()
        let savedID = try await coordinator.open(profileID: profile.id)
        _ = await coordinator.openQuickConnect(QuickConnectTarget(host: "quick.box"))
        try await coordinator.persistWorkspace()

        let snapshot = try await library.snapshot()
        #expect(snapshot.workspaceTabs.map(\.id) == [savedID])

        let restored = SessionCoordinator(library: library, prober: StubProber(), driver: StubSSHDriver())
        restored.restoreWorkspace(from: snapshot)
        #expect(restored.sessions.count == 1)
        #expect(restored.sessions[0].id == savedID)
        #expect(restored.sessions[0].state == .disconnected)
        #expect(restored.terminal(for: savedID) == nil)
    }

    @Test func quickConnectCanBecomeASavedMachine() async throws {
        let library = try GRDBMachineLibrary.inMemory()
        let coordinator = SessionCoordinator(
            library: library,
            prober: StubProber(),
            driver: StubSSHDriver())
        let sessionID = await coordinator.openQuickConnect(
            QuickConnectTarget(host: "new.box", username: "nick", port: 2222))

        let machineID = try await coordinator.saveQuickConnect(sessionID: sessionID, machineName: "New Box")
        try await coordinator.persistWorkspace()

        let snapshot = try await library.snapshot()
        #expect(snapshot.machine(machineID)?.name == "New Box")
        #expect(snapshot.addresses(for: machineID).first?.host == "new.box")
        #expect(snapshot.profiles(for: machineID).first?.username == "nick")
        #expect(snapshot.workspaceTabs.map(\.id) == [sessionID])
    }

    @Test func tabSelectionCyclingAndReorderingAreStable() async throws {
        let library = try GRDBMachineLibrary.inMemory()
        let coordinator = SessionCoordinator(
            library: library,
            prober: StubProber(),
            driver: StubSSHDriver())
        let one = await coordinator.openQuickConnect(QuickConnectTarget(host: "one"))
        let two = await coordinator.openQuickConnect(QuickConnectTarget(host: "two"))
        let three = await coordinator.openQuickConnect(QuickConnectTarget(host: "three"))

        coordinator.select(number: 1)
        #expect(coordinator.selectedSessionID == one)
        coordinator.cycleSelection()
        #expect(coordinator.selectedSessionID == two)
        coordinator.cycleSelection(reverse: true)
        #expect(coordinator.selectedSessionID == one)
        coordinator.move(sessionID: three, before: one)
        #expect(coordinator.sessions.map(\.id) == [three, one, two])
    }

    @Test func closingOthersAsksFirstWhenAnotherSessionIsLive() async throws {
        let (coordinator, _, profile, driver) = try await coordinatorWithOneMachine()
        let keep = try await coordinator.open(profileID: profile.id)
        let live = try await coordinator.open(profileID: profile.id)
        let idle = await coordinator.openQuickConnect(QuickConnectTarget(host: "idle"))
        coordinator.disconnect(sessionID: idle)

        coordinator.requestCloseOthers(keeping: keep)
        #expect(coordinator.pendingClose == .others(keeping: keep))
        #expect(coordinator.sessions.map(\.id) == [keep, live, idle])

        coordinator.confirmPendingClose()
        #expect(coordinator.pendingClose == nil)
        #expect(coordinator.sessions.map(\.id) == [keep])
        #expect(coordinator.selectedSessionID == keep)
        #expect(driver.sessions[1].terminal.isClosed)
    }

    @Test func closingOthersSkipsConfirmationWhenNothingIsLive() async throws {
        let (coordinator, _, profile, _) = try await coordinatorWithOneMachine()
        let keep = try await coordinator.open(profileID: profile.id)
        let idle = await coordinator.openQuickConnect(QuickConnectTarget(host: "idle"))
        coordinator.disconnect(sessionID: idle)

        coordinator.requestCloseOthers(keeping: keep)
        #expect(coordinator.pendingClose == nil)
        #expect(coordinator.sessions.map(\.id) == [keep])
    }

    @Test func openingDefaultProfileFailsClearlyWithoutProfiles() async throws {
        let library = try GRDBMachineLibrary.inMemory()
        let machine = Machine(name: "bare")
        try await library.save(.upsertMachine(machine))
        let coordinator = SessionCoordinator(library: library, prober: StubProber(), driver: StubSSHDriver())

        await #expect(throws: SessionCoordinatorError.noProfiles(machine.id)) {
            try await coordinator.openDefaultProfile(for: machine.id)
        }
        #expect(coordinator.sessions.isEmpty)
    }

    @Test func openingDefaultProfilePrefersTheMarkedDefault() async throws {
        let library = try GRDBMachineLibrary.inMemory()
        let first = ProfileID()
        let preferred = ProfileID()
        let machine = Machine(name: "box", defaultProfileID: preferred)
        let address = MachineAddress(machineID: machine.id, label: "LAN", host: "box.local")
        try await library.save(.batch([
            .upsertMachine(machine), .upsertAddress(address),
            .upsertProfile(.ssh(SSHProfile(id: first, machineID: machine.id, name: "first", username: "a"))),
            .upsertProfile(.ssh(SSHProfile(id: preferred, machineID: machine.id, name: "preferred", username: "b"))),
        ]))
        let driver = StubSSHDriver()
        let coordinator = SessionCoordinator(library: library, prober: StubProber(results: ["box.local": true]), driver: driver)

        let id = try await coordinator.openDefaultProfile(for: machine.id)

        #expect(coordinator.sessions.first(where: { $0.id == id })?.profileName == "preferred")
        #expect(driver.requests.first?.destination.user == "b")
    }

    private func coordinatorWithOneMachine() async throws -> (SessionCoordinator, GRDBMachineLibrary, SSHProfile, StubSSHDriver) {
        let library = try GRDBMachineLibrary.inMemory()
        let machine = Machine(name: "box")
        let address = MachineAddress(machineID: machine.id, label: "LAN", host: "box.local")
        let profile = SSHProfile(machineID: machine.id)
        try await library.save(.batch([.upsertMachine(machine), .upsertAddress(address), .upsertProfile(.ssh(profile))]))
        let driver = StubSSHDriver()
        return (
            SessionCoordinator(library: library, prober: StubProber(results: ["box.local": true]), driver: driver),
            library,
            profile,
            driver)
    }
}

private extension SessionState {
    var isConnected: Bool {
        if case .connected = self { true } else { false }
    }

    var isConnecting: Bool {
        if case .connecting = self { true } else { false }
    }
}

private actor StubProber: AddressProbing {
    private let results: [String: Bool]
    private(set) var hosts: [String] = []

    init(results: [String: Bool] = [:]) {
        self.results = results
    }

    func canConnect(host: String, port: Int, timeout: Duration) async -> Bool {
        hosts.append(host)
        return results[host] ?? false
    }
}

@MainActor
private final class StubSSHDriver: SSHSessionDriving {
    private(set) var requests: [SSHSessionRequest] = []
    private(set) var sessions: [StubDriverSession] = []

    func start(_ request: SSHSessionRequest) throws -> SSHDriverSession {
        requests.append(request)
        let terminal = StubTerminal()
        let channel = SSHExitStatusChannel()
        let tracked = StubDriverSession(terminal: terminal, exitStatusChannel: channel)
        sessions.append(tracked)
        return SSHDriverSession(terminal: terminal, exitStatusChannel: channel) { tracked.didFinish = true }
    }
}

@MainActor
private final class StubDriverSession {
    let terminal: StubTerminal
    let exitStatusChannel: SSHExitStatusChannel
    var didFinish = false

    init(terminal: StubTerminal, exitStatusChannel: SSHExitStatusChannel) {
        self.terminal = terminal
        self.exitStatusChannel = exitStatusChannel
    }
}

@MainActor
private final class StubTerminal: TerminalSession {
    let view = NSView()
    var title = ""
    var processState = TerminalProcessState.running
    var eventHandler: (@MainActor (TerminalEvent) -> Void)?
    private(set) var isClosed = false

    func send(_ input: TerminalInput) {}
    func performBinding(_ action: String) -> Bool { true }
    func close() { isClosed = true }
    func emit(_ event: TerminalEvent) { eventHandler?(event) }
}
