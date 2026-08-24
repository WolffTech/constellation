import ConstellationCore
import Foundation

/// Everything the editor works on for one machine. Built from the snapshot,
/// edited freely, then turned into a single batch change plus the secrets to
/// write to the vault.
struct MachineDraft: Equatable {
    struct PendingSecret {
        var credentialID: CredentialID
        var secret: Secret
    }

    var machine: Machine
    var tagsText: String
    var addresses: [MachineAddress]
    var profiles: [SSHProfileDraft]
    var vncProfiles: [VNCProfileDraft]
    var rdpProfiles: [RDPProfileDraft]
    var removedAddressIDs: Set<AddressID> = []
    var removedProfileIDs: Set<ProfileID> = []
    var removedCredentialIDs: Set<CredentialID> = []
    let isNew: Bool

    init(newMachine name: String = "") {
        let machine = Machine(name: name)
        self.machine = machine
        tagsText = ""
        addresses = [MachineAddress(machineID: machine.id, label: "", host: "")]
        profiles = [SSHProfileDraft(profile: SSHProfile(machineID: machine.id))]
        vncProfiles = []
        rdpProfiles = []
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
        vncProfiles = snapshot.profiles(for: machine.id).compactMap { profile in
            guard case .vnc(let vnc) = profile else { return nil }
            return VNCProfileDraft(profile: vnc, credential: vnc.credentialID.flatMap(snapshot.credential))
        }
        rdpProfiles = snapshot.profiles(for: machine.id).compactMap { profile in
            guard case .rdp(let rdp) = profile else { return nil }
            return RDPProfileDraft(profile: rdp, credential: rdp.credentialID.flatMap(snapshot.credential))
        }
        isNew = false
    }

    var pendingSecrets: [PendingSecret] {
        let ssh = profiles.compactMap { draft -> PendingSecret? in
            guard draft.needsSecret, let secret = draft.enteredSecret, !secret.isEmpty,
                  let id = draft.profile.credentialID else { return nil }
            return PendingSecret(credentialID: id, secret: Secret(secret))
        }
        let vnc = vncProfiles.compactMap { draft -> PendingSecret? in
            guard let secret = draft.enteredSecret, !secret.isEmpty,
                  let id = draft.profile.credentialID else { return nil }
            return PendingSecret(credentialID: id, secret: Secret(secret))
        }
        let rdp = rdpProfiles.compactMap { draft -> PendingSecret? in
            guard let secret = draft.enteredSecret, !secret.isEmpty,
                  let id = draft.profile.credentialID else { return nil }
            return PendingSecret(credentialID: id, secret: Secret(secret))
        }
        return ssh + vnc + rdp
    }

    /// Every profile id in editor order: SSH, then VNC, then RDP.
    var profileIDs: [ProfileID] { profiles.map(\.id) + vncProfiles.map(\.id) + rdpProfiles.map(\.id) }

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

    mutating func addVNCProfile() {
        vncProfiles.append(VNCProfileDraft(profile: VNCProfile(
            machineID: machine.id,
            name: vncProfiles.isEmpty ? "VNC" : "VNC \(vncProfiles.count + 1)")))
    }

    mutating func addRDPProfile() {
        rdpProfiles.append(RDPProfileDraft(profile: RDPProfile(
            machineID: machine.id,
            name: rdpProfiles.isEmpty ? "RDP" : "RDP \(rdpProfiles.count + 1)")))
    }

    mutating func removeProfile(_ id: ProfileID) {
        if let index = profiles.firstIndex(where: { $0.profile.id == id }) {
            if let credential = profiles[index].profile.credentialID { removedCredentialIDs.insert(credential) }
            profiles.remove(at: index)
        } else if let index = vncProfiles.firstIndex(where: { $0.profile.id == id }) {
            if let credential = vncProfiles[index].profile.credentialID { removedCredentialIDs.insert(credential) }
            vncProfiles.remove(at: index)
        } else if let index = rdpProfiles.firstIndex(where: { $0.profile.id == id }) {
            if let credential = rdpProfiles[index].profile.credentialID { removedCredentialIDs.insert(credential) }
            rdpProfiles.remove(at: index)
        } else {
            return
        }
        removedProfileIDs.insert(id)
        if machine.defaultProfileID == id { machine.defaultProfileID = nil }
    }

