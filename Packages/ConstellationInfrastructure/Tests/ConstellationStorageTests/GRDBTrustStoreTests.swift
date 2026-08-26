// SPDX-FileCopyrightText: 2026 Nick Wolff <nick@wolff.tech>
// SPDX-License-Identifier: GPL-3.0-only

import ConstellationCore
import Foundation
import Testing
@testable import ConstellationStorage

struct GRDBTrustStoreTests {
    private func cert(host: String = "win11", port: Int = 3389, fingerprint: String = "AA:BB:CC") -> TrustedCertificate {
        TrustedCertificate(host: host, port: port, fingerprint: fingerprint, subject: "CN=win11", issuer: "CN=win11", commonName: "win11")
    }

    @Test func storesAndReadsBack() async throws {
        let store = try GRDBTrustStore.inMemory()
        let certificate = cert()
        try await store.trust(certificate)
        #expect(try await store.trusted(host: "win11", port: 3389) == certificate)
        #expect(try await store.trusted(host: "win11", port: 3390) == nil)
    }

    @Test func trustingAgainReplacesTheFingerprint() async throws {
        let store = try GRDBTrustStore.inMemory()
        try await store.trust(cert(fingerprint: "old"))
        try await store.trust(cert(fingerprint: "new"))
        #expect(try await store.all().count == 1)
        #expect(try await store.trusted(host: "win11", port: 3389)?.fingerprint == "new")
    }

    @Test func forgettingRemovesTheEntry() async throws {
        let store = try GRDBTrustStore.inMemory()
        try await store.trust(cert())
        try await store.forget(host: "win11", port: 3389)
        #expect(try await store.trusted(host: "win11", port: 3389) == nil)
    }

    @Test func matchesIgnoresSeparatorsAndCase() {
        let certificate = cert(fingerprint: "AA:BB:CC")
        #expect(certificate.matches(fingerprint: "aabbcc"))
        #expect(certificate.matches(fingerprint: "aa bb cc"))
        #expect(!certificate.matches(fingerprint: "aabbcd"))
    }
}
