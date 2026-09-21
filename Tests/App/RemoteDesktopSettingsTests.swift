// SPDX-FileCopyrightText: 2026 Nick Wolff <nick@wolff.tech>
// SPDX-License-Identifier: GPL-3.0-only

import ConstellationCore
import ConstellationRDP
import ConstellationRemoteDesktop
import ConstellationVNC
import Foundation
import Testing
@testable import Constellation

@MainActor
struct GeneralSettingsTests {
    @Test func generalSettingsShowTheLocalMachineByDefaultAndPersistChanges() throws {
        let suiteName = "GeneralSettingsTests-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let settings = GeneralSettingsStore(defaults: defaults)
        #expect(settings.value.showsLocalMachine)
        settings.update { $0.showsLocalMachine = false }
        #expect(!GeneralSettingsStore(defaults: defaults).value.showsLocalMachine)
    }
}

@MainActor
struct RemoteDesktopSettingsTests {
    @Test func settingsPersistAndResetToDefaults() throws {
        let suiteName = "RemoteDesktopSettingsTests-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let vnc = VNCSettingsStore(defaults: defaults)
        #expect(vnc.value == .default)
        vnc.update { $0.colorDepth = .bits8; $0.defaultDisplayMode = .actualSize }
        #expect(VNCSettingsStore(defaults: defaults).value == vnc.value)

        let rdp = RDPSettingsStore(defaults: defaults)
        rdp.update { $0.dynamicResolution = false; $0.desktopWidth = 1920; $0.connectionQuality = .modem }
        #expect(RDPSettingsStore(defaults: defaults).value == rdp.value)

        rdp.reset()
        #expect(RDPSettingsStore(defaults: defaults).value == .default)
        #expect(VNCSettingsStore(defaults: defaults).value.colorDepth == .bits8)
    }

    @Test func unreadableSettingsFallBackToDefaults() throws {
        let suiteName = "RemoteDesktopSettingsTests-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        defaults.set(Data("{\"colorDepth\": 99}".utf8), forKey: VNCSettings.defaultsKey)

