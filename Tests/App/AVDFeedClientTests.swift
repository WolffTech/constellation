// SPDX-FileCopyrightText: 2026 Nick Wolff <nick@wolff.tech>
// SPDX-License-Identifier: GPL-3.0-only

import ConstellationCore
import ConstellationRDP
import CryptoKit
import Foundation
import Testing
@testable import Constellation

@MainActor
struct AVDFeedClientTests {
    /// Answers by URL and records what was asked.
    private final class FakeService: @unchecked Sendable {
        private let lock = NSLock()
        private var recorded: [URLRequest] = []
        var responses: [String: (Int, String)] = [:]

        var requests: [URLRequest] { lock.withLock { recorded } }

        func respond(to request: URLRequest) throws -> (Data, URLResponse) {
            lock.withLock { recorded.append(request) }
            let url = request.url!
            let (status, body) = responses[url.absoluteString] ?? (404, "")
            return (Data(body.utf8), HTTPURLResponse(url: url, statusCode: status, httpVersion: nil, headerFields: nil)!)
        }
    }

    private let tokenURL = "https://login.microsoftonline.com/organizations/oauth2/v2.0/token"
    private let feedURL = "https://rdweb-g-us-r0.wvd.microsoft.com/api/arm/hubs/feed"
    private let fileURL = "https://rdweb-g-us-r0.wvd.microsoft.com/api/arm/hubs/resource/desk1.rdp"

    private func workingService() -> FakeService {
        let service = FakeService()
        service.responses = [
            tokenURL: (200, #"{"access_token":"tok123","token_type":"Bearer"}"#),
            AVDFeed.discoveryURL.absoluteString: (200, #"<TenantFeedURLs><TenantFeedURL FeedURL="\#(feedURL)" TenantDisplayName="Contoso"/></TenantFeedURLs>"#),
            feedURL: (200, """
                <ResourceCollection><Publisher><Resources><Resource ID="desk1" Title="SessionDesktop" Type="Desktop">
                <HostingTerminalServers><HostingTerminalServer><ResourceFile URL="\(fileURL)"/></HostingTerminalServer></HostingTerminalServers>
                </Resource></Resources></Publisher></ResourceCollection>
                """),
            fileURL: (200, "full address:s:rdgateway.wvd.microsoft.com\nresourceprovider:s:arm\ngatewayhostname:s:afdfp-rdgateway.wvd.microsoft.com:443\n"),
        ]
        return service
    }

    @Test func signsInThenReadsTheWorkspaceAndTheDesktopsFile() async throws {
        let service = workingService()
        var signIn: RDPEntraSignInRequest?
        let client = AVDFeedClient(
            transport: { try service.respond(to: $0) },
            signInPrompt: { request, _ in
                signIn = request
                return "code-1"
            })

        let desktops = try await client.desktops(loginHint: "nick@example.com")
        #expect(desktops.map(\.title) == ["SessionDesktop"])
        let file = try await client.connectionFile(for: desktops[0])
        #expect(file.gateway.host == "afdfp-rdgateway.wvd.microsoft.com")

        // The token request proves the code with the verifier behind the page's challenge.
        let authorizeURL = try #require(signIn).authorizeURL
        let page = try #require(URLComponents(url: authorizeURL, resolvingAgainstBaseURL: false)?.queryItems)
        #expect(page.first { $0.name == "login_hint" }?.value == "nick@example.com")
        let exchange = try #require(service.requests.first)
        let body = try #require(exchange.httpBody)
        let form = try #require(URLComponents(string: "?" + String(decoding: body, as: UTF8.self))?.queryItems)
        #expect(form.first { $0.name == "code" }?.value == "code-1")
        let verifier = try #require(form.first { $0.name == "code_verifier" }?.value)
        let challenge = Data(SHA256.hash(data: Data(verifier.utf8))).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
        #expect(page.first { $0.name == "code_challenge" }?.value == challenge)

        // Every feed request carries the token and the client identifier the service insists on.
        for request in service.requests.dropFirst() {
            #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer tok123")
            #expect(request.value(forHTTPHeaderField: "X-MS-User-Agent") == AVDFeedClient.userAgent)
        }
        #expect(service.requests.map(\.url?.absoluteString) == [tokenURL, AVDFeed.discoveryURL.absoluteString, feedURL, fileURL])
    }

    @Test func aClosedSignInWindowAsksTheServiceNothing() async {
        let service = workingService()
        let client = AVDFeedClient(transport: { try service.respond(to: $0) }, signInPrompt: { _, _ in nil })
        await #expect(throws: AVDFeedClientError.signInCancelled) { try await client.desktops(loginHint: nil) }
        #expect(service.requests.isEmpty)
    }

    @Test func reportsWhyEntraIDRefusedTheSignIn() async {
        let service = workingService()
        service.responses[tokenURL] = (400, #"{"error":"invalid_grant","error_description":"AADSTS53003: Access has been blocked by Conditional Access policies."}"#)
        let client = AVDFeedClient(transport: { try service.respond(to: $0) }, signInPrompt: { _, _ in "code-1" })
        await #expect(throws: AVDFeedClientError.signInRefused("AADSTS53003: Access has been blocked by Conditional Access policies.")) {
            try await client.desktops(loginHint: nil)
        }
    }

    @Test func reportsAFeedErrorWithTheServicesOwnWords() async {
        let service = workingService()
        service.responses[AVDFeed.discoveryURL.absoluteString] = (400, "INCOMPATIBLE_CLIENT_VERSION")
        let client = AVDFeedClient(transport: { try service.respond(to: $0) }, signInPrompt: { _, _ in "code-1" })
        await #expect(throws: AVDFeedClientError.requestFailed(status: 400, detail: "INCOMPATIBLE_CLIENT_VERSION")) {
            try await client.desktops(loginHint: nil)
        }
    }

    @Test func anAccountWithOnlyRemoteAppsHasNoDesktops() async {
        let service = workingService()
        service.responses[feedURL] = (200, "<ResourceCollection/>")
        let client = AVDFeedClient(transport: { try service.respond(to: $0) }, signInPrompt: { _, _ in "code-1" })
        await #expect(throws: AVDFeedClientError.noDesktops) { try await client.desktops(loginHint: nil) }
    }
}
