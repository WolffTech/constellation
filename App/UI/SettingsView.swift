// SPDX-FileCopyrightText: 2026 Nick Wolff <nick@wolff.tech>
// SPDX-License-Identifier: GPL-3.0-only

import ConstellationCore
import SwiftUI

/// The Settings window's tabs. The window takes each tab's content size, so
/// every tab is given the same one and switching does not resize the window.
struct SettingsView: View {
    let root: CompositionRoot

    private static let tabSize = CGSize(width: 640, height: 500)

    var body: some View {
        TabView {
            TerminalSettingsView(settings: root.terminalSettings)
                .frame(width: Self.tabSize.width, height: Self.tabSize.height)
                .tabItem { Label("Terminal", systemImage: "terminal") }
            RDPSettingsView(settings: root.rdpSettings)
                .frame(width: Self.tabSize.width, height: Self.tabSize.height)
                .tabItem { Label("RDP", systemImage: ConnectionProtocol.rdp.symbolName) }
            VNCSettingsView(settings: root.vncSettings)
                .frame(width: Self.tabSize.width, height: Self.tabSize.height)
                .tabItem { Label("VNC", systemImage: ConnectionProtocol.vnc.symbolName) }
            if let trustedCertificates = root.trustedCertificates {
                TrustedCertificatesView(model: trustedCertificates)
                    .frame(width: Self.tabSize.width, height: Self.tabSize.height)
                    .tabItem { Label("Certificates", systemImage: "checkmark.shield") }
            }
            ShortcutSettingsView(shortcuts: root.shortcuts)
                .frame(width: Self.tabSize.width, height: Self.tabSize.height)
                .tabItem { Label("Shortcuts", systemImage: "keyboard") }
            UpdatesSettingsView(updates: root.updates)
                .frame(width: Self.tabSize.width, height: Self.tabSize.height)
                .tabItem { Label("Updates", systemImage: "arrow.down.circle") }
        }
    }
}
