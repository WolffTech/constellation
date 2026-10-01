// SPDX-FileCopyrightText: 2026 Nick Wolff <nick@wolff.tech>
// SPDX-License-Identifier: GPL-3.0-only

import ConstellationCore
import ConstellationRDP
import Foundation
import Testing
@testable import Constellation

@MainActor
struct RDPTrustTests {
    private func cert(fingerprint: String = "AA:BB:CC", changed: Bool = false) -> RDPCertificate {
        RDPCertificate(
            host: "win11", port: 3389, commonName: "win11",
            subject: "CN=win11", issuer: "CN=win11",
            fingerprint: fingerprint, hostMismatch: false, changed: changed)
    }

    /// Records every prompt so a test can assert whether one appeared and with
    /// what `changed` flag, and dictate the user's choice. Only ever touched on
    /// the main actor, so `@unchecked Sendable` is safe.
    private final class Prompt: @unchecked Sendable {
        var calls: [(RDPCertificate, Bool)] = []
        var decision: RDPTrustDecision
        init(_ decision: RDPTrustDecision) { self.decision = decision }
        func ask(_ certificate: RDPCertificate, _ name: String, _ changed: Bool) -> RDPTrustDecision {
            calls.append((certificate, changed))
            return decision
        }
    }

    private func resolve(
        _ certificate: RDPCertificate,
        machineName: String,
        trustStore: any TrustStore,
        prompt: @MainActor (RDPCertificate, String, Bool) -> RDPTrustDecision
    ) async -> RDPCertificateVerdict {
        await resolveCertificate(
            certificate, machineName: machineName, trustStore: trustStore, prompt: prompt,
            trustNotSaved: { _, _, error in Issue.record(error, "trust decision unexpectedly not saved") })
    }

    @Test func trustedFingerprintConnectsWithoutPrompting() async throws {
        let store = InMemoryTrustStore()
        try await store.trust(TrustedCertificate(host: "win11", port: 3389, fingerprint: "AA:BB:CC", subject: "", issuer: "", commonName: ""))
        let prompt = Prompt(.reject)
        let verdict = await resolve(cert(), machineName: "win11", trustStore: store, prompt: prompt.ask)
        #expect(verdict == .acceptOnce)
        #expect(prompt.calls.isEmpty)
    }

    @Test func unknownCertificatePromptsAsFirstUse() async throws {
        let store = InMemoryTrustStore()
        let prompt = Prompt(.connectOnce)
        let verdict = await resolve(cert(), machineName: "win11", trustStore: store, prompt: prompt.ask)
        #expect(verdict == .acceptOnce)
        #expect(prompt.calls.count == 1)
        #expect(prompt.calls.first?.1 == false)
        // Connect Once does not persist.
        #expect(try await store.trusted(host: "win11", port: 3389) == nil)
    }

    @Test func alwaysTrustPersistsTheFingerprint() async throws {
        let store = InMemoryTrustStore()
        let prompt = Prompt(.trustAlways)
        let verdict = await resolve(cert(), machineName: "win11", trustStore: store, prompt: prompt.ask)
        #expect(verdict == .acceptOnce)
        #expect(try await store.trusted(host: "win11", port: 3389)?.fingerprint == "AA:BB:CC")
    }

    @Test func forgettingAServerPromptsAsFirstUseAgain() async throws {
        let store = InMemoryTrustStore()
        try await store.trust(TrustedCertificate(host: "win11", port: 3389, fingerprint: "AA:BB:CC", subject: "", issuer: "", commonName: ""))
        try await store.forget(host: "win11", port: 3389)
        let prompt = Prompt(.connectOnce)
        let verdict = await resolve(cert(), machineName: "win11", trustStore: store, prompt: prompt.ask)
        #expect(verdict == .acceptOnce)
        #expect(prompt.calls.count == 1)
        #expect(prompt.calls.first?.1 == false, "a forgotten server is not a changed one")
    }

    @Test func alwaysTrustRecordsWhenTheDecisionWasMade() async throws {
        let store = InMemoryTrustStore()
        let before = Date()
        _ = await resolve(cert(), machineName: "win11", trustStore: store, prompt: Prompt(.trustAlways).ask)
        let trustedAt = try #require(try await store.trusted(host: "win11", port: 3389)?.trustedAt)
        #expect(trustedAt >= before && trustedAt <= Date())
    }

    @Test func differentStoredFingerprintPromptsAsChanged() async throws {
        let store = InMemoryTrustStore()
        try await store.trust(TrustedCertificate(host: "win11", port: 3389, fingerprint: "OLD", subject: "", issuer: "", commonName: ""))
        let prompt = Prompt(.reject)
        let verdict = await resolve(cert(fingerprint: "NEW"), machineName: "win11", trustStore: store, prompt: prompt.ask)
        #expect(verdict == .reject)
        #expect(prompt.calls.first?.1 == true, "expected the changed warning")
    }

    @Test func unsavedAlwaysTrustIsReportedAndStillConnects() async {
        var reported: [String] = []
        let verdict = await resolveCertificate(
            cert(), machineName: "win11", trustStore: RefusingTrustStore(), prompt: Prompt(.trustAlways).ask,
            trustNotSaved: { _, name, _ in reported.append(name) })
        #expect(verdict == .acceptOnce)
        #expect(reported == ["win11"])
    }
}

private struct RefusingTrustStore: TrustStore {
    struct Refused: Error {}
    func trusted(host: String, port: Int) async throws -> TrustedCertificate? { nil }
    func trust(_ certificate: TrustedCertificate) async throws { throw Refused() }
    func forget(host: String, port: Int) async throws {}
    func all() async throws -> [TrustedCertificate] { [] }
}
