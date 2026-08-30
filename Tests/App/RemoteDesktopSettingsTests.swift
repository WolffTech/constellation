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
}
