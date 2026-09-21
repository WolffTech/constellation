// SPDX-FileCopyrightText: 2026 Nick Wolff <nick@wolff.tech>
// SPDX-License-Identifier: GPL-3.0-only

import CoreGraphics
import Foundation

/// What an RDP session needs to start. The password is resolved lazily through
/// a provider at connect time so it never lives in this value.
public struct RDPSessionConfiguration: Sendable, Equatable {
    public var host: String
    public var port: Int
    public var username: String?
    public var domain: String?
    /// Initial desktop size in points; the display's backing scale turns it
    /// into pixels and a matching desktop scale (200% on Retina). With
    /// `dynamicResolution` the session asks the server to follow the view size
    /// afterwards.
    public var width: Int
    public var height: Int
    public var dynamicResolution: Bool
    /// Mirrors text between the local pasteboard and the remote clipboard,
    /// both ways. Files and images are not shared.
    public var sharesClipboard: Bool
    public var connectionQuality: RDPConnectionQuality
    /// `nil` connects directly.
    public var gateway: RDPGatewayConfiguration?

    public init(
        host: String,
        port: Int = 3389,
        username: String? = nil,
        domain: String? = nil,
        width: Int = 1280,
        height: Int = 800,
        dynamicResolution: Bool = true,
        sharesClipboard: Bool = false,
        connectionQuality: RDPConnectionQuality = .automatic,
        gateway: RDPGatewayConfiguration? = nil
    ) {
        self.host = host
        self.port = port
        self.username = username
        self.domain = domain
        self.width = width
        self.height = height
        self.dynamicResolution = dynamicResolution
        self.sharesClipboard = sharesClipboard
        self.connectionQuality = connectionQuality
        self.gateway = gateway
    }
}

/// An RD Gateway to tunnel the session through over HTTPS. The gateway, not
/// this Mac, resolves the session's `host`.
public struct RDPGatewayConfiguration: Sendable, Equatable {
    public enum Account: Sendable, Equatable {
        /// The desktop's username, domain and password also open the gateway.
        case sameAsDesktop
        /// The password comes from the session's gateway password provider.
        case separate(username: String, domain: String?)
        /// An Azure Virtual Desktop gateway: the user signs in to Entra ID
        /// through the session's sign-in handler and the gateway brokers
        /// `resource`.
        case azureVirtualDesktop(RDPAzureVirtualDesktopResource)
    }

    public var host: String
    public var port: Int
    public var account: Account

    public init(host: String, port: Int = 443, account: Account = .sameAsDesktop) {
        self.host = host
        self.port = port
        self.account = account
    }
}

/// What an Azure Virtual Desktop gateway needs to broker a desktop, as its
/// connection file gives it. The gateway rejects a resource it does not know,
/// so none of this is validated here.
public struct RDPAzureVirtualDesktopResource: Sendable, Equatable {
    public var endpointPool: String?
    public var geo: String?
    public var armPath: String?
    /// Scopes the sign-in page to the tenant; `nil` lets any account sign in.
    public var tenantID: String?
    public var diagnosticServiceURL: String?
    public var hubDiscoveryURL: String?
    public var activityHint: String?
    public var loadBalanceInfo: String?
    /// The resource's id in its workspace, sent for desktops too.
    public var application: String?
    public var desktopSignIn: RDPAzureDesktopSignIn
    public var cloud: RDPAzureCloud

    public init(
        endpointPool: String? = nil,
        geo: String? = nil,
        armPath: String? = nil,
        tenantID: String? = nil,
        diagnosticServiceURL: String? = nil,
        hubDiscoveryURL: String? = nil,
        activityHint: String? = nil,
        loadBalanceInfo: String? = nil,
        application: String? = nil,
        desktopSignIn: RDPAzureDesktopSignIn = .password,
        cloud: RDPAzureCloud = .commercial
    ) {
        self.endpointPool = endpointPool
        self.geo = geo
        self.armPath = armPath
        self.tenantID = tenantID
        self.diagnosticServiceURL = diagnosticServiceURL
        self.hubDiscoveryURL = hubDiscoveryURL
        self.activityHint = activityHint
        self.loadBalanceInfo = loadBalanceInfo
        self.application = application
        self.desktopSignIn = desktopSignIn
        self.cloud = cloud
    }
}

/// How the desktop behind an Azure Virtual Desktop gateway signs its user in.
public enum RDPAzureDesktopSignIn: Sendable, Equatable {
    case password
    /// Entra ID, so no password is needed. A desktop that refuses it is asked
    /// again with a username and password.
    case entraID
    /// A desktop known to refuse the Entra ID sign-in its connection file promises.
    case passwordInsteadOfEntraID
}

/// The Azure cloud whose Entra ID signs the user in to a gateway.
public enum RDPAzureCloud: Sendable, Equatable {
    case commercial
    case usGovernment

