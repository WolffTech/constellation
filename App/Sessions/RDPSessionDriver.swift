import AppKit
import ConstellationCore
import ConstellationRDP
import ConstellationRemoteDesktop
import Foundation

struct RDPSessionRequest: Equatable, Sendable {
    var host: String
    var port: Int
    var username: String?
    var domain: String?
    var credentialID: CredentialID?
    var sharesClipboard: Bool
    /// Shown in prompts so the user knows which machine asks.
    var machineName: String
}

@MainActor
protocol RDPSessionDriving: AnyObject {
    func start(_ request: RDPSessionRequest) throws -> any RemoteDesktopSession
}

/// Starts FreeRDP sessions. NLA needs the account and password before the
/// connection opens, so anything the profile and vault cannot supply is asked
/// for up front; certificates are confirmed while FreeRDP waits.
@MainActor
final class FreeRDPSessionDriver: RDPSessionDriving {
    private let vault: any CredentialVault
    private let credentialPrompt: @MainActor (RDPCredentialPrompt) -> RDPCredentialEntry?
    private let certificatePrompt: @MainActor (RDPCertificate, String) -> RDPCertificateVerdict

    init(
        vault: any CredentialVault,
        credentialPrompt: @escaping @MainActor (RDPCredentialPrompt) -> RDPCredentialEntry? = RDPCredentialPrompter.ask,
        certificatePrompt: @escaping @MainActor (RDPCertificate, String) -> RDPCertificateVerdict = RDPCertificatePrompter.ask
    ) {
        self.vault = vault
        self.credentialPrompt = credentialPrompt
        self.certificatePrompt = certificatePrompt
    }

    func start(_ request: RDPSessionRequest) throws -> any RemoteDesktopSession {
        var username = request.username ?? ""
        var domain = request.domain ?? ""
        var password = request.credentialID.flatMap { try? vault.retrieve(id: $0) }?.withValue { $0 }

        if username.isEmpty || password == nil {
            guard let entry = credentialPrompt(RDPCredentialPrompt(
                machineName: request.machineName,
                username: request.username,
                domain: request.domain,
                hasStoredPassword: password != nil))
            else { throw RDPSessionDriverError.cancelled }
            username = entry.username
            domain = entry.domain
            if let entered = entry.password { password = entered }
        }

        let configuration = RDPSessionConfiguration(
            host: request.host,
            port: request.port,
            username: username,
            domain: domain.isEmpty ? nil : domain,
            sharesClipboard: request.sharesClipboard)
        let certificatePrompt = self.certificatePrompt
        let machineName = request.machineName
        return RDPSession(
            configuration: configuration,
            password: { password },
            verifyCertificate: { certificate in certificatePrompt(certificate, machineName) })
    }
}

enum RDPSessionDriverError: Error, LocalizedError {
    case cancelled

    var errorDescription: String? { "The connection was cancelled." }
}

struct RDPCredentialPrompt: Equatable, Sendable {
    var machineName: String
    var username: String?
    var domain: String?
    var hasStoredPassword: Bool
}

struct RDPCredentialEntry: Equatable, Sendable {
    var username: String
    var domain: String
    /// `nil` keeps the stored password.
    var password: String?
}

/// Native dialog for the account details NLA needs before connecting.
@MainActor
enum RDPCredentialPrompter {
    static func ask(_ prompt: RDPCredentialPrompt) -> RDPCredentialEntry? {
        let alert = NSAlert()
        alert.messageText = "\(prompt.machineName) needs Windows credentials"
        alert.informativeText = prompt.hasStoredPassword
            ? "Enter the account to sign in with. The saved password will be used."
            : "Enter the account and password to sign in with."
        let width: CGFloat = 300
        let rows = prompt.hasStoredPassword ? 2 : 3
        let stack = NSView(frame: NSRect(x: 0, y: 0, width: width, height: CGFloat(rows) * 30 - 6))
        var y = stack.frame.height - 24

        let user = NSTextField(frame: NSRect(x: 0, y: y, width: width, height: 24))
        user.placeholderString = "Username"
        user.stringValue = prompt.username ?? ""
        stack.addSubview(user)
        y -= 30

        let domain = NSTextField(frame: NSRect(x: 0, y: y, width: width, height: 24))
        domain.placeholderString = "Domain (optional)"
        domain.stringValue = prompt.domain ?? ""
        stack.addSubview(domain)
        y -= 30

        var password: NSSecureTextField?
        if !prompt.hasStoredPassword {
            let field = NSSecureTextField(frame: NSRect(x: 0, y: y, width: width, height: 24))
            field.placeholderString = "Password"
            stack.addSubview(field)
            password = field
        }
        alert.accessoryView = stack
        alert.window.initialFirstResponder = user.stringValue.isEmpty ? user : (password ?? user)
        alert.addButton(withTitle: "Connect")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return nil }
        return RDPCredentialEntry(
            username: user.stringValue.trimmingCharacters(in: .whitespaces),
            domain: domain.stringValue.trimmingCharacters(in: .whitespaces),
            password: password?.stringValue)
    }
}

/// Native dialog for a server certificate FreeRDP cannot verify. Accepts for
/// this session only; a Trust Store that remembers decisions comes later, and
/// nothing is written to FreeRDP's own known-hosts file.
@MainActor
enum RDPCertificatePrompter {
    static func ask(_ certificate: RDPCertificate, machineName: String) -> RDPCertificateVerdict {
        let alert = NSAlert()
        alert.alertStyle = certificate.changed ? .critical : .warning
        alert.messageText = certificate.changed
            ? "The certificate for \(machineName) has changed"
            : "Verify the identity of \(machineName)"
        var lines = [
            "The RDP server at \(certificate.host):\(certificate.port) presented a certificate that could not be verified.",
            "",
            "Subject: \(certificate.subject)",
            "Issuer: \(certificate.issuer)",
            "SHA-256: \(certificate.fingerprint)",
        ]
        if certificate.hostMismatch {
            lines.append("")
            lines.append("The certificate was issued for \(certificate.commonName), not \(certificate.host).")
        }
        if certificate.changed {
            lines.append("")
            lines.append("A different certificate was seen before. Continue only if you expected the server to change.")
        }
        alert.informativeText = lines.joined(separator: "\n")
        alert.addButton(withTitle: "Connect")
        alert.addButton(withTitle: "Cancel")
        return alert.runModal() == .alertFirstButtonReturn ? .acceptOnce : .reject
    }
}
