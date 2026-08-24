import ConstellationCore
import ConstellationRDP
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

    @Test func trustedFingerprintConnectsWithoutPrompting() async throws {
        let store = InMemoryTrustStore()
        try await store.trust(TrustedCertificate(host: "win11", port: 3389, fingerprint: "AA:BB:CC", subject: "", issuer: "", commonName: ""))
        let prompt = Prompt(.reject)
        let verdict = await resolveCertificate(cert(), machineName: "win11", trustStore: store, prompt: prompt.ask)
        #expect(verdict == .acceptOnce)
        #expect(prompt.calls.isEmpty)
    }

    @Test func unknownCertificatePromptsAsFirstUse() async throws {
        let store = InMemoryTrustStore()
        let prompt = Prompt(.connectOnce)
        let verdict = await resolveCertificate(cert(), machineName: "win11", trustStore: store, prompt: prompt.ask)
        #expect(verdict == .acceptOnce)
        #expect(prompt.calls.count == 1)
        #expect(prompt.calls.first?.1 == false)
        // Connect Once does not persist.
        #expect(try await store.trusted(host: "win11", port: 3389) == nil)
    }

    @Test func alwaysTrustPersistsTheFingerprint() async throws {
        let store = InMemoryTrustStore()
        let prompt = Prompt(.trustAlways)
        let verdict = await resolveCertificate(cert(), machineName: "win11", trustStore: store, prompt: prompt.ask)
        #expect(verdict == .acceptOnce)
        #expect(try await store.trusted(host: "win11", port: 3389)?.fingerprint == "AA:BB:CC")
    }

    @Test func differentStoredFingerprintPromptsAsChanged() async throws {
        let store = InMemoryTrustStore()
        try await store.trust(TrustedCertificate(host: "win11", port: 3389, fingerprint: "OLD", subject: "", issuer: "", commonName: ""))
        let prompt = Prompt(.reject)
        let verdict = await resolveCertificate(cert(fingerprint: "NEW"), machineName: "win11", trustStore: store, prompt: prompt.ask)
        #expect(verdict == .reject)
        #expect(prompt.calls.first?.1 == true, "expected the changed warning")
    }
}
