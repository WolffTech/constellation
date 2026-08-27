// SPDX-FileCopyrightText: 2026 Nick Wolff <nick@wolff.tech>
// SPDX-License-Identifier: GPL-3.0-only

import SwiftUI

/// The Settings window's tabs. The window takes each tab's content size, so
/// every tab is given the same one and switching does not resize the window.
struct SettingsView: View {
    let root: CompositionRoot

    private static let tabSize = CGSize(width: 640, height: 440)

    var body: some View {
        TabView {
            TerminalSettingsView(settings: root.terminalSettings)
                .frame(width: Self.tabSize.width, height: Self.tabSize.height)
                .tabItem { Label("Terminal", systemImage: "terminal") }
            if let trustedCertificates = root.trustedCertificates {
                TrustedCertificatesView(model: trustedCertificates)
                    .frame(width: Self.tabSize.width, height: Self.tabSize.height)
                    .tabItem { Label("Certificates", systemImage: "checkmark.shield") }
            }
        }
    }
}
