// SPDX-FileCopyrightText: 2026 Nick Wolff <nick@wolff.tech>
// SPDX-License-Identifier: GPL-3.0-only

import ConstellationCore
import Foundation
import Observation

/// The remembered certificate decisions, for Settings › Certificates and the
/// sidebar's per-profile "Forget" action. Reads through to the Trust Store on
/// every load rather than mirroring it, because the RDP driver writes to the
/// store directly when the user chooses Always Trust.
@MainActor
@Observable
final class TrustedCertificatesModel {
    private(set) var certificates: [TrustedCertificate] = []
    var presentedError: String?

    private let store: any TrustStore

    init(store: any TrustStore) {
        self.store = store
    }

    func load() async {
        do { certificates = try await store.all() }
        catch { presentedError = error.localizedDescription }
    }

    func forget(_ ids: Set<TrustedCertificate.ID>) async {
        let doomed = certificates.filter { ids.contains($0.id) }
        do {
            for certificate in doomed { try await store.forget(host: certificate.host, port: certificate.port) }
        } catch {
            presentedError = error.localizedDescription
        }
        await load()
    }

    /// Drops the decision for every address of a machine at one port, which is
    /// what "forget this RDP profile's certificate" means when the profile
    /// picks whichever address is reachable.
    func forget(hosts: [String], port: Int) async {
        do {
            for host in hosts { try await store.forget(host: host, port: port) }
        } catch {
            presentedError = error.localizedDescription
        }
        await load()
    }
}
