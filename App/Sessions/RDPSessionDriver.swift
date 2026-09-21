// SPDX-FileCopyrightText: 2026 Nick Wolff <nick@wolff.tech>
// SPDX-License-Identifier: GPL-3.0-only

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
    /// `nil` connects directly; otherwise `host` is resolved by the gateway.
    var gateway: RDPGateway?
    /// Shown in prompts so the user knows which machine asks.
    var machineName: String
}

@MainActor
protocol RDPSessionDriving: AnyObject {
    func start(_ request: RDPSessionRequest) throws -> any RemoteDesktopSession
}

/// Starts FreeRDP sessions. NLA needs the account and password before the
/// connection opens, so anything the profile and vault cannot supply is asked
/// for up front, for the desktop first and then for a gateway with its own
/// account; certificates are confirmed while FreeRDP waits, and so is an Entra
/// ID sign-in for Azure Virtual Desktop. App-wide RDP settings are read as each
/// session starts.
@MainActor
final class FreeRDPSessionDriver: RDPSessionDriving {
    private let vault: any CredentialVault
    private let trustStore: any TrustStore
    private let settings: @MainActor () -> RDPSettings
    private let credentialPrompt: @MainActor (RDPCredentialPrompt) -> RDPCredentialEntry?
    private let certificatePrompt: @MainActor (RDPCertificate, String, Bool) -> RDPTrustDecision
    private let entraSignInPrompt: @MainActor @Sendable (RDPEntraSignInRequest, String) async -> String?

    init(
        vault: any CredentialVault,
        trustStore: any TrustStore,
        settings: @escaping @MainActor () -> RDPSettings = { .default },
        credentialPrompt: @escaping @MainActor (RDPCredentialPrompt) -> RDPCredentialEntry? = RDPCredentialPrompter.ask,
        certificatePrompt: @escaping @MainActor (RDPCertificate, String, Bool) -> RDPTrustDecision = RDPCertificatePrompter.ask,
        entraSignInPrompt: @escaping @MainActor @Sendable (RDPEntraSignInRequest, String) async -> String? = RDPEntraSignInPrompter.ask
    ) {
        self.vault = vault
        self.trustStore = trustStore
        self.settings = settings
        self.credentialPrompt = credentialPrompt
        self.certificatePrompt = certificatePrompt
        self.entraSignInPrompt = entraSignInPrompt
    }

