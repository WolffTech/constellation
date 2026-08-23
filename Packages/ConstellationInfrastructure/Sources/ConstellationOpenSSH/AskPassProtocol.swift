import Foundation

/// Wire format between `constellation-askpass` and the app, carried over a
/// per-app-instance `CFMessagePort`. Secrets cross this boundary once, in the
/// reply, and are never logged.
public enum AskPass {
    /// What ssh is asking for. Derived from `SSH_ASKPASS_PROMPT`.
    public enum PromptKind: String, Codable, Sendable {
        /// A secret: password or key passphrase.
        case secret
        /// A yes/no question, for example an unknown host key.
        case confirm
        /// Informational text with no answer expected.
        case none
    }

    public struct Request: Codable, Sendable, Equatable {
        /// Matches the token the app placed in the ssh environment.
        public var token: String
        public var kind: PromptKind
        /// ssh's prompt text, for example `temp@192.0.2.18's password: `.
        public var prompt: String
        /// Opaque id the app can resolve against its vault. `nil` means ask the user.
        public var credentialID: String?

        public init(token: String, kind: PromptKind, prompt: String, credentialID: String?) {
            self.token = token
            self.kind = kind
            self.prompt = prompt
            self.credentialID = credentialID
        }
    }

    public enum Response: Codable, Sendable, Equatable {
        case secret(String)
        case confirmed(Bool)
        case denied

        /// What the helper prints to stdout for ssh.
        public var sshOutput: String? {
            switch self {
            case .secret(let value): value
            case .confirmed(true): "yes"
            case .confirmed(false): "no"
            case .denied: nil
            }
        }
    }

    /// Environment variables the app sets on the ssh command.
    public enum EnvironmentKey {
        public static let port = "CONSTELLATION_ASKPASS_PORT"
        public static let token = "CONSTELLATION_ASKPASS_TOKEN"
        public static let credentialID = "CONSTELLATION_CREDENTIAL_ID"
    }

    /// Message port name for one service instance. Unique per instance, not
    /// just per process, so a test host running beside the app gets its own.
    public static func portName(pid: pid_t, instance: UUID) -> String {
        "tech.wolff.Constellation.askpass.\(pid).\(instance.uuidString)"
    }

    /// Classifies a prompt. OpenSSH sets `SSH_ASKPASS_PROMPT` only for agent
    /// permission prompts; the host-key question arrives with it unset, so the
    /// prompt text decides. Anything that is not clearly a password or
    /// passphrase request is treated as a confirmation and never answered from
    /// the vault.
    public static func promptKind(sshPromptVariable value: String?, promptText: String) -> PromptKind {
        switch value {
        case "confirm": return .confirm
        case "none": return .none
        default: break
        }
        let text = promptText.lowercased()
        if text.contains("(yes/no") || text.contains("type 'yes'") || text.contains("type \"yes\"") {
            return .confirm
        }
        if text.contains("password") || text.contains("passphrase") {
            return .secret
        }
        return .confirm
    }
}