    /// `nil` leaves FreeRDP's defaults, which are the commercial cloud's.
    var entraHost: String? {
        switch self {
        case .commercial: nil
        case .usGovernment: "login.microsoftonline.us"
        }
    }

    /// Percent-encoded, as FreeRDP puts it in the authorize URL unchanged.
    var gatewayScope: String? {
        switch self {
        case .commercial: nil
        case .usGovernment: "https%3A%2F%2Fwww.wvd.azure.us%2F.default%20openid%20profile%20offline_access"
        }
    }
}

/// An Entra ID sign-in page to show, and how to recognise its end. FreeRDP
/// builds the page's URL and exchanges the resulting code itself.
public struct RDPEntraSignInRequest: Sendable, Equatable {
    public let authorizeURL: URL
    /// Where Entra ID sends the browser once the user has signed in. Nothing
    /// serves this address; the code is read off the navigation to it.
    public let redirectURI: String

    /// `nil` if `authorizeURL` is not a URL with a `redirect_uri`. A
    /// `loginHint` pre-fills the account on the sign-in page.
    public init?(authorizeURL: String, loginHint: String? = nil) {
        var text = authorizeURL
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-._~"))
        if let hint = loginHint?.addingPercentEncoding(withAllowedCharacters: allowed), !hint.isEmpty {
            text += "&login_hint=\(hint)"
        }
        guard let url = URL(string: text),
              let redirect = URLComponents(url: url, resolvingAgainstBaseURL: false)?
                  .queryItems?.first(where: { $0.name == "redirect_uri" })?.value,
              !redirect.isEmpty
        else { return nil }
        self.authorizeURL = url
        self.redirectURI = redirect
    }

    /// Whether a navigation to `url` ends the sign-in, with or without a code.
    public func isRedirect(_ url: URL) -> Bool {
        url.absoluteString.lowercased().hasPrefix(redirectURI.lowercased())
    }

    /// The authorization code a redirect carries, or `nil` if Entra ID
    /// reported an error instead.
    public func authorizationCode(from url: URL) -> String? {
        guard isRedirect(url) else { return nil }
        let code = URLComponents(url: url, resolvingAgainstBaseURL: false)?
            .queryItems?.first(where: { $0.name == "code" })?.value
        return code?.isEmpty == false ? code : nil
    }
}

/// Shows an Entra ID sign-in page and returns the authorization code from its
/// redirect, or `nil` if the user gave up. Runs on the main actor while
/// FreeRDP's client thread waits; cancelling the task must dismiss the page.
public typealias RDPEntraSignIn = @MainActor @Sendable (RDPEntraSignInRequest) async -> String?

/// The network profile Windows tunes its desktop experience for (wallpaper,
/// font smoothing, animations, themes). `automatic` leaves FreeRDP's defaults
/// in place; the others match xfreerdp's `/network` presets.
public enum RDPConnectionQuality: String, Sendable, Codable, CaseIterable {
    case automatic
    case lan
    case broadband
    case modem
}

/// The account a desktop signs in with.
public struct RDPDesktopCredentials: Sendable, Equatable {
    public var username: String
    public var domain: String?
    public var password: String

    public init(username: String, domain: String? = nil, password: String) {
        self.username = username
        self.domain = domain
        self.password = password
    }
}

/// Asked when a desktop refuses the Entra ID sign-in its connection file
/// promised and wants an account instead. Returning `nil` gives up.
public typealias RDPDesktopCredentialsProvider = @MainActor @Sendable () async -> RDPDesktopCredentials?

/// Resolves the account password (from Keychain in the app). Returning `nil`
/// aborts before connecting.
public typealias RDPPasswordProvider = @MainActor @Sendable () async -> String?

/// A server certificate presented for approval. Mirrors the C bridge's view.
public struct RDPCertificate: Sendable, Equatable {
    public var host: String
    public var port: Int
    public var commonName: String
    public var subject: String
    public var issuer: String
    public var fingerprint: String
    public var hostMismatch: Bool
    public var changed: Bool
    /// Presented by the RD Gateway rather than the desktop; `host` and `port`
    /// are then the gateway's.
    public var isGateway: Bool

    public init(host: String, port: Int, commonName: String, subject: String, issuer: String, fingerprint: String, hostMismatch: Bool, changed: Bool, isGateway: Bool = false) {
        self.host = host
        self.port = port
        self.commonName = commonName
        self.subject = subject
        self.issuer = issuer
        self.fingerprint = fingerprint
        self.hostMismatch = hostMismatch
        self.changed = changed
        self.isGateway = isGateway
    }
}

public enum RDPCertificateVerdict: Sendable, Equatable {
    case reject
    case acceptOnce
    /// Lets FreeRDP record the certificate in its own known-hosts file.
    case acceptAndStore
}

/// Decides whether to trust a server certificate. Runs on the main actor while
/// FreeRDP's client thread waits, which is how a native prompt pauses
/// connection setup.
public typealias RDPCertificateVerifier = @MainActor @Sendable (RDPCertificate) async -> RDPCertificateVerdict
