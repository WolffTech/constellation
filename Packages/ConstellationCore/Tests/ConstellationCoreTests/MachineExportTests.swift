import Foundation
import Testing
@testable import ConstellationCore

struct MachineExportTests {
    private func sampleSnapshot() -> (MachineLibrarySnapshot, CredentialID) {
        let machine = Machine(name: "alpha", notes: "temp box", tags: ["homelab"], isFavorite: true)
        let credential = CredentialReference(label: "temp password", kind: .password)
        let address = MachineAddress(machineID: machine.id, label: "LAN", host: "192.0.2.18", kind: .lan, priority: 0)
        let profile = SSHProfile(machineID: machine.id, name: "SSH", username: "temp", authentication: .password, credentialID: credential.id)
        let snapshot = MachineLibrarySnapshot(machines: [machine], addresses: [address], profiles: [.ssh(profile)], credentials: [credential])
        return (snapshot, credential.id)
    }

    @Test func exportCarriesNoCredentialIDs() throws {
        let (snapshot, credentialID) = sampleSnapshot()
        let data = try MachineExport.encode(MachineExport.document(from: snapshot))
        let json = String(decoding: data, as: UTF8.self)
        #expect(!json.contains(credentialID.description))
        #expect(!json.contains("credentialID"))
        #expect(!json.contains("credentials"))
        #expect(json.contains("192.0.2.18"))
    }

    @Test func importRoundTripsDefinitions() throws {
        let (snapshot, _) = sampleSnapshot()
        let data = try MachineExport.encode(MachineExport.document(from: snapshot))
        let document = try MachineExport.decode(data)
        #expect(document.machines == snapshot.machines)
        #expect(document.addresses == snapshot.addresses)
        #expect(document.profiles.map(\.id) == snapshot.profiles.map(\.id))
        #expect(document.profiles.allSatisfy { $0.credentialID == nil })
        guard case .batch(let changes) = MachineExport.importChange(for: document) else {
            Issue.record("expected a batch")
            return
        }
        #expect(changes.count == 3)
    }

    @Test func rejectsNewerFormats() throws {
        let (snapshot, _) = sampleSnapshot()
        var document = MachineExport.document(from: snapshot)
        document.version = 99
        let data = try MachineExport.encode(document)
        #expect(throws: MachineExportError.unsupportedVersion(99)) { try MachineExport.decode(data) }
    }
}

struct SecretTests {
    @Test func printedFormsAreRedacted() {
        let secret = Secret("hunter2")
        #expect("\(secret)" == "Secret(••••)")
        #expect(String(reflecting: secret) == "Secret(••••)")
        #expect(!String(describing: [secret]).contains("hunter2"))
        #expect(secret.withValue { $0 } == "hunter2")
    }
}
