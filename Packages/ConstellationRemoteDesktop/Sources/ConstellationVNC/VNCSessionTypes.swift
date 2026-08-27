// SPDX-FileCopyrightText: 2026 Nick Wolff <nick@wolff.tech>
// SPDX-License-Identifier: GPL-3.0-only

import ConstellationRemoteDesktop
import Foundation

/// What a VNC session needs to start. Secrets are never part of it; the
/// session asks its credential provider when the server demands one.
public struct VNCSessionConfiguration: Sendable, Equatable {
    public var host: String
    public var port: Int
    public var username: String?
    /// Redirect the local pasteboard to and from the remote desktop. Fixed for
    /// the life of the connection.
    public var sharesClipboard: Bool
    public var colorDepth: VNCColorDepth
    /// Let other viewers stay connected instead of asking the server to
    /// disconnect them when this session starts.
    public var sharesSession: Bool
    public var keyboardMode: VNCKeyboardMode

    public init(
        host: String,
        port: Int = 5900,
        username: String? = nil,
        sharesClipboard: Bool = false,
        colorDepth: VNCColorDepth = .bits24,
        sharesSession: Bool = true,
        keyboardMode: VNCKeyboardMode = .forwardUnusedShortcuts
    ) {
        self.host = host
        self.port = port
        self.username = username
        self.sharesClipboard = sharesClipboard
        self.colorDepth = colorDepth
        self.sharesSession = sharesSession
        self.keyboardMode = keyboardMode
    }
}

/// Bits per pixel requested from the server. Fewer bits mean less bandwidth.
public enum VNCColorDepth: Int, Sendable, Codable, CaseIterable {
    case bits8 = 8
    case bits16 = 16
    case bits24 = 24
}

/// What happens to macOS keyboard shortcuts while the remote desktop has focus.
public enum VNCKeyboardMode: String, Sendable, Codable, CaseIterable {
    /// Every shortcut stays with the Mac.
    case local
    /// Shortcuts the app does not use go to the remote desktop.
    case forwardUnusedShortcuts
    /// Every shortcut goes to the remote desktop, including the app's own.
    case forwardAllShortcuts
}

/// What the server asked for during authentication.
public enum VNCCredentialRequest: Sendable, Equatable {
    case password
    case usernameAndPassword
}

public enum VNCSessionCredential: Sendable {
    case password(String)
    case usernameAndPassword(username: String, password: String)
}

/// Answers credential requests. Returning `nil` cancels authentication.
public typealias VNCCredentialProvider = @MainActor @Sendable (VNCCredentialRequest) async -> VNCSessionCredential?
