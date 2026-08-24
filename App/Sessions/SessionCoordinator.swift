import AppKit
import ConstellationCore
import ConstellationOpenSSH
import ConstellationTerminal
import Foundation
import Observation

@MainActor
@Observable
final class SessionCoordinator {
    private(set) var sessions: [SessionSummary] = []
    private(set) var selectedSessionID: SessionID?
    var pendingClose: CloseRequest?
    var searchSessionID: SessionID?
    var presentedError: PresentedError?

    private let library: any MachineLibrary
    private let prober: any AddressProbing
    private let driver: any SSHSessionDriving
    private var handles: [SessionID: SSHDriverSession] = [:]
    private var attempts: [SessionID: UUID] = [:]
    private var reportedExitStatuses: [SessionID: Int32] = [:]
    private var pendingConnectionFacts: [SessionID: ConnectionFacts] = [:]
    private var workspaceSaveTask: Task<Void, Never>?

    init(
        library: any MachineLibrary,
        prober: any AddressProbing,
        driver: any SSHSessionDriving
    ) {
        self.library = library
        self.prober = prober
        self.driver = driver
    }

    var selectedSession: SessionSummary? {
        guard let selectedSessionID else { return nil }
        return sessions.first { $0.id == selectedSessionID }
    }

    var needsQuitConfirmation: Bool {
        sessions.contains { $0.state.hasLiveProcess }
    }

    func terminal(for id: SessionID) -> (any TerminalSession)? {
        handles[id]?.terminal
    }

    /// Connected sessions for a machine.
    func count(for machineID: MachineID) -> Int {
        sessions.count { $0.machineID == machineID && $0.state.isConnected }
    }

    /// Connected sessions for one profile.
    func count(forProfile profileID: ProfileID) -> Int {
        sessions.count { $0.profileID == profileID && $0.state.isConnected }
    }

    @discardableResult
    func open(profileID: ProfileID) async throws -> SessionID {
        let snapshot = try await library.snapshot()
        guard let profile = snapshot.profile(profileID) else { throw SessionCoordinatorError.unknownProfile(profileID) }
        guard let machine = snapshot.machine(profile.machineID) else { throw SessionCoordinatorError.unknownMachine(profile.machineID) }
        let id = SessionID()
        sessions.append(SessionSummary(
            id: id,
            target: .saved(machineID: machine.id, profileID: profile.id),
            title: machine.name,
            machineName: machine.name,
            profileName: profile.name,
            state: .connecting(startedAt: .now)))
        selectedSessionID = id
        scheduleWorkspaceSave()
        await connect(id, snapshot: snapshot)
        return id
    }

    /// Opens the machine's default profile, or its first profile when none is marked default.
    @discardableResult
    func openDefaultProfile(for machineID: MachineID) async throws -> SessionID {
        let snapshot = try await library.snapshot()
        guard let machine = snapshot.machine(machineID) else { throw SessionCoordinatorError.unknownMachine(machineID) }
        guard let profileID = machine.defaultProfileID ?? snapshot.profiles(for: machineID).first?.id else {
            throw SessionCoordinatorError.noProfiles(machineID)
        }
        return try await open(profileID: profileID)
    }

    @discardableResult
    func openQuickConnect(_ target: QuickConnectTarget) async -> SessionID {
        let id = SessionID()
        sessions.append(SessionSummary(
            id: id,
            target: .quick(target),
            title: target.displayName,
            machineName: nil,
            profileName: "SSH",
            state: .connecting(startedAt: .now)))
        selectedSessionID = id
        await connect(id, snapshot: nil)
        return id
    }

    func reconnect(sessionID: SessionID) async throws {
        guard sessions.contains(where: { $0.id == sessionID }) else {
            throw SessionCoordinatorError.unknownSession(sessionID)
        }
        handles.removeValue(forKey: sessionID)?.close()
        pendingConnectionFacts.removeValue(forKey: sessionID)
        update(sessionID) { $0.state = .connecting(startedAt: .now) }
        await connect(sessionID, snapshot: nil)
    }