        #expect(VNCSettingsStore(defaults: defaults).value == .default)
    }

    @Test func vncDriverAppliesTheSettingsToEachSession() throws {
        let settings = VNCSettings(colorDepth: .bits16, sharesSession: false, keyboardMode: .local, defaultDisplayMode: .actualSize)
        let driver = RoyalVNCSessionDriver(vault: InMemoryCredentialVault(), settings: { settings }, prompt: { _ in nil })

        let session = try #require(driver.start(VNCSessionRequest(
            host: "vnc.box", port: 5901, username: "nick", credentialID: nil, sharesClipboard: true, machineName: "screen")) as? RoyalVNCSession)

        #expect(session.configuration == VNCSessionConfiguration(
            host: "vnc.box", port: 5901, username: "nick", sharesClipboard: true,
            colorDepth: .bits16, sharesSession: false, keyboardMode: .local))
        #expect(session.displayMode == .actualSize)
    }

    @Test func rdpDriverAppliesTheSettingsToEachSession() throws {
        let settings = RDPSettings(defaultDisplayMode: .actualSize, dynamicResolution: false, desktopWidth: 1920, desktopHeight: 1080, connectionQuality: .lan)
        let driver = FreeRDPSessionDriver(
            vault: InMemoryCredentialVault(),
            trustStore: InMemoryTrustStore(),
            settings: { settings },
            credentialPrompt: { _ in RDPCredentialEntry(username: "nick", domain: "", password: "secret") },
            certificatePrompt: { _, _, _ in .reject })

        let session = try #require(driver.start(RDPSessionRequest(
            host: "win.box", port: 3390, username: nil, domain: nil, credentialID: nil, sharesClipboard: true, machineName: "win")) as? RDPSession)

        #expect(session.configuration == RDPSessionConfiguration(
            host: "win.box", port: 3390, username: "nick", domain: nil,
            width: 1920, height: 1080, dynamicResolution: false, sharesClipboard: true, connectionQuality: .lan))
        #expect(session.displayMode == .actualSize)
    }

    @Test func rdpDriverAsksForAGatewayAccountTheProfileLacks() throws {
        let vault = InMemoryCredentialVault()
        let desktopCredential = CredentialID()
        try vault.store(Secret("pa55"), for: desktopCredential)
        var prompts: [RDPCredentialPrompt] = []
        let driver = FreeRDPSessionDriver(
            vault: vault,
            trustStore: InMemoryTrustStore(),
            credentialPrompt: { prompt in
                prompts.append(prompt)
                return RDPCredentialEntry(username: "dmz-nick", domain: "DMZ", password: "gw55")
            },
            certificatePrompt: { _, _, _ in .reject })
        let gateway = RDPGateway(host: "gw.example.com", port: 8443, credentials: .separate(username: nil, domain: nil, credentialID: nil))

        let session = try #require(driver.start(RDPSessionRequest(
            host: "win.corp.internal", port: 3389, username: "nick", domain: nil, credentialID: desktopCredential,
            sharesClipboard: false, gateway: gateway, machineName: "win")) as? RDPSession)

        // The desktop account is complete, so only the gateway's is asked for.
        #expect(prompts == [RDPCredentialPrompt(machineName: "win", username: nil, domain: nil, hasStoredPassword: false, gatewayHost: "gw.example.com")])
        #expect(session.configuration.gateway == RDPGatewayConfiguration(
            host: "gw.example.com", port: 8443, account: .separate(username: "dmz-nick", domain: "DMZ")))
    }

    @Test func rdpDriverReusesTheDesktopAccountForTheGatewayWithoutPrompting() throws {
        let vault = InMemoryCredentialVault()
        let desktopCredential = CredentialID()
        try vault.store(Secret("pa55"), for: desktopCredential)
        let driver = FreeRDPSessionDriver(
            vault: vault,
            trustStore: InMemoryTrustStore(),
            credentialPrompt: { _ in
                Issue.record("nothing is missing, so nothing should be asked")
                return nil
            },
            certificatePrompt: { _, _, _ in .reject })

        let session = try #require(driver.start(RDPSessionRequest(
            host: "win.corp.internal", port: 3389, username: "nick", domain: nil, credentialID: desktopCredential,
            sharesClipboard: false, gateway: RDPGateway(host: "gw.example.com"), machineName: "win")) as? RDPSession)

        #expect(session.configuration.gateway == RDPGatewayConfiguration(host: "gw.example.com", port: 443, account: .sameAsDesktop))
    }

    @Test func rdpDriverSignsInToAzureVirtualDesktopWithEntraIDAlone() throws {
        let driver = FreeRDPSessionDriver(
            vault: InMemoryCredentialVault(),
            trustStore: InMemoryTrustStore(),
            credentialPrompt: { _ in
                Issue.record("Entra ID signs in to the gateway and the desktop, so no password is asked for")
                return nil
            },
            certificatePrompt: { _, _, _ in .reject },
            entraSignInPrompt: { _, _ in nil })
        let resource = AVDResource(armPath: "/subscriptions/s/hostpools/p", tenantID: "tenant", desktopSignIn: .entraID)
        let gateway = RDPGateway(host: "rdgateway.wvd.microsoft.com", credentials: .azureVirtualDesktop(resource))

        let session = try #require(driver.start(RDPSessionRequest(
            host: "rdgateway.wvd.microsoft.com", port: 3389, username: nil, domain: nil, credentialID: nil,
            sharesClipboard: false, gateway: gateway, machineName: "Cloud PC")) as? RDPSession)

        #expect(session.configuration.username == nil)
        #expect(session.configuration.gateway == RDPGatewayConfiguration(
            host: "rdgateway.wvd.microsoft.com", port: 443,
            account: .azureVirtualDesktop(RDPAzureVirtualDesktopResource(
                armPath: "/subscriptions/s/hostpools/p", tenantID: "tenant", desktopSignIn: .entraID))))
    }

    @Test func rdpDriverSignsInToTheGovernmentCloudForAGovernmentGateway() throws {
        let driver = FreeRDPSessionDriver(
            vault: InMemoryCredentialVault(),
            trustStore: InMemoryTrustStore(),
            credentialPrompt: { _ in nil },
            certificatePrompt: { _, _, _ in .reject },
            entraSignInPrompt: { _, _ in nil })
        let gateway = RDPGateway(host: "rdgateway.wvd.azure.us", credentials: .azureVirtualDesktop(AVDResource(desktopSignIn: .entraID)))

        let session = try #require(driver.start(RDPSessionRequest(
            host: "rdgateway.wvd.azure.us", port: 3389, username: nil, domain: nil, credentialID: nil,
            sharesClipboard: false, gateway: gateway, machineName: "Cloud PC")) as? RDPSession)

        #expect(session.configuration.gateway?.account == .azureVirtualDesktop(
            RDPAzureVirtualDesktopResource(desktopSignIn: .entraID, cloud: .usGovernment)))
    }

    @Test func rdpDriverStillAsksForTheDesktopPasswordBehindAzureVirtualDesktop() throws {
        var prompts: [RDPCredentialPrompt] = []
        let driver = FreeRDPSessionDriver(
            vault: InMemoryCredentialVault(),
            trustStore: InMemoryTrustStore(),
            credentialPrompt: { prompt in
                prompts.append(prompt)
                return RDPCredentialEntry(username: "nick@example.com", domain: "", password: "pa55")
            },
            certificatePrompt: { _, _, _ in .reject },
            entraSignInPrompt: { _, _ in nil })
        let gateway = RDPGateway(host: "rdgateway.wvd.microsoft.com", credentials: .azureVirtualDesktop(AVDResource()))

        _ = try driver.start(RDPSessionRequest(
            host: "rdgateway.wvd.microsoft.com", port: 3389, username: nil, domain: nil, credentialID: nil,
            sharesClipboard: false, gateway: gateway, machineName: "Cloud PC"))

        // Only the desktop's account: the gateway's comes from the sign-in page.
        #expect(prompts == [RDPCredentialPrompt(machineName: "Cloud PC", username: nil, domain: nil, hasStoredPassword: false)])
    }

    @Test func rdpDriverAsksForThePasswordUpFrontWhenEntraDesktopSignInIsTurnedOff() throws {
        var prompts: [RDPCredentialPrompt] = []
        let driver = FreeRDPSessionDriver(
            vault: InMemoryCredentialVault(),
            trustStore: InMemoryTrustStore(),
            credentialPrompt: { prompt in
                prompts.append(prompt)
                return RDPCredentialEntry(username: "nick@example.com", domain: "", password: "pa55")
            },
            certificatePrompt: { _, _, _ in .reject },
            entraSignInPrompt: { _, _ in nil })
        let gateway = RDPGateway(
            host: "rdgateway.wvd.microsoft.com",
            credentials: .azureVirtualDesktop(AVDResource(desktopSignIn: .passwordInsteadOfEntraID)))

        let session = try #require(driver.start(RDPSessionRequest(
            host: "rdgateway.wvd.microsoft.com", port: 3389, username: nil, domain: nil, credentialID: nil,
            sharesClipboard: false, gateway: gateway, machineName: "Cloud PC")) as? RDPSession)

        #expect(prompts.count == 1)
        #expect(session.configuration.gateway?.account == .azureVirtualDesktop(
            RDPAzureVirtualDesktopResource(desktopSignIn: .passwordInsteadOfEntraID)))
    }
}
