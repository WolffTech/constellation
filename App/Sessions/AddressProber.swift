// SPDX-FileCopyrightText: 2026 Nick Wolff <nick@wolff.tech>
// SPDX-License-Identifier: GPL-3.0-only

import Foundation
import Network

protocol AddressProbing: Sendable {
    func canConnect(host: String, port: Int, timeout: Duration) async -> Bool
}

/// A short TCP handshake used only to choose a route before OpenSSH starts.
struct TCPAddressProber: AddressProbing {
    func canConnect(host: String, port: Int, timeout: Duration) async -> Bool {
        guard let networkPort = NWEndpoint.Port(rawValue: UInt16(port)) else { return false }
        return await withCheckedContinuation { continuation in
            let probe = TCPProbe(
                connection: NWConnection(host: NWEndpoint.Host(host), port: networkPort, using: .tcp),
                continuation: continuation)
            probe.start(timeout: timeout)
        }
    }
}

private final class TCPProbe: @unchecked Sendable {
    private static let queue = DispatchQueue(label: "tech.wolff.Constellation.address-probe", qos: .userInitiated)

    private let connection: NWConnection
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Bool, Never>?

    init(connection: NWConnection, continuation: CheckedContinuation<Bool, Never>) {
        self.connection = connection
        self.continuation = continuation
    }

    func start(timeout: Duration) {
        connection.stateUpdateHandler = { [self] state in
            switch state {
            case .ready:
                finish(true)
            case .failed, .cancelled:
                finish(false)
            default:
                break
            }
        }
        connection.start(queue: Self.queue)
        Self.queue.asyncAfter(deadline: .now() + timeout.timeInterval) { [self] in
            finish(false)
        }
    }

    private func finish(_ result: Bool) {
        let pending = lock.withLock { () -> CheckedContinuation<Bool, Never>? in
            defer { continuation = nil }
            return continuation
        }
        guard let pending else { return }
        connection.stateUpdateHandler = nil
        connection.cancel()
        pending.resume(returning: result)
    }
}

private extension Duration {
    var timeInterval: TimeInterval {
        let parts = components
        return TimeInterval(parts.seconds) + TimeInterval(parts.attoseconds) / 1e18
    }
}