    func disconnect(sessionID: SessionID) {
        attempts[sessionID] = UUID()
        guard let handle = handles.removeValue(forKey: sessionID) else {
            update(sessionID) { $0.state = .disconnected }
            return
        }
        update(sessionID) { $0.state = .disconnecting }
        handle.close()
        reportedExitStatuses.removeValue(forKey: sessionID)
        pendingConnectionFacts.removeValue(forKey: sessionID)
        update(sessionID) { $0.state = .disconnected }
    }

    func close(sessionID: SessionID) {
        attempts[sessionID] = UUID()
        handles.removeValue(forKey: sessionID)?.close()
        reportedExitStatuses.removeValue(forKey: sessionID)
        pendingConnectionFacts.removeValue(forKey: sessionID)
        guard let index = sessions.firstIndex(where: { $0.id == sessionID }) else { return }
        sessions.remove(at: index)
        if selectedSessionID == sessionID {
            selectedSessionID = sessions.indices.contains(index) ? sessions[index].id : sessions.last?.id
        }
        if searchSessionID == sessionID { searchSessionID = nil }
        scheduleWorkspaceSave()
    }

    func requestClose(sessionID: SessionID) {
        guard let session = sessions.first(where: { $0.id == sessionID }) else { return }
        if session.state.hasLiveProcess {
            pendingClose = .session(sessionID)
        } else {
            close(sessionID: sessionID)
        }
    }

    func requestCloseOthers(keeping sessionID: SessionID) {
        guard sessions.contains(where: { $0.id == sessionID }) else { return }
        if sessions.contains(where: { $0.id != sessionID && $0.state.hasLiveProcess }) {
            pendingClose = .others(keeping: sessionID)
        } else {
            closeOthers(keeping: sessionID)
        }
    }

    func closeOthers(keeping sessionID: SessionID) {
        for id in sessions.map(\.id) where id != sessionID {
            close(sessionID: id)
        }
        select(sessionID)
    }

    /// Runs the close the user just confirmed.
    func confirmPendingClose() {
        defer { pendingClose = nil }
        switch pendingClose {
        case .session(let id): close(sessionID: id)
        case .others(let keeping): closeOthers(keeping: keeping)
        case nil: break
        }
    }

    func present(_ error: any Error, title: String) {
        presentedError = PresentedError(title: title, message: error.localizedDescription)
    }

    func closeSessions(for machineID: MachineID) {
        for id in sessions.filter({ $0.machineID == machineID }).map(\.id) {
            close(sessionID: id)
        }
    }

    func select(_ sessionID: SessionID?) {
        guard sessionID == nil || sessions.contains(where: { $0.id == sessionID }) else { return }
        selectedSessionID = sessionID
        scheduleWorkspaceSave()
    }

    func select(number: Int) {
        guard (1...9).contains(number), sessions.indices.contains(number - 1) else { return }
        select(sessions[number - 1].id)
    }

    func cycleSelection(reverse: Bool = false) {
        guard !sessions.isEmpty else { return }
        guard let selectedSessionID,
              let index = sessions.firstIndex(where: { $0.id == selectedSessionID }) else {
            select(sessions[0].id)
            return
        }
        let offset = reverse ? sessions.count - 1 : 1
        select(sessions[(index + offset) % sessions.count].id)
    }

    func move(sessionID: SessionID, before destinationID: SessionID) {
        guard sessionID != destinationID,
              let source = sessions.firstIndex(where: { $0.id == sessionID }),
              let destination = sessions.firstIndex(where: { $0.id == destinationID }) else { return }
        let session = sessions.remove(at: source)
        let adjustedDestination = source < destination ? destination - 1 : destination
        sessions.insert(session, at: adjustedDestination)
        scheduleWorkspaceSave()
    }

