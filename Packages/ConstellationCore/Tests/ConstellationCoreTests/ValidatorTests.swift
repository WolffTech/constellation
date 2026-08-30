// SPDX-FileCopyrightText: 2026 Nick Wolff <nick@wolff.tech>
// SPDX-License-Identifier: GPL-3.0-only

import Foundation
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

    @Test func addressLabelsAreOptionalAndFallBackToTheKind() throws {
        let address = MachineAddress(machineID: MachineID(), label: "  ", host: "10.0.0.5", kind: .tailscale)
        try Validator.validate(address)
        #expect(address.displayLabel == "Tailscale")
        #expect(MachineAddress(machineID: MachineID(), label: "Office", host: "x").displayLabel == "Office")
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

    @Test func groupsNeedAName() {
        #expect(throws: ValidationError.emptyGroupName) { try Validator.validate(.upsertGroup(MachineGroup(name: "  "))) }
        #expect(throws: Never.self) { try Validator.validate(.moveGroup(GroupID(), position: 3)) }
    }

    @Test func machinesDecodeWithoutGroupFields() throws {
        let json = """
        {"id":"\(MachineID())","name":"alpha","notes":"","tags":["a"],"isFavorite":false}
        """
        let machine = try JSONDecoder().decode(Machine.self, from: Data(json.utf8))
        #expect(machine.groupID == nil)
        #expect(machine.position == 0)
    }

    @Test func batchValidationStopsAtTheFirstProblem() {
        let change = MachineLibraryChange.batch([
            .upsertMachine(Machine(name: "ok")),
            .upsertMachine(Machine(name: "")),
        ])
        #expect(throws: ValidationError.emptyMachineName) { try Validator.validate(change) }
    }
}