    /// Validates and assembles the batch. Addresses take their list order as priority.
    func change() throws -> MachineLibraryChange {
        var machine = self.machine
        machine.name = machine.name.trimmingCharacters(in: .whitespaces)
        machine.tags = Set(tagsText.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty })
        if machine.defaultProfileID == nil { machine.defaultProfileID = profileIDs.first }

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
        for draft in vncProfiles {
            let profile = draft.resolvedProfile()
            if let credential = draft.resolvedCredential(machineName: machine.name) {
                changes.append(.upsertCredential(credential))
            }
            changes.append(.upsertProfile(.vnc(profile)))
        }
        for draft in rdpProfiles {
            let profile = draft.resolvedProfile()
            if let credential = draft.resolvedCredential(machineName: machine.name) {
                changes.append(.upsertCredential(credential))
            }
            changes.append(.upsertProfile(.rdp(profile)))
        }
        changes += removedProfileIDs.map { .deleteProfile($0) }
        let keptCredentials = Set(
            profiles.compactMap(\.profile.credentialID)
                + vncProfiles.compactMap(\.profile.credentialID)
                + rdpProfiles.compactMap(\.profile.credentialID))
        changes += removedCredentialIDs.subtracting(keptCredentials).map { .deleteCredential($0) }

        let change = MachineLibraryChange.batch(changes)
        try Validator.validate(change)
        return change
    }
}

/// One SSH profile under edit. A typed secret becomes a vault item on save;
/// an existing secret is never shown, only replaced or removed.
struct SSHProfileDraft: Identifiable, Equatable {
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

/// One VNC profile under edit. The password is optional: without one the app
/// prompts at connect time. Apple Remote Desktop also needs the username.
struct VNCProfileDraft: Identifiable, Equatable {
    var profile: VNCProfile
    var enteredSecret: String? {
        didSet {
            if let entered = enteredSecret, !entered.isEmpty, profile.credentialID == nil {
                profile.credentialID = CredentialID()
            }
        }
    }
    var existingCredentialLabel: String?
    var id: ProfileID { profile.id }

    init(profile: VNCProfile, credential: CredentialReference? = nil) {
        self.profile = profile
        existingCredentialLabel = credential?.label
    }

    var hasStoredSecret: Bool { existingCredentialLabel != nil && profile.credentialID != nil }

    mutating func removeStoredSecret() {
        profile.credentialID = nil
        existingCredentialLabel = nil
        enteredSecret = nil
    }

    func resolvedProfile() -> VNCProfile {
        var profile = self.profile
        profile.name = profile.name.trimmingCharacters(in: .whitespaces)
        profile.username = profile.username?.trimmingCharacters(in: .whitespaces)
        if profile.username?.isEmpty == true { profile.username = nil }
        let hasSecret = hasStoredSecret || enteredSecret?.isEmpty == false
        if !hasSecret { profile.credentialID = nil }
        return profile
    }

    func resolvedCredential(machineName: String) -> CredentialReference? {
        guard enteredSecret?.isEmpty == false, let id = resolvedProfile().credentialID else { return nil }
        return CredentialReference(id: id, label: "\(machineName) · \(resolvedProfile().name) VNC password", kind: .password)
    }
}

/// One RDP profile under edit. Username and domain are optional: NLA needs
/// them, so whatever is missing is asked for at connect time.
struct RDPProfileDraft: Identifiable, Equatable {
    var profile: RDPProfile
    var enteredSecret: String? {
        didSet {
            if let entered = enteredSecret, !entered.isEmpty, profile.credentialID == nil {
                profile.credentialID = CredentialID()
            }
        }
    }
    var existingCredentialLabel: String?
    var id: ProfileID { profile.id }

    init(profile: RDPProfile, credential: CredentialReference? = nil) {
        self.profile = profile
        existingCredentialLabel = credential?.label
    }

    var hasStoredSecret: Bool { existingCredentialLabel != nil && profile.credentialID != nil }

    mutating func removeStoredSecret() {
        profile.credentialID = nil
        existingCredentialLabel = nil
        enteredSecret = nil
    }

    func resolvedProfile() -> RDPProfile {
        var profile = self.profile
        profile.name = profile.name.trimmingCharacters(in: .whitespaces)
        profile.username = profile.username?.trimmingCharacters(in: .whitespaces)
        if profile.username?.isEmpty == true { profile.username = nil }
        profile.domain = profile.domain?.trimmingCharacters(in: .whitespaces)
        if profile.domain?.isEmpty == true { profile.domain = nil }
        let hasSecret = hasStoredSecret || enteredSecret?.isEmpty == false
        if !hasSecret { profile.credentialID = nil }
        return profile
    }

    func resolvedCredential(machineName: String) -> CredentialReference? {
        guard enteredSecret?.isEmpty == false, let id = resolvedProfile().credentialID else { return nil }
        return CredentialReference(id: id, label: "\(machineName) · \(resolvedProfile().name) RDP password", kind: .password)
    }
}