    func restoreWorkspace(from snapshot: MachineLibrarySnapshot) {
        guard sessions.isEmpty else { return }
        sessions = snapshot.workspaceTabs.compactMap { tab in
            guard let machine = snapshot.machine(tab.machineID),
                  let profile = snapshot.profile(tab.profileID) else { return nil }
            return SessionSummary(
                id: tab.id,
                target: .saved(machineID: machine.id, profileID: profile.id),
                title: tab.title.isEmpty ? machine.name : tab.title,
                machineName: machine.name,
                profileName: profile.name,
                state: .disconnected)
        }
        selectedSessionID = snapshot.workspaceTabs.first(where: \.isSelected).flatMap { selected in
            sessions.contains(where: { $0.id == selected.id }) ? selected.id : nil
        } ?? sessions.first?.id
    }

    @discardableResult
    func saveQuickConnect(sessionID: SessionID, machineName: String) async throws -> MachineID {
        guard let index = sessions.firstIndex(where: { $0.id == sessionID }) else {
            throw SessionCoordinatorError.unknownSession(sessionID)
        }
        guard case .quick(let target) = sessions[index].target else {
            throw SessionCoordinatorError.notQuickConnect(sessionID)
        }
        let profileID = ProfileID()
        let machine = Machine(name: machineName, defaultProfileID: profileID)
        let address = MachineAddress(machineID: machine.id, label: "Quick Connect", host: target.host, kind: .other)
        let profile = SSHProfile(
            id: profileID,
            machineID: machine.id,
            username: target.username,
            port: target.effectivePort,
            addressSelection: .pinned(address.id),
            authentication: .agent)
        try await library.save(.batch([
            .upsertMachine(machine), .upsertAddress(address), .upsertProfile(.ssh(profile)),
        ]))
        sessions[index].target = .saved(machineID: machine.id, profileID: profile.id)
        sessions[index].machineName = machine.name
        sessions[index].title = machine.name
        scheduleWorkspaceSave()
        return machine.id
    }

    func performSearch() {
        guard let selectedSessionID, handles[selectedSessionID] != nil else { return }
        searchSessionID = selectedSessionID
    }

    func dismissSearch(sessionID: SessionID) {
        _ = handles[sessionID]?.terminal.performBinding("end_search")
        if searchSessionID == sessionID { searchSessionID = nil }
    }

    func closeAll() {
        for id in sessions.map(\.id) { close(sessionID: id) }
    }

    func disconnectAllForTermination() {
        for id in sessions.filter({ $0.state.hasLiveProcess }).map(\.id) {
            disconnect(sessionID: id)
        }
    }

    /// Writes the current saved-tab snapshot immediately. Tests and app
    /// lifecycle hooks use this when they need a completed write.
    func persistWorkspace() async throws {
        workspaceSaveTask?.cancel()
        try await library.save(.replaceWorkspace(workspaceTabs))
    }

    private func connect(_ sessionID: SessionID, snapshot: MachineLibrarySnapshot?) async {
        let attempt = UUID()
        attempts[sessionID] = attempt
        reportedExitStatuses.removeValue(forKey: sessionID)
        guard let summary = sessions.first(where: { $0.id == sessionID }) else { return }

        let request: SSHSessionRequest
        switch summary.target {
        case .quick(let target):
            request = SSHSessionRequest(
                destination: SSHDestination(host: target.host, user: target.username, port: target.port),
                hostKeyAlias: nil,
                authentication: .agent,
                credentialID: nil)

        case .saved(let machineID, let profileID):
            let loaded: MachineLibrarySnapshot
            do {
                loaded = if let snapshot { snapshot } else { try await library.snapshot() }
            } catch {
                fail(sessionID, attempt: attempt, with: .launchFailed(error.localizedDescription))
                return
            }
            guard let profile = loaded.profile(profileID) else {
                fail(sessionID, attempt: attempt, with: .launchFailed("The profile no longer exists."))
                return
            }
            guard case .ssh(let ssh) = profile else {
                fail(sessionID, attempt: attempt, with: .unsupportedProtocol(profile.protocolKind))
                return
            }
            var addresses = loaded.addresses(for: machineID)
            if case .pinned(let addressID) = profile.addressSelection {
                addresses = addresses.filter { $0.id == addressID }
            }
            guard !addresses.isEmpty else {
                fail(sessionID, attempt: attempt, with: .noAddress)
                return
            }
            var reachable: MachineAddress?
            for address in addresses {
                guard attempts[sessionID] == attempt else { return }
                if await prober.canConnect(host: address.host, port: ssh.port, timeout: .seconds(2)) {
                    reachable = address
                    break
                }
            }
            guard let reachable else {
                fail(sessionID, attempt: attempt, with: .unreachable)
                return
            }
            request = SSHSessionRequest(
                destination: SSHDestination(host: reachable.host, user: ssh.username, port: ssh.port),
                hostKeyAlias: "constellation-\(machineID)",
                authentication: ssh.authentication,
                credentialID: ssh.credentialID)
        }

        guard attempts[sessionID] == attempt else { return }
        do {
            let handle = try driver.start(request)
            guard attempts[sessionID] == attempt,
                  sessions.contains(where: { $0.id == sessionID }) else {
                handle.close()
                return
            }
            handles[sessionID] = handle
            pendingConnectionFacts[sessionID] = ConnectionFacts(
                host: request.destination.host,
                port: request.destination.port ?? 22,
                connectedAt: Date())
            handle.terminal.eventHandler = { [weak self] event in
                self?.handle(event, for: sessionID)
            }
        } catch {
            fail(sessionID, attempt: attempt, with: .launchFailed(error.localizedDescription))
        }
    }

