// SPDX-FileCopyrightText: 2026 Nick Wolff <nick@wolff.tech>
// SPDX-License-Identifier: GPL-3.0-only

import Foundation
import Testing
@testable import ConstellationRDP

struct RDPEntraSignInTests {
    /// The shape FreeRDP builds for an Azure Virtual Desktop gateway.
    private let authorizeURL = "https://login.microsoftonline.com/77064fd5/oauth2/v2.0/authorize"
        + "?client_id=a85cf173-4192-42f8-81fa-777a763e6e2c&response_type=code"
        + "&scope=https%3A%2F%2Fwww.wvd.microsoft.com%2F.default%20openid%20profile%20offline_access"
        + "&redirect_uri=https%3A%2F%2Flogin.microsoftonline.com%2F77064fd5%2Foauth2%2Fnativeclient"

    @Test func readsTheRedirectFromTheAuthorizeURL() throws {
        let request = try #require(RDPEntraSignInRequest(authorizeURL: authorizeURL))
        #expect(request.redirectURI == "https://login.microsoftonline.com/77064fd5/oauth2/nativeclient")
        #expect(request.authorizeURL.absoluteString == authorizeURL)
    }

    @Test func rejectsAnAuthorizeURLWithoutARedirect() {
        #expect(RDPEntraSignInRequest(authorizeURL: "https://login.microsoftonline.com/common?client_id=x") == nil)
    }

    @Test func addsTheAccountAsALoginHint() throws {
        let request = try #require(RDPEntraSignInRequest(authorizeURL: authorizeURL, loginHint: "nick+avd@example.com"))
        #expect(request.authorizeURL.absoluteString == authorizeURL + "&login_hint=nick%2Bavd%40example.com")
    }

    @Test func takesTheCodeFromTheRedirectOnly() throws {
        let request = try #require(RDPEntraSignInRequest(authorizeURL: authorizeURL))
        let redirect = try #require(URL(string: "https://login.microsoftonline.com/77064fd5/oauth2/nativeclient?code=0.AAA-bbb&session_state=1"))
        #expect(request.authorizationCode(from: redirect) == "0.AAA-bbb")

        // A page on the way there that happens to carry a `code` parameter.
        let signInPage = try #require(URL(string: "https://login.microsoftonline.com/77064fd5/login?code=nope"))
        #expect(!request.isRedirect(signInPage))
        #expect(request.authorizationCode(from: signInPage) == nil)
    }

    @Test func anErrorRedirectEndsTheSignInWithoutACode() throws {
        let request = try #require(RDPEntraSignInRequest(authorizeURL: authorizeURL))
        let denied = try #require(URL(string: "https://login.microsoftonline.com/77064fd5/oauth2/nativeclient?error=access_denied"))
        #expect(request.isRedirect(denied))
        #expect(request.authorizationCode(from: denied) == nil)
    }

    @Test func matchesTheBrokerSchemeADesktopSignInRedirectsTo() throws {
        let url = "https://login.microsoftonline.com/common/oauth2/v2.0/authorize?client_id=x"
            + "&redirect_uri=ms-appx-web%3a%2f%2fMicrosoft.AAD.BrokerPlugin%2fvm1.example.com"
        let request = try #require(RDPEntraSignInRequest(authorizeURL: url))
        let redirect = try #require(URL(string: "ms-appx-web://Microsoft.AAD.BrokerPlugin/vm1.example.com?code=abc"))
        #expect(request.authorizationCode(from: redirect) == "abc")
    }
}
