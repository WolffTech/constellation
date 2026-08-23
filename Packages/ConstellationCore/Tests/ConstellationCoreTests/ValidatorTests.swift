import Testing
@testable import ConstellationCore

struct ValidatorTests {
    @Test func acceptsCommonHosts() {
        for host in ["192.0.2.18", "alpha.local", "box", "nas-01.home.arpa", "[fe80::1%en0]", "2001:db8::1"] {
            #expect(throws: Never.self, "\(host)") { try Validator.validateHost(host) }
        }
    }

    @Test func rejectsBadHosts() {
        #expect(throws: ValidationError.emptyHost) { try Validator.validateHost("  ") }
        #expect(throws: ValidationError.invalidHost("host:22")) { try Validator.validateHost("host:22") }
        #expect(throws: ValidationError.invalidHost("a b")) { try Validator.validateHost("a b") }
        #expect(throws: ValidationError.invalidHost(".bad")) { try Validator.validateHost(".bad") }
        #expect(throws: ValidationError.invalidHost("user@host")) { try Validator.validateHost("user@host") }
    }

    @Test func portsMustBeInRange() {
        #expect(throws: ValidationError.invalidPort(0)) { try Validator.validatePort(0) }
        #expect(throws: ValidationError.invalidPort(70000)) { try Validator.validatePort(70000) }
        #expect(throws: Never.self) { try Validator.validatePort(22) }
    }

    @Test func passwordProfilesNeedACredential() {
        let machine = Machine(name: "box")
        let profile = SSHProfile(machineID: machine.id, name: "Admin", authentication: .password)
        #expect(throws: ValidationError.missingCredential(profile: "Admin")) { try Validator.validate(.ssh(profile)) }
        var fixed = profile
        fixed.credentialID = CredentialID()
        #expect(throws: Never.self) { try Validator.validate(.ssh(fixed)) }
    }

    @Test func keyFileProfilesNeedAPath() {
        let profile = SSHProfile(machineID: MachineID(), name: "Key", authentication: .keyFile(path: " "))
        #expect(throws: ValidationError.missingKeyFile(profile: "Key")) { try Validator.validate(.ssh(profile)) }
    }

    @Test func batchValidationStopsAtTheFirstProblem() {
        let change = MachineLibraryChange.batch([
            .upsertMachine(Machine(name: "ok")),
            .upsertMachine(Machine(name: "")),
        ])
        #expect(throws: ValidationError.emptyMachineName) { try Validator.validate(change) }
    }
}
