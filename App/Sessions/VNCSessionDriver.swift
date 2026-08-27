// SPDX-FileCopyrightText: 2026 Nick Wolff <nick@wolff.tech>
// SPDX-License-Identifier: GPL-3.0-only

import AppKit
import ConstellationCore
import ConstellationRemoteDesktop
import ConstellationVNC
import Foundation

struct VNCSessionRequest: Equatable, Sendable {
    var host: String
    var port: Int
    var username: String?
    var credentialID: CredentialID?
    var sharesClipboard: Bool
    /// Shown in the credential prompt so the user knows which machine asks.
    var machineName: String
}

@MainActor
protocol VNCSessionDriving: AnyObject {
    func start(_ request: VNCSessionRequest) throws -> any RemoteDesktopSession
}

/// Starts RoyalVNCKit sessions. The stored password is offered first; the
/// user is asked only when there is none or the server also wants a username
/// the profile lacks. App-wide VNC settings are read as each session starts.
@MainActor
final class RoyalVNCSessionDriver: VNCSessionDriving {
    private let vault: any CredentialVault
    private let settings: @MainActor () -> VNCSettings
    private let prompt: @MainActor (VNCCredentialPrompt) -> VNCSessionCredential?

    init(
        vault: any CredentialVault,
        settings: @escaping @MainActor () -> VNCSettings = { .default },
        prompt: @escaping @MainActor (VNCCredentialPrompt) -> VNCSessionCredential? = VNCCredentialPrompter.ask
    ) {
        self.vault = vault
        self.settings = settings
        self.prompt = prompt
    }

    func start(_ request: VNCSessionRequest) throws -> any RemoteDesktopSession {
        let settings = settings()
        let configuration = VNCSessionConfiguration(
            host: request.host,
            port: request.port,
            username: request.username,
            sharesClipboard: request.sharesClipboard,
            colorDepth: settings.colorDepth,
            sharesSession: settings.sharesSession,
            keyboardMode: settings.keyboardMode)
        let vault = self.vault
        let prompt = self.prompt
        let session = RoyalVNCSession(configuration: configuration) { kind in
            let stored = request.credentialID.flatMap { try? vault.retrieve(id: $0) }?.withValue { $0 }
            switch kind {
            case .password:
                if let stored { return .password(stored) }
            case .usernameAndPassword:
                if let stored, let username = request.username, !username.isEmpty {
                    return .usernameAndPassword(username: username, password: stored)
                }
            }
            return prompt(VNCCredentialPrompt(
                kind: kind,
                machineName: request.machineName,
                username: request.username,
                hasStoredPassword: stored != nil))
        }
        session.displayMode = settings.defaultDisplayMode
        return session
    }
}

struct VNCCredentialPrompt: Equatable, Sendable {
    var kind: VNCCredentialRequest
    var machineName: String
    var username: String?
    var hasStoredPassword: Bool
}

/// Native dialog for VNC credentials the vault cannot answer.
@MainActor
enum VNCCredentialPrompter {
    static func ask(_ prompt: VNCCredentialPrompt) -> VNCSessionCredential? {
        let alert = NSAlert()
        alert.messageText = "\(prompt.machineName) needs VNC credentials"
        alert.informativeText = switch prompt.kind {
        case .password: "Enter the VNC password."
        case .usernameAndPassword: "The server uses Apple Remote Desktop or MS-Logon authentication. Enter the account name and password."
        }
        let width: CGFloat = 280
        let password = NSSecureTextField(frame: NSRect(x: 0, y: 0, width: width, height: 24))
        password.placeholderString = "Password"
        password.setAccessibilityLabel("Password")
        var username: NSTextField?
        switch prompt.kind {
        case .password:
            alert.accessoryView = password
            alert.window.initialFirstResponder = password
        case .usernameAndPassword:
            let user = NSTextField(frame: NSRect(x: 0, y: 30, width: width, height: 24))
            user.placeholderString = "Username"
            user.setAccessibilityLabel("Username")
            user.stringValue = prompt.username ?? ""
            let stack = NSView(frame: NSRect(x: 0, y: 0, width: width, height: 54))
            stack.setAccessibilityRole(.group)
            stack.setAccessibilityLabel("Credentials")
            stack.addSubview(user)
            stack.addSubview(password)
            user.nextKeyView = password
            password.nextKeyView = user
            alert.accessoryView = stack
            alert.window.initialFirstResponder = user.stringValue.isEmpty ? user : password
            username = user
        }
        alert.addButton(withTitle: "Connect")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return nil }
        switch prompt.kind {
        case .password:
            return .password(password.stringValue)
        case .usernameAndPassword:
            return .usernameAndPassword(username: username?.stringValue ?? "", password: password.stringValue)
        }
    }
}