    func start(_ request: RDPSessionRequest) throws -> any RemoteDesktopSession {
        var username = request.username ?? ""
        var domain = request.domain ?? ""
        var password = request.credentialID.flatMap { try? vault.retrieve(id: $0) }?.withValue { $0 }

        // A desktop that signs in with Entra ID takes no password.
        let needsPassword = request.gateway?.azureVirtualDesktop?.desktopSignIn != .entraID
        if needsPassword, username.isEmpty || password == nil {
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

        var gateway: RDPGatewayConfiguration?
        var gatewayPassword: String?
        if let requested = request.gateway {
            let (account, password) = try gatewayAccount(for: requested, machineName: request.machineName)
            gateway = RDPGatewayConfiguration(host: requested.host, port: requested.port, account: account)
            gatewayPassword = password
        }

        let settings = settings()
        let configuration = RDPSessionConfiguration(
            host: request.host,
            port: request.port,
            username: username.isEmpty ? nil : username,
            domain: domain.isEmpty ? nil : domain,
            width: settings.desktopWidth,
            height: settings.desktopHeight,
            dynamicResolution: settings.dynamicResolution,
            sharesClipboard: request.sharesClipboard,
            connectionQuality: settings.connectionQuality,
            gateway: gateway)
        let certificatePrompt = self.certificatePrompt
        let trustStore = self.trustStore
        let machineName = request.machineName
        let entraSignInPrompt = self.entraSignInPrompt
        let credentialPrompt = self.credentialPrompt
        let session = RDPSession(
            configuration: configuration,
            password: { password },
            gatewayPassword: { [gatewayPassword] in gatewayPassword },
            verifyCertificate: { certificate in
                await resolveCertificate(certificate, machineName: machineName, trustStore: trustStore, prompt: certificatePrompt)
            },
            entraSignIn: { request in await entraSignInPrompt(request, machineName) },
            // Only a desktop that refuses its Entra ID sign-in gets here; the
            // account was not asked for up front.
            desktopCredentials: { [username, domain, password] in
                if !username.isEmpty, let password {
                    return RDPDesktopCredentials(username: username, domain: domain.isEmpty ? nil : domain, password: password)
                }
                guard let entry = credentialPrompt(RDPCredentialPrompt(
                    machineName: machineName,
                    username: username.isEmpty ? nil : username,
                    domain: domain.isEmpty ? nil : domain,
                    hasStoredPassword: password != nil)),
                    let entered = entry.password ?? password
                else { return nil }
                return RDPDesktopCredentials(username: entry.username, domain: entry.domain.isEmpty ? nil : entry.domain, password: entered)
            })
        session.displayMode = settings.defaultDisplayMode
        return session
    }

    /// Resolves a gateway's own account the way the desktop's is: profile and
    /// vault first, then a prompt for whatever is missing.
    private func gatewayAccount(
        for gateway: RDPGateway,
        machineName: String
    ) throws -> (RDPGatewayConfiguration.Account, password: String?) {
        let savedUsername: String?, savedDomain: String?, credentialID: CredentialID?
        switch gateway.credentials {
        case .sameAsDesktop:
            return (.sameAsDesktop, nil)
        case .azureVirtualDesktop(let resource):
            return (.azureVirtualDesktop(RDPAzureVirtualDesktopResource(resource, in: AVDCloud(gatewayHost: gateway.host))), nil)
        case .separate(let username, let domain, let id):
            (savedUsername, savedDomain, credentialID) = (username, domain, id)
        }
        var username = savedUsername ?? ""
        var domain = savedDomain ?? ""
        var password = credentialID.flatMap { try? vault.retrieve(id: $0) }?.withValue { $0 }
        if username.isEmpty || password == nil {
            guard let entry = credentialPrompt(RDPCredentialPrompt(
                machineName: machineName,
                username: savedUsername,
                domain: savedDomain,
                hasStoredPassword: password != nil,
                gatewayHost: gateway.host))
            else { throw RDPSessionDriverError.cancelled }
            username = entry.username
            domain = entry.domain
            if let entered = entry.password { password = entered }
        }
        return (.separate(username: username, domain: domain.isEmpty ? nil : domain), password)
    }
}

private extension RDPAzureVirtualDesktopResource {
    init(_ resource: AVDResource, in cloud: AVDCloud) {
        self.init(
            endpointPool: resource.endpointPool,
            geo: resource.geo,
            armPath: resource.armPath,
            tenantID: resource.tenantID,
            diagnosticServiceURL: resource.diagnosticServiceURL,
            hubDiscoveryURL: resource.hubDiscoveryURL,
            activityHint: resource.activityHint,
            loadBalanceInfo: resource.loadBalanceInfo,
            application: resource.application,
            desktopSignIn: RDPAzureDesktopSignIn(resource.desktopSignIn),
            cloud: cloud == .usGovernment ? .usGovernment : .commercial)
    }
}

private extension RDPAzureDesktopSignIn {
    init(_ signIn: AVDDesktopSignIn) {
        self = switch signIn {
        case .password: .password
        case .entraID: .entraID
        case .passwordInsteadOfEntraID: .passwordInsteadOfEntraID
        }
    }
}

/// Trust-on-first-use for a presented certificate: a certificate whose
/// fingerprint the store already trusts connects silently; anything else
/// prompts, and "Always Trust" records the decision for next time. Returning
/// `.acceptOnce` to FreeRDP for every accept keeps the store the single source
/// of trust rather than FreeRDP's own known-hosts file.
@MainActor
func resolveCertificate(
    _ certificate: RDPCertificate,
    machineName: String,
    trustStore: any TrustStore,
    prompt: @MainActor (RDPCertificate, String, Bool) -> RDPTrustDecision
) async -> RDPCertificateVerdict {
    let stored = try? await trustStore.trusted(host: certificate.host, port: certificate.port)
    if let stored, stored.matches(fingerprint: certificate.fingerprint) {
        return .acceptOnce
    }
    // A stored-but-different fingerprint is a changed certificate even if
    // FreeRDP (which never records ours) does not flag it.
    let changed = certificate.changed || stored != nil
    switch prompt(certificate, machineName, changed) {
    case .reject:
        return .reject
    case .connectOnce:
        return .acceptOnce
    case .trustAlways:
        try? await trustStore.trust(TrustedCertificate(
            host: certificate.host,
            port: certificate.port,
            fingerprint: certificate.fingerprint,
            subject: certificate.subject,
            issuer: certificate.issuer,
            commonName: certificate.commonName,
            trustedAt: Date()))
        return .acceptOnce
    }
}

/// What the user chose when shown an unverified certificate.
enum RDPTrustDecision: Equatable, Sendable {
    case connectOnce
    case trustAlways
    case reject
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
    /// Set when the account is for this RD Gateway rather than the desktop.
    var gatewayHost: String?
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
        if let gatewayHost = prompt.gatewayHost {
            alert.messageText = "The gateway for \(prompt.machineName) needs credentials"
            alert.informativeText = prompt.hasStoredPassword
                ? "Enter the account to sign in to \(gatewayHost) with. The saved password will be used."
                : "Enter the account and password to sign in to \(gatewayHost) with."
        } else {
            alert.messageText = "\(prompt.machineName) needs Windows credentials"
            alert.informativeText = prompt.hasStoredPassword
                ? "Enter the account to sign in with. The saved password will be used."
                : "Enter the account and password to sign in with."
        }
        let width: CGFloat = 300
        let rows = prompt.hasStoredPassword ? 2 : 3
        let stack = NSView(frame: NSRect(x: 0, y: 0, width: width, height: CGFloat(rows) * 30 - 6))
        stack.setAccessibilityRole(.group)
        stack.setAccessibilityLabel("Credentials")
        var y = stack.frame.height - 24

