// SPDX-FileCopyrightText: 2026 Nick Wolff <nick@wolff.tech>
// SPDX-License-Identifier: GPL-3.0-only

import AppKit
import ConstellationCore
import ConstellationOpenSSH
import ConstellationStorage
import ConstellationRemoteDesktop
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

    @Test func vncProfilesConnectThroughTheRemoteDesktopDriver() async throws {
        let (coordinator, library, machine, vncDriver) = try await coordinatorWithVNCMachine()
        let profile = try #require(await library.snapshot().profiles(for: machine.id).first)

        let id = try await coordinator.open(profileID: profile.id)

        let session = try #require(vncDriver.sessions.last)
        #expect(vncDriver.requests.last == VNCSessionRequest(
            host: "vnc.box", port: 5901, username: "nick", credentialID: nil, sharesClipboard: true, machineName: "screen"))
        #expect(session.connectCalls == 1)
        #expect(coordinator.remoteDesktop(for: id) != nil)
        #expect(coordinator.terminal(for: id) == nil)
        #expect(coordinator.sessions.first?.endpoint == SessionEndpoint(host: "vnc.box", port: 5901))
        #expect(coordinator.sessions.first?.protocolKind == .vnc)

        session.emit(.stateChanged(.connected))
        #expect(coordinator.sessions.first?.state.isConnected == true)
        #expect(coordinator.count(forProfile: profile.id) == 1)

        coordinator.disconnect(sessionID: id)
        #expect(coordinator.sessions.first?.state == .disconnecting)
        #expect(session.disconnectCalls == 1)
        session.emit(.stateChanged(.disconnected(nil)))
        #expect(coordinator.sessions.first?.state == .disconnected)
        #expect(coordinator.remoteDesktop(for: id) == nil)
    }

    @Test func vncAuthenticationFailuresAreReportedAsSuch() async throws {
        let (coordinator, library, machine, vncDriver) = try await coordinatorWithVNCMachine()
        let profile = try #require(await library.snapshot().profiles(for: machine.id).first)
        _ = try await coordinator.open(profileID: profile.id)
        let session = try #require(vncDriver.sessions.last)

        session.emit(.stateChanged(.disconnected(RemoteDesktopSessionFailure(message: "Authentication failed.", isAuthenticationFailure: true))))

        #expect(coordinator.sessions.first?.state == .failed(.authenticationFailed("Authentication failed.")))
        #expect(coordinator.sessions.first?.state.hasLiveProcess == false)
    }

    @Test func displayModeReachesTheRemoteDesktop() async throws {
        let (coordinator, library, machine, vncDriver) = try await coordinatorWithVNCMachine()
        let profile = try #require(await library.snapshot().profiles(for: machine.id).first)
        let id = try await coordinator.open(profileID: profile.id)
        let session = try #require(vncDriver.sessions.last)

        coordinator.setDisplayMode(.actualSize, for: id)

        #expect(session.displayMode == .actualSize)
        #expect(coordinator.sessions.first?.displayMode == .actualSize)
    }

    @Test func vncWithoutADriverFailsClearly() async throws {
        let library = try GRDBMachineLibrary.inMemory()
        let machine = Machine(name: "screen")
        let address = MachineAddress(machineID: machine.id, label: "", host: "vnc.box")
        let profile = VNCProfile(machineID: machine.id)
        try await library.save(.batch([.upsertMachine(machine), .upsertAddress(address), .upsertProfile(.vnc(profile))]))
        let coordinator = SessionCoordinator(library: library, prober: StubProber(results: ["vnc.box": true]), driver: StubSSHDriver())

        _ = try await coordinator.open(profileID: profile.id)

        #expect(coordinator.sessions.first?.state == .failed(.unsupportedProtocol(.vnc)))
    }

    @Test func rdpProfilesConnectThroughTheirOwnDriver() async throws {
        let library = try GRDBMachineLibrary.inMemory()
        let machine = Machine(name: "win")
        let address = MachineAddress(machineID: machine.id, label: "", host: "win.box")
        let credential = CredentialReference(label: "win · RDP RDP password", kind: .password)
        let profile = RDPProfile(machineID: machine.id, username: "nick", domain: "CORP", port: 3390, credentialID: credential.id, sharesClipboard: true)
        try await library.save(.batch([
            .upsertMachine(machine), .upsertAddress(address), .upsertCredential(credential), .upsertProfile(.rdp(profile)),
        ]))
        let rdpDriver = StubRDPDriver()
        let coordinator = SessionCoordinator(
            library: library,
            prober: StubProber(results: ["win.box": true]),
            driver: StubSSHDriver(),
            rdpDriver: rdpDriver)

        let id = try await coordinator.open(profileID: profile.id)

        #expect(rdpDriver.requests.last == RDPSessionRequest(
            host: "win.box", port: 3390, username: "nick", domain: "CORP", credentialID: credential.id, sharesClipboard: true, machineName: "win"))
        let session = try #require(rdpDriver.sessions.last)
        #expect(session.connectCalls == 1)
        #expect(coordinator.isRemoteDesktop(id))
        #expect(coordinator.sessions.first?.protocolKind == .rdp)
        session.emit(.stateChanged(.connected))
        #expect(coordinator.sessions.first?.state.isConnected == true)
        session.emit(.stateChanged(.disconnected(RemoteDesktopSessionFailure(message: "Authentication failed.", isAuthenticationFailure: true))))
        #expect(coordinator.sessions.first?.state == .failed(.authenticationFailed("Authentication failed.")))
    }

    @Test func cancellingTheRDPCredentialPromptLeavesTheTabDisconnected() async throws {
        let library = try GRDBMachineLibrary.inMemory()
        let machine = Machine(name: "win")
        let address = MachineAddress(machineID: machine.id, label: "", host: "win.box")
        let profile = RDPProfile(machineID: machine.id)
        try await library.save(.batch([.upsertMachine(machine), .upsertAddress(address), .upsertProfile(.rdp(profile))]))
        let rdpDriver = StubRDPDriver(cancels: true)
        let coordinator = SessionCoordinator(
            library: library,
            prober: StubProber(results: ["win.box": true]),
            driver: StubSSHDriver(),
            rdpDriver: rdpDriver)

        _ = try await coordinator.open(profileID: profile.id)

        #expect(coordinator.sessions.first?.state == .disconnected)
        #expect(rdpDriver.sessions.isEmpty)
    }

    @Test func rdpWithoutADriverFailsClearly() async throws {
        let library = try GRDBMachineLibrary.inMemory()
        let machine = Machine(name: "win")
        let address = MachineAddress(machineID: machine.id, label: "", host: "win.box")
        let profile = RDPProfile(machineID: machine.id)
        try await library.save(.batch([.upsertMachine(machine), .upsertAddress(address), .upsertProfile(.rdp(profile))]))
        let coordinator = SessionCoordinator(library: library, prober: StubProber(results: ["win.box": true]), driver: StubSSHDriver())

        _ = try await coordinator.open(profileID: profile.id)

        #expect(coordinator.sessions.first?.state == .failed(.unsupportedProtocol(.rdp)))
    }

    private func coordinatorWithVNCMachine() async throws -> (SessionCoordinator, GRDBMachineLibrary, Machine, StubVNCDriver) {
        let library = try GRDBMachineLibrary.inMemory()
        let machine = Machine(name: "screen")
        let address = MachineAddress(machineID: machine.id, label: "", host: "vnc.box")
        let profile = VNCProfile(machineID: machine.id, username: "nick", port: 5901, sharesClipboard: true)
        try await library.save(.batch([.upsertMachine(machine), .upsertAddress(address), .upsertProfile(.vnc(profile))]))
        let vncDriver = StubVNCDriver()
        let coordinator = SessionCoordinator(
            library: library,
            prober: StubProber(results: ["vnc.box": true]),
            driver: StubSSHDriver(),
            vncDriver: vncDriver)
        return (coordinator, library, machine, vncDriver)
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

@MainActor
private final class StubVNCDriver: VNCSessionDriving {
    private(set) var requests: [VNCSessionRequest] = []
    private(set) var sessions: [StubRemoteDesktopSession] = []

    func start(_ request: VNCSessionRequest) throws -> any RemoteDesktopSession {
        requests.append(request)
        let session = StubRemoteDesktopSession()
        sessions.append(session)
        return session
    }
}

@MainActor
private final class StubRDPDriver: RDPSessionDriving {
    private let cancels: Bool
    private(set) var requests: [RDPSessionRequest] = []
    private(set) var sessions: [StubRemoteDesktopSession] = []

    init(cancels: Bool = false) {
        self.cancels = cancels
    }

    func start(_ request: RDPSessionRequest) throws -> any RemoteDesktopSession {
        requests.append(request)
        if cancels { throw RDPSessionDriverError.cancelled }
        let session = StubRemoteDesktopSession()
        sessions.append(session)
        return session
    }
}

@MainActor
private final class StubRemoteDesktopSession: RemoteDesktopSession {
    let view = NSView()
    private(set) var state: RemoteDesktopSessionState = .idle
    var framebufferSize: CGSize?
    var displayMode: RemoteDesktopDisplayMode = .fit
    var eventHandler: (@MainActor (RemoteDesktopSessionEvent) -> Void)?
    private(set) var connectCalls = 0
    private(set) var disconnectCalls = 0

    func connect() {
        connectCalls += 1
        emit(.stateChanged(.connecting))
    }

    func disconnect() { disconnectCalls += 1 }
    func focus() {}

    func emit(_ event: RemoteDesktopSessionEvent) {
        if case .stateChanged(let newState) = event { state = newState }
        eventHandler?(event)
    }
}
