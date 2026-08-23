import ConstellationCore
import Foundation

/// Everything the editor works on for one machine. Built from the snapshot,
/// edited freely, then turned into a single batch change plus the secrets to
/// write to the vault.
struct MachineDraft {
    struct PendingSecret {
        var credentialID: CredentialID
        var secret: Secret
    }

    var machine: Machine
    var tagsText: String
    var addresses: [MachineAddress]
    var profiles: [SSHProfileDraft]
    var removedAddressIDs: Set<AddressID> = []
    var removedProfileIDs: Set<ProfileID> = []
    var removedCredentialIDs: Set<CredentialID> = []
    let isNew: Bool

    init(newMachine name: String = "") {
        let machine = Machine(name: name)
        self.machine = machine
        tagsText = ""
        addresses = [MachineAddress(machineID: machine.id, label: "LAN", host: "")]
        profiles = [SSHProfileDraft(profile: SSHProfile(machineID: machine.id))]
        isNew = true
    }

    init(editing machine: Machine, in snapshot: MachineLibrarySnapshot) {
        self.machine = machine
        tagsText = machine.tags.sorted().joined(separator: ", ")
        addresses = snapshot.addresses(for: machine.id)
        profiles = snapshot.profiles(for: machine.id).compactMap { profile in
            guard case .ssh(let ssh) = profile else { return nil }
            return SSHProfileDraft(profile: ssh, credential: ssh.credentialID.flatMap(snapshot.credential))
        }
        isNew = false
    }

    var pendingSecrets: [PendingSecret] {
        profiles.compactMap { draft in
            guard draft.needsSecret, let secret = draft.enteredSecret, !secret.isEmpty,
                  let id = draft.profile.credentialID else { return nil }
            return PendingSecret(credentialID: id, secret: Secret(secret))
        }
    }

    mutating func addAddress() {
        addresses.append(MachineAddress(machineID: machine.id, label: "", host: "", priority: addresses.count))
    }

    mutating func removeAddress(_ id: AddressID) {
        addresses.removeAll { $0.id == id }
        removedAddressIDs.insert(id)
        for index in profiles.indices where profiles[index].profile.addressSelection == .pinned(id) {
            profiles[index].profile.addressSelection = .automatic
        }
    }

    mutating func addProfile() {
        profiles.append(SSHProfileDraft(profile: SSHProfile(machineID: machine.id, name: profiles.isEmpty ? "SSH" : "SSH \(profiles.count + 1)")))
    }

    mutating func removeProfile(_ id: ProfileID) {
        guard let index = profiles.firstIndex(where: { $0.profile.id == id }) else { return }
        if let credential = profiles[index].profile.credentialID { removedCredentialIDs.insert(credential) }
        profiles.remove(at: index)
        removedProfileIDs.insert(id)
        if machine.defaultProfileID == id { machine.defaultProfileID = nil }
    }

    /// Validates and assembles the batch. Addresses take their list order as priority.
    func change() throws -> MachineLibraryChange {
        var machine = self.machine
        machine.name = machine.name.trimmingCharacters(in: .whitespaces)
        machine.tags = Set(tagsText.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty })
        if machine.defaultProfileID == nil { machine.defaultProfileID = profiles.first?.profile.id }

        var changes: [MachineLibraryChange] = [.upsertMachine(machine)]
        for (index, var address) in addresses.enumerated() {
            address.priority = index
            address.host = address.host.trimmingCharacters(in: .whitespaces)
            address.label = address.label.trimmingCharacters(in: .whitespaces)
            changes.append(.upsertAddress(address))
        }
        changes += removedAddressIDs.map { .deleteAddress($0) }

        for draft in profiles {
            let profile = try draft.resolvedProfile(machineName: machine.name)
            if let credential = draft.resolvedCredential(machineName: machine.name) {
                changes.append(.upsertCredential(credential))
            }
            changes.append(.upsertProfile(.ssh(profile)))
        }
        changes += removedProfileIDs.map { .deleteProfile($0) }
        changes += removedCredentialIDs.subtracting(Set(profiles.compactMap(\.profile.credentialID))).map { .deleteCredential($0) }

        let change = MachineLibraryChange.batch(changes)
        try Validator.validate(change)
        return change
    }
}

/// One SSH profile under edit. A typed secret becomes a vault item on save;
/// an existing secret is never shown, only replaced or removed.
struct SSHProfileDraft: Identifiable {
    enum AuthMode: String, CaseIterable, Identifiable {
        case agent, keyFile, password
        var id: String { rawValue }
        var label: String {
            switch self {
            case .agent: "SSH agent"
            case .keyFile: "Key file"
            case .password: "Password"
            }
        }
    }

    var profile: SSHProfile
    var authMode: AuthMode
    var keyFilePath: String
    /// A secret typed in this editing session, not yet in the vault. Typing one
    /// allocates the credential id once so the profile, the reference and the
    /// vault item all agree.
    var enteredSecret: String? {
        didSet {
            if let entered = enteredSecret, !entered.isEmpty, profile.credentialID == nil {
                profile.credentialID = CredentialID()
            }
        }
    }
    /// Label of the secret already in the vault, if any.
    var existingCredentialLabel: String?
    var id: ProfileID { profile.id }

    init(profile: SSHProfile, credential: CredentialReference? = nil) {
        self.profile = profile
        switch profile.authentication {
        case .agent:
            authMode = .agent
            keyFilePath = ""
        case .keyFile(let path):
            authMode = .keyFile
            keyFilePath = path
        case .password:
            authMode = .password
            keyFilePath = ""
        }
        existingCredentialLabel = credential?.label
    }

    var hasStoredSecret: Bool { existingCredentialLabel != nil && profile.credentialID != nil }

    var needsSecret: Bool { authMode == .password || authMode == .keyFile }

    mutating func removeStoredSecret() {
        profile.credentialID = nil
        existingCredentialLabel = nil
        enteredSecret = nil
    }

    func resolvedProfile(machineName: String) throws -> SSHProfile {
        var profile = self.profile
        profile.name = profile.name.trimmingCharacters(in: .whitespaces)
        profile.username = profile.username?.trimmingCharacters(in: .whitespaces)
        if profile.username?.isEmpty == true { profile.username = nil }
        switch authMode {
        case .agent:
            profile.authentication = .agent
        case .keyFile:
            profile.authentication = .keyFile(path: keyFilePath.trimmingCharacters(in: .whitespaces))
        case .password:
            profile.authentication = .password
        }
        // A credential id only survives if a secret exists for it: stored, or typed now.
        let hasSecret = hasStoredSecret || enteredSecret?.isEmpty == false
        if authMode == .agent || !hasSecret { profile.credentialID = nil }
        return profile
    }

    /// The reference to upsert when a secret was entered or the label changed.
    func resolvedCredential(machineName: String) -> CredentialReference? {
        guard authMode != .agent, enteredSecret?.isEmpty == false else { return nil }
        let resolved = (try? resolvedProfile(machineName: machineName)) ?? profile
        guard let id = resolved.credentialID else { return nil }
        let kind: CredentialKind = authMode == .password ? .password : .passphrase
        return CredentialReference(id: id, label: "\(machineName) · \(resolved.name) \(kind.displayName.lowercased())", kind: kind)
    }
}
