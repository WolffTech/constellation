// SPDX-FileCopyrightText: 2026 Nick Wolff <nick@wolff.tech>
// SPDX-License-Identifier: GPL-3.0-only

import Foundation
import Testing
@testable import ConstellationCore

struct AVDConnectionFileTests {
    /// Trimmed from a file the Azure Virtual Desktop web client serves.
    private let contents = """
        gatewayusagemethod:i:1
        wvd endpoint pool:s:11112222-0815-1234-abcd-123456789abc
        geo:s:EU
        armpath:s:/subscriptions/584e4430/resourcegroups/f6cfbbf2/providers/Microsoft.DesktopVirtualization/hostpools/3367af18
        aadtenantid:s:77064fd5-2634-4a0d-b310-2fa3c1d0472d
        full address:s:rdgateway-r1.wvd.microsoft.com
        diagnosticserviceurl:s:https://rdweb-g-eu-r1.wvd.microsoft.com/api/arm/DiagnosticEvents/v1
        hubdiscoverygeourl:s:https://rdweb-g-eu-r1.wvd.microsoft.com/api/arm/hubdiscovery?resourceId=16e1fb18
        resourceprovider:s:arm
        gatewayhostname:s:afdfp-rdgateway-r1.wvd.microsoft.com:443
        loadbalanceinfo:s:mth://localhost/b47b47c1/16e1fb18
        activityhint:s:ms-wvd-ep:16e1fb18?ScaleUnitPath={"Geo"%3a"EU"}
        remoteapplicationprogram:s:||40d51148-8d2c-4222-aeb3-7ad10be11650
        remotedesktopname:s:Cloud PC Enterprise
        remoteapplicationmode:i:0
        drivestoredirect:s:*
        targetisaadjoined:i:1
        enablerdsaadauth:i:0
        """

    @Test func readsTheGatewayAndResource() throws {
        let file = try AVDConnectionFile(contents: contents)
        #expect(file.address == "rdgateway-r1.wvd.microsoft.com")
        #expect(file.name == "Cloud PC Enterprise")
        #expect(file.gateway.host == "afdfp-rdgateway-r1.wvd.microsoft.com")
        #expect(file.gateway.port == 443)
        #expect(file.gateway.azureVirtualDesktop == AVDResource(
            endpointPool: "11112222-0815-1234-abcd-123456789abc",
            geo: "EU",
            armPath: "/subscriptions/584e4430/resourcegroups/f6cfbbf2/providers/Microsoft.DesktopVirtualization/hostpools/3367af18",
            tenantID: "77064fd5-2634-4a0d-b310-2fa3c1d0472d",
            diagnosticServiceURL: "https://rdweb-g-eu-r1.wvd.microsoft.com/api/arm/DiagnosticEvents/v1",
            hubDiscoveryURL: "https://rdweb-g-eu-r1.wvd.microsoft.com/api/arm/hubdiscovery?resourceId=16e1fb18",
            activityHint: #"ms-wvd-ep:16e1fb18?ScaleUnitPath={"Geo"%3a"EU"}"#,
            loadBalanceInfo: "mth://localhost/b47b47c1/16e1fb18",
            application: "||40d51148-8d2c-4222-aeb3-7ad10be11650",
            desktopSignIn: .password))
    }

    @Test func readsAFileWindowsSavedAsUTF16() throws {
        let windows = contents.replacingOccurrences(of: "\n", with: "\r\n")
            .replacingOccurrences(of: "enablerdsaadauth:i:0", with: "enablerdsaadauth:i:1")
        let file = try AVDConnectionFile(data: Data([0xFF, 0xFE]) + windows.data(using: .utf16LittleEndian)!)
        #expect(file == (try AVDConnectionFile(contents: windows)))
        #expect(file.gateway.azureVirtualDesktop?.desktopSignIn == .entraID)
    }

    @Test func aResourceSavedWithTheOldEntraFlagStillSignsInWithEntraID() throws {
        let saved = Data(#"{"tenantID":"tenant","usesEntraDesktopSignIn":true}"#.utf8)
        #expect(try JSONDecoder().decode(AVDResource.self, from: saved) == AVDResource(tenantID: "tenant", desktopSignIn: .entraID))
    }

    @Test func aGatewayWithoutAPortUsesTheDefault() throws {
        let file = try AVDConnectionFile(contents: contents.replacingOccurrences(of: ".com:443", with: ".com"))
        #expect(file.gateway.host == "afdfp-rdgateway-r1.wvd.microsoft.com")
        #expect(file.gateway.port == RDPGateway.defaultPort)
    }

    @Test func theGatewaysNameTellsItsCloud() {
        #expect(AVDCloud(gatewayHost: "afdfp-rdgateway-r1.wvd.microsoft.com") == .commercial)
        #expect(AVDCloud(gatewayHost: "rdgateway-r0.WVD.azure.us") == .usGovernment)
    }

    @Test func rejectsAnOrdinaryConnectionFile() {
        #expect(throws: AVDConnectionFileError.notAzureVirtualDesktop) {
            try AVDConnectionFile(contents: "full address:s:win.example.com\ngatewayhostname:s:gw.example.com\n")
        }
    }

    @Test func rejectsARemoteApp() {
        #expect(throws: AVDConnectionFileError.remoteApp) {
            try AVDConnectionFile(contents: contents.replacingOccurrences(of: "remoteapplicationmode:i:0", with: "remoteapplicationmode:i:1"))
        }
    }

    @Test func theResourceSurvivesTheLibrarysJSON() throws {
        let gateway = try AVDConnectionFile(contents: contents).gateway
        let profile = ConnectionProfile.rdp(RDPProfile(machineID: MachineID(), gateway: gateway))
        let decoded = try JSONDecoder().decode(ConnectionProfile.self, from: JSONEncoder().encode(profile))
        #expect(decoded == profile)
        #expect(profile.credentialIDs.isEmpty)
        #expect(profile.withoutCredential() == profile)
    }
}
