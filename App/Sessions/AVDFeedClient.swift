// SPDX-FileCopyrightText: 2026 Nick Wolff <nick@wolff.tech>
// SPDX-License-Identifier: GPL-3.0-only

import ConstellationCore
import ConstellationRDP
import CryptoKit
import Foundation

enum AVDFeedClientError: Error, Equatable, LocalizedError {
    case signInCancelled
    case signInRefused(String)
    case requestFailed(status: Int, detail: String)
    case noDesktops

    var errorDescription: String? {
        switch self {
        case .signInCancelled: "The sign-in was cancelled."
        case .signInRefused(let detail): "Microsoft Entra ID refused the sign-in. \(detail)"
        case .requestFailed(let status, let detail): "Azure Virtual Desktop answered with an error (\(status)). \(detail)"
        case .noDesktops: "This account has no Azure Virtual Desktop desktops assigned."
        }
    }
}

/// Signs in to Entra ID and reads the account's Azure Virtual Desktop
/// workspace, the way the Windows App does after it is given the feed
/// discovery address. The token lives only as long as this value; connecting
/// to a desktop signs in again through FreeRDP.
@MainActor
final class AVDFeedClient {
    typealias Transport = @Sendable (URLRequest) async throws -> (Data, URLResponse)

    /// Microsoft's own Remote Desktop client registration, which FreeRDP also
    /// uses. The feed service names it in its authentication challenge.
    static let clientID = "a85cf173-4192-42f8-81fa-777a763e6e2c"
    static let scope = "https://www.wvd.microsoft.com/.default openid profile"
    static let redirectURI = "https://login.microsoftonline.com/common/oauth2/nativeclient"
    static let authority = "https://login.microsoftonline.com/organizations/oauth2/v2.0"
    /// The feed service turns away clients it does not know with
    /// INCOMPATIBLE_CLIENT_VERSION, so this is the web client's identifier.
    static let userAgent = "com.microsoft.rdc.html/2.0.79.2 rdhtml-sdk/2.0.4"

    private let transport: Transport
    private let signInPrompt: @MainActor @Sendable (RDPEntraSignInRequest, String) async -> String?
    private var accessToken: String?

    init(
        transport: @escaping Transport = { try await URLSession.shared.data(for: $0) },
        signInPrompt: @escaping @MainActor @Sendable (RDPEntraSignInRequest, String) async -> String? = RDPEntraSignInPrompter.ask
    ) {
        self.transport = transport
        self.signInPrompt = signInPrompt
    }

    /// Signs in, then lists the desktops in every tenant the account belongs to.
    func desktops(loginHint: String?) async throws -> [AVDFeed.Desktop] {
        let token = try await signIn(loginHint: loginHint)
        let discovery = try await get(AVDFeed.discoveryURL, accept: AVDFeed.discoveryContentType, token: token)
        var desktops: [AVDFeed.Desktop] = []
        for feed in try AVDFeed.tenantFeeds(fromDiscovery: discovery) {
            let data = try await get(feed.url, accept: AVDFeed.feedContentType, token: token)
            desktops += try AVDFeed.desktops(fromFeed: data, of: feed)
        }
        if desktops.isEmpty { throw AVDFeedClientError.noDesktops }
        return desktops
    }

    /// Downloads a desktop's connection file with the token `desktops` signed in for.
    func connectionFile(for desktop: AVDFeed.Desktop) async throws -> AVDConnectionFile {
        guard let accessToken else { throw AVDFeedClientError.signInCancelled }
        return try AVDConnectionFile(data: try await get(desktop.connectionFileURL, accept: "*/*", token: accessToken))
    }

    // MARK: Sign-in (authorization code with PKCE)

    private func signIn(loginHint: String?) async throws -> String {
        let verifier = Self.randomVerifier()
        guard let request = RDPEntraSignInRequest(authorizeURL: Self.authorizeURL(verifier: verifier), loginHint: loginHint),
              let code = await signInPrompt(request, "Azure Virtual Desktop")
        else { throw AVDFeedClientError.signInCancelled }

        var exchange = URLRequest(url: URL(string: "\(Self.authority)/token")!)
        exchange.httpMethod = "POST"
        exchange.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        exchange.httpBody = Data(Self.form([
            "grant_type": "authorization_code", "client_id": Self.clientID, "code": code,
            "redirect_uri": Self.redirectURI, "scope": Self.scope, "code_verifier": verifier,
        ]).utf8)
        let (data, _) = try await transport(exchange)
        let response = try JSONDecoder().decode(TokenResponse.self, from: data)
        guard let token = response.access_token else {
            throw AVDFeedClientError.signInRefused(response.error_description ?? response.error ?? "")
        }
        accessToken = token
        return token
    }

    static func authorizeURL(verifier: String) -> String {
        let challenge = Data(SHA256.hash(data: Data(verifier.utf8))).base64URLEncodedString()
        return "\(authority)/authorize?" + form([
            "client_id": clientID, "response_type": "code", "redirect_uri": redirectURI, "scope": scope,
            "code_challenge": challenge, "code_challenge_method": "S256", "prompt": "select_account",
        ])
    }

    private static func randomVerifier() -> String {
        Data((0..<32).map { _ in UInt8.random(in: .min ... .max) }).base64URLEncodedString()
    }

    private static func form(_ fields: KeyValuePairs<String, String>) -> String {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-._~"))
        return fields.map { "\($0)=\($1.addingPercentEncoding(withAllowedCharacters: allowed) ?? "")" }.joined(separator: "&")
    }

    private struct TokenResponse: Decodable {
        var access_token: String?
        var error: String?
        var error_description: String?
    }

    // MARK: Feed requests

    private func get(_ url: URL, accept: String, token: String) async throws -> Data {
        var request = URLRequest(url: url)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue(accept, forHTTPHeaderField: "Accept")
        request.setValue(Self.userAgent, forHTTPHeaderField: "User-Agent")
        request.setValue(Self.userAgent, forHTTPHeaderField: "X-MS-User-Agent")
        let (data, response) = try await transport(request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard status == 200 else {
            throw AVDFeedClientError.requestFailed(status: status, detail: String(decoding: data.prefix(300), as: UTF8.self))
        }
        return data
    }
}

private extension Data {
    func base64URLEncodedString() -> String {
        base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}
