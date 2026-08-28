// SPDX-FileCopyrightText: 2026 Nick Wolff <nick@wolff.tech>
// SPDX-License-Identifier: GPL-3.0-only

import AppKit
import ConstellationCore
import ConstellationOpenSSH
import ConstellationRemoteDesktop
import ConstellationTerminal
import Foundation
import Observation

/// A running driver session of either kind.
@MainActor
enum LiveSession {
    case ssh(SSHDriverSession)
    case remoteDesktop(any RemoteDesktopSession)

    var terminal: (any TerminalSession)? {
        if case .ssh(let handle) = self { handle.terminal } else { nil }
    }

    var remoteDesktop: (any RemoteDesktopSession)? {
        if case .remoteDesktop(let session) = self { session } else { nil }
    }

    func close() {
        switch self {
        case .ssh(let handle): handle.close()
        case .remoteDesktop(let session):
            session.eventHandler = nil
            session.disconnect()
        }
    }
}

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
    private let vncDriver: (any VNCSessionDriving)?
    private let rdpDriver: (any RDPSessionDriving)?
    private var handles: [SessionID: LiveSession] = [:]
    private var attempts: [SessionID: UUID] = [:]
    private var reportedExitStatuses: [SessionID: Int32] = [:]
    private var pendingConnectionFacts: [SessionID: ConnectionFacts] = [:]
    private var workspaceSaveTask: Task<Void, Never>?

    init(
        library: any MachineLibrary,
        prober: any AddressProbing,
        driver: any SSHSessionDriving,
        vncDriver: (any VNCSessionDriving)? = nil,
        rdpDriver: (any RDPSessionDriving)? = nil
    ) {
        self.library = library
        self.prober = prober
        self.driver = driver
        self.vncDriver = vncDriver
        self.rdpDriver = rdpDriver
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

    func remoteDesktop(for id: SessionID) -> (any RemoteDesktopSession)? {
        handles[id]?.remoteDesktop
    }

    func isRemoteDesktop(_ id: SessionID) -> Bool {
        switch sessions.first(where: { $0.id == id })?.protocolKind {
        case .vnc, .rdp: true
        case .ssh, .appleScreenSharing, nil: false
        }
    }

    /// Open workspace tabs for a machine, regardless of connection state.
    func openSessionCount(forMachine machineID: MachineID) -> Int {
        sessions.count { $0.machineID == machineID }
    }

    /// Open workspace tabs for one profile, regardless of connection state.
    func openSessionCount(forProfile profileID: ProfileID) -> Int {
        sessions.count { $0.profileID == profileID }
    }

    /// Selects the first matching tab in the current tab order.
    @discardableResult
    func selectFirstSession(forProfile profileID: ProfileID) -> Bool {
        guard let sessionID = sessions.first(where: { $0.profileID == profileID })?.id else { return false }
        select(sessionID)
        return true
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
            state: .connecting(startedAt: .now),
            protocolKind: profile.protocolKind,
            username: profile.username))
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
        pendingConnectionFacts.removeValue(forKey: sessionID)
        reportedExitStatuses.removeValue(forKey: sessionID)
        switch handles[sessionID] {
        case .ssh(let handle):
            handles.removeValue(forKey: sessionID)
            update(sessionID) { $0.state = .disconnecting }
            handle.close()
            update(sessionID) { $0.state = .disconnected }
        case .remoteDesktop(let session) where session.state.isLive:
            // The desktop closes asynchronously; its disconnected event finishes this.
            update(sessionID) { $0.state = .disconnecting }
            session.disconnect()
        case .remoteDesktop:
            handles.removeValue(forKey: sessionID)?.close()
            update(sessionID) { $0.state = .disconnected }
        case nil:
            update(sessionID) { $0.state = .disconnected }
        }
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

    func setDisplayMode(_ mode: RemoteDesktopDisplayMode, for sessionID: SessionID) {
        handles[sessionID]?.remoteDesktop?.displayMode = mode
        update(sessionID) { $0.displayMode = mode }
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
                state: .disconnected,
                protocolKind: profile.protocolKind,
                username: profile.username)
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
        guard let selectedSessionID, terminal(for: selectedSessionID) != nil else { return }
        searchSessionID = selectedSessionID
    }

    func dismissSearch(sessionID: SessionID) {
        _ = terminal(for: sessionID)?.performBinding("end_search")
        if searchSessionID == sessionID { searchSessionID = nil }
    }

    func closeAll() {
        for id in sessions.map(\.id) { close(sessionID: id) }
    }

    func disconnectAllForTermination() {
        for id in sessions.filter({ $0.state.hasLiveProcess }).map(\.id) {
            handles.removeValue(forKey: id)?.close()
            update(id) { $0.state = .disconnected }
        }
    }

    /// Writes the current saved-tab snapshot immediately. Tests and app
    /// lifecycle hooks use this when they need a completed write.
    func persistWorkspace() async throws {
        workspaceSaveTask?.cancel()
        try await library.save(.replaceWorkspace(workspaceTabs))
    }

    // MARK: Connecting

    private func connect(_ sessionID: SessionID, snapshot: MachineLibrarySnapshot?) async {
        let attempt = UUID()
        attempts[sessionID] = attempt
        reportedExitStatuses.removeValue(forKey: sessionID)
        guard let summary = sessions.first(where: { $0.id == sessionID }) else { return }

        switch summary.target {
        case .quick(let target):
            let request = SSHSessionRequest(
                destination: SSHDestination(host: target.host, user: target.username, port: target.port),
                hostKeyAlias: nil,
                authentication: .agent,
                credentialID: nil)
            startSSH(request, for: sessionID, attempt: attempt)

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
            let port: Int
            switch profile {
            case .ssh(let ssh): port = ssh.port
            case .vnc(let vnc): port = vnc.port
            case .rdp(let rdp): port = rdp.port
            case .appleScreenSharing:
                fail(sessionID, attempt: attempt, with: .unsupportedProtocol(profile.protocolKind))
                return
            }
            guard let address = await resolveAddress(for: profile, machineID: machineID, port: port, in: loaded, sessionID: sessionID, attempt: attempt) else {
                return
            }
            update(sessionID) {
                $0.endpoint = SessionEndpoint(host: address.host, port: port)
                $0.protocolKind = profile.protocolKind
                $0.username = profile.username
            }

            switch profile {
            case .ssh(let ssh):
                startSSH(
                    SSHSessionRequest(
                        destination: SSHDestination(host: address.host, user: ssh.username, port: ssh.port),
                        hostKeyAlias: "constellation-\(machineID)",
                        authentication: ssh.authentication,
                        credentialID: ssh.credentialID),
                    for: sessionID,
                    attempt: attempt)
            case .vnc(let vnc):
                startVNC(
                    VNCSessionRequest(
                        host: address.host,
                        port: vnc.port,
                        username: vnc.username,
                        credentialID: vnc.credentialID,
                        sharesClipboard: vnc.sharesClipboard,
                        machineName: summary.machineName ?? summary.title),
                    for: sessionID,
                    attempt: attempt)
            case .rdp(let rdp):
                startRDP(
                    RDPSessionRequest(
                        host: address.host,
                        port: rdp.port,
                        username: rdp.username,
                        domain: rdp.domain,
                        credentialID: rdp.credentialID,
                        sharesClipboard: rdp.sharesClipboard,
                        machineName: summary.machineName ?? summary.title),
                    for: sessionID,
                    attempt: attempt)
            case .appleScreenSharing:
                return
            }
        }
    }

    /// Pinned address, or the first one in priority order that accepts a TCP
    /// connection. Exactly one address reaches a driver.
    private func resolveAddress(
        for profile: ConnectionProfile,
        machineID: MachineID,
        port: Int,
        in snapshot: MachineLibrarySnapshot,
        sessionID: SessionID,
        attempt: UUID
    ) async -> MachineAddress? {
        var addresses = snapshot.addresses(for: machineID)
        if case .pinned(let addressID) = profile.addressSelection {
            addresses = addresses.filter { $0.id == addressID }
        }
        guard !addresses.isEmpty else {
            fail(sessionID, attempt: attempt, with: .noAddress)
            return nil
        }
        for address in addresses {
            guard attempts[sessionID] == attempt else { return nil }
            if await prober.canConnect(host: address.host, port: port, timeout: .seconds(2)) {
                return address
            }
        }
        fail(sessionID, attempt: attempt, with: .unreachable)
        return nil
    }

    private func startSSH(_ request: SSHSessionRequest, for sessionID: SessionID, attempt: UUID) {
        guard attempts[sessionID] == attempt else { return }
        do {
            let handle = try driver.start(request)
            guard attempts[sessionID] == attempt,
                  sessions.contains(where: { $0.id == sessionID }) else {
                handle.close()
                return
            }
            handles[sessionID] = .ssh(handle)
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

    private func startVNC(_ request: VNCSessionRequest, for sessionID: SessionID, attempt: UUID) {
        guard let vncDriver else {
            fail(sessionID, attempt: attempt, with: .unsupportedProtocol(.vnc))
            return
        }
        startRemoteDesktop(host: request.host, port: request.port, for: sessionID, attempt: attempt) {
            try vncDriver.start(request)
        }
    }

    private func startRDP(_ request: RDPSessionRequest, for sessionID: SessionID, attempt: UUID) {
        guard let rdpDriver else {
            fail(sessionID, attempt: attempt, with: .unsupportedProtocol(.rdp))
            return
        }
        startRemoteDesktop(host: request.host, port: request.port, for: sessionID, attempt: attempt) {
            try rdpDriver.start(request)
        }
    }

    /// Shared tail of every remote desktop start: the driver may prompt (and
    /// throw on cancel) before the session exists.
    private func startRemoteDesktop(
        host: String,
        port: Int,
        for sessionID: SessionID,
        attempt: UUID,
        make: () throws -> any RemoteDesktopSession
    ) {
        guard attempts[sessionID] == attempt else { return }
        do {
            let session = try make()
            guard attempts[sessionID] == attempt,
                  let summary = sessions.first(where: { $0.id == sessionID }) else { return }
            if let mode = summary.displayMode {
                session.displayMode = mode
            } else {
                update(sessionID) { $0.displayMode = session.displayMode }
            }
            handles[sessionID] = .remoteDesktop(session)
            let facts = ConnectionFacts(host: host, port: port, connectedAt: Date())
            session.eventHandler = { [weak self] event in
                self?.handle(event, facts: facts, for: sessionID)
            }
            session.connect()
        } catch RDPSessionDriverError.cancelled {
            update(sessionID) { $0.state = .disconnected }
        } catch {
            fail(sessionID, attempt: attempt, with: .launchFailed(error.localizedDescription))
        }
    }

    // MARK: Events

    private func handle(_ event: TerminalEvent, for sessionID: SessionID) {
        guard case .ssh(let handle) = handles[sessionID] else { return }
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

    private func handle(_ event: RemoteDesktopSessionEvent, facts: ConnectionFacts, for sessionID: SessionID) {
        guard case .remoteDesktop = handles[sessionID] else { return }
        switch event {
        case .stateChanged(let state):
            switch state {
            case .idle:
                break
            case .connecting:
                update(sessionID) { $0.state = .connecting(startedAt: .now) }
            case .connected:
                update(sessionID) { $0.state = .connected(ConnectionFacts(host: facts.host, port: facts.port, connectedAt: Date())) }
            case .disconnecting:
                update(sessionID) { $0.state = .disconnecting }
            case .disconnected(let failure):
                handles.removeValue(forKey: sessionID)?.close()
                update(sessionID) {
                    switch failure {
                    case nil: $0.state = .disconnected
                    case let failure? where failure.isAuthenticationFailure: $0.state = .failed(.authenticationFailed(failure.message))
                    case let failure?: $0.state = .failed(.remoteDesktop(failure.message))
                    }
                }
            }
        case .framebufferSizeChanged:
            break
        }
    }

    private func fail(_ sessionID: SessionID, attempt: UUID, with failure: ConnectionFailure) {
        guard attempts[sessionID] == attempt else { return }
        pendingConnectionFacts.removeValue(forKey: sessionID)
        update(sessionID) { $0.state = .failed(failure) }
    }

    private func update(_ sessionID: SessionID, _ change: (inout SessionSummary) -> Void) {
        guard let index = sessions.firstIndex(where: { $0.id == sessionID }) else { return }
        let before = sessions[index].state.displayName
        change(&sessions[index])
        let session = sessions[index]
        if session.id == selectedSessionID, session.state.displayName != before {
            announce("\(session.title): \(session.state.displayName)")
        }
    }

    /// VoiceOver announcement for state changes of the session on screen;
    /// the tab and banners update visually but nothing else would speak.
    private func announce(_ text: String) {
        guard let app = NSApp else { return }
        NSAccessibility.post(
            element: app, notification: .announcementRequested,
            userInfo: [.announcement: text, .priority: NSAccessibilityPriorityLevel.medium.rawValue])
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