        let user = NSTextField(frame: NSRect(x: 0, y: y, width: width, height: 24))
        user.placeholderString = "Username"
        user.setAccessibilityLabel("Username")
        user.stringValue = prompt.username ?? ""
        stack.addSubview(user)
        y -= 30

        let domain = NSTextField(frame: NSRect(x: 0, y: y, width: width, height: 24))
        domain.placeholderString = "Domain (optional)"
        domain.setAccessibilityLabel("Domain")
        domain.stringValue = prompt.domain ?? ""
        stack.addSubview(domain)
        y -= 30

        var password: NSSecureTextField?
        if !prompt.hasStoredPassword {
            let field = NSSecureTextField(frame: NSRect(x: 0, y: y, width: width, height: 24))
            field.placeholderString = "Password"
            field.setAccessibilityLabel("Password")
            stack.addSubview(field)
            password = field
        }
        user.nextKeyView = domain
        domain.nextKeyView = password ?? user
        password?.nextKeyView = user
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

/// Native dialog for a server certificate FreeRDP cannot verify. "Always Trust"
/// records the decision in the Trust Store; "Connect Once" accepts only this
/// session. `changed` is true when the store already trusts a different
/// certificate for this server.
@MainActor
enum RDPCertificatePrompter {
    static func ask(_ certificate: RDPCertificate, machineName: String, changed: Bool) -> RDPTrustDecision {
        let alert = NSAlert()
        alert.alertStyle = changed ? .critical : .warning
        alert.messageText = changed
            ? "The certificate for \(machineName) has changed"
            : "Verify the identity of \(machineName)"
        let server = certificate.isGateway ? "RD Gateway" : "RDP server"
        var lines = [
            "The \(server) at \(certificate.host):\(certificate.port) presented a certificate that could not be verified.",
            "",
            "Subject: \(certificate.subject)",
            "Issuer: \(certificate.issuer)",
            "SHA-256: \(certificate.fingerprint)",
        ]
        if certificate.hostMismatch {
            lines.append("")
            lines.append("The certificate was issued for \(certificate.commonName), not \(certificate.host).")
        }
        if changed {
            lines.append("")
            lines.append("A different certificate was trusted before. Continue only if you expected the server to change, such as after a reinstall.")
            lines.append("Trusted certificates can be reviewed in Settings › Certificates.")
        }
        alert.informativeText = lines.joined(separator: "\n")
        // Connect Once is the default; Always Trust must be a deliberate choice,
        // especially when the certificate has changed.
        alert.addButton(withTitle: "Connect Once")
        alert.addButton(withTitle: changed ? "Replace and Always Trust" : "Always Trust")
        alert.addButton(withTitle: "Cancel")
        switch alert.runModal() {
        case .alertFirstButtonReturn: return .connectOnce
        case .alertSecondButtonReturn: return .trustAlways
        default: return .reject
        }
    }
}
