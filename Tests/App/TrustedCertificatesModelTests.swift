// SPDX-FileCopyrightText: 2026 Nick Wolff <nick@wolff.tech>
// SPDX-License-Identifier: GPL-3.0-only

import ConstellationCore
import Testing
@testable import Constellation

@MainActor
struct TrustedCertificatesModelTests {
    private func cert(host: String, port: Int = 3389) -> TrustedCertificate {
        TrustedCertificate(host: host, port: port, fingerprint: "AA", subject: "", issuer: "", commonName: host)
    }

    @Test func loadListsTheStore() async throws {
        let store = InMemoryTrustStore()
        try await store.trust(cert(host: "win11"))
        let model = TrustedCertificatesModel(store: store)
        await model.load()
        #expect(model.certificates.map(\.id) == ["win11:3389"])
    }

    @Test func forgetRemovesOnlyTheSelectedServers() async throws {
        let store = InMemoryTrustStore()
        try await store.trust(cert(host: "win11"))
        try await store.trust(cert(host: "dc01"))
        let model = TrustedCertificatesModel(store: store)
        await model.load()
        await model.forget(["win11:3389"])
        #expect(model.certificates.map(\.id) == ["dc01:3389"])
        #expect(try await store.trusted(host: "win11", port: 3389) == nil)
        #expect(try await store.trusted(host: "dc01", port: 3389) != nil)
    }

    @Test func forgetByHostsCoversEveryAddressAtThePort() async throws {
        let store = InMemoryTrustStore()
        try await store.trust(cert(host: "win11.lan"))
        try await store.trust(cert(host: "10.0.0.5"))
        try await store.trust(cert(host: "10.0.0.5", port: 3390))
        let model = TrustedCertificatesModel(store: store)
        await model.forget(hosts: ["win11.lan", "10.0.0.5"], port: 3389)
        #expect(model.certificates.map(\.id) == ["10.0.0.5:3390"])
    }
}
