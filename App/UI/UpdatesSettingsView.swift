// SPDX-FileCopyrightText: 2026 Nick Wolff <nick@wolff.tech>
// SPDX-License-Identifier: GPL-3.0-only

import SwiftUI

struct UpdatesSettingsView: View {
    static let releasesURL = URL(string: "https://github.com/WolffTech/constellation/releases")!

    @Bindable var updates: UpdateController

    var body: some View {
        Form {
            Section {
                LabeledContent("Version", value: "\(updates.version) (\(updates.build))")
                Toggle("Check for updates automatically", isOn: $updates.automaticallyChecksForUpdates)
                Toggle("Download updates automatically", isOn: $updates.automaticallyDownloadsUpdates)
                    .disabled(!updates.automaticallyChecksForUpdates)
            } footer: {
                Text("Updates are downloaded from GitHub Releases and verified before they are installed.")
            }
            Section {
                HStack {
                    Link("View Releases on GitHub", destination: Self.releasesURL)
                    Spacer()
                    Button("Check for Updates…") { updates.checkForUpdates() }
                        .disabled(!updates.canCheckForUpdates)
                }
            }
        }
        .formStyle(.grouped)
        .disabled(!updates.isAvailable)
        .onAppear { updates.refresh() }
    }
}