    private func handle(_ event: TerminalEvent, for sessionID: SessionID) {
        guard let handle = handles[sessionID] else { return }
        switch event {
        case .titleChanged(let title):
            if let code = handle.exitStatusChannel.exitStatus(fromTitle: title) {
                reportedExitStatuses[sessionID] = code
            } else if handle.exitStatusChannel.isConnectionTitle(title),
                      let facts = pendingConnectionFacts.removeValue(forKey: sessionID) {
                update(sessionID) { $0.state = .connected(facts) }
            } else if !title.isEmpty {
                update(sessionID) { $0.title = title }
                scheduleWorkspaceSave()
            }
        case .processExited:
            handle.finish()
            pendingConnectionFacts.removeValue(forKey: sessionID)
            if let code = reportedExitStatuses.removeValue(forKey: sessionID) {
                update(sessionID) { $0.state = code == 0 ? .disconnected : .failed(.sshExited(code)) }
            } else {
                update(sessionID) { $0.state = .failed(.endedWithoutStatus) }
            }
        case .closeRequested(let processAlive):
            if processAlive {
                pendingClose = .session(sessionID)
            } else {
                close(sessionID: sessionID)
            }
        case .bell:
            NSSound.beep()
        case .rendererHealthChanged(let healthy):
            if !healthy {
                presentedError = PresentedError(
                    title: "Terminal Renderer Stopped",
                    message: "The terminal renderer stopped responding. Close and reopen the session.")
            }
        }
    }

    private func fail(_ sessionID: SessionID, attempt: UUID, with failure: ConnectionFailure) {
        guard attempts[sessionID] == attempt else { return }
        pendingConnectionFacts.removeValue(forKey: sessionID)
        update(sessionID) { $0.state = .failed(failure) }
    }

    private func update(_ sessionID: SessionID, _ change: (inout SessionSummary) -> Void) {
        guard let index = sessions.firstIndex(where: { $0.id == sessionID }) else { return }
        change(&sessions[index])
    }

    private var workspaceTabs: [WorkspaceTab] {
        sessions.enumerated().compactMap { index, session in
            guard case .saved(let machineID, let profileID) = session.target else { return nil }
            return WorkspaceTab(
                id: session.id,
                machineID: machineID,
                profileID: profileID,
                title: session.title,
                position: index,
                isSelected: session.id == selectedSessionID)
        }
    }

    private func scheduleWorkspaceSave() {
        let tabs = workspaceTabs
        workspaceSaveTask?.cancel()
        workspaceSaveTask = Task { [library] in
            do {
                try await Task.sleep(for: .milliseconds(50))
                try Task.checkCancellation()
                try await library.save(.replaceWorkspace(tabs))
            } catch is CancellationError {
                return
            } catch {
                await MainActor.run { [weak self] in self?.present(error, title: "Couldn’t Save Workspace") }
            }
        }
    }
}
