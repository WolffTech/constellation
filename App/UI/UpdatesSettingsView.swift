// SPDX-FileCopyrightText: 2026 Nick Wolff <nick@wolff.tech>
// SPDX-License-Identifier: GPL-3.0-only

import SwiftUI

/// Placeholder until an updater (Sparkle is the plan) ships. Shows the
/// installed version and where new builds are published.
struct UpdatesSettingsView: View {
    static let releasesURL = URL(string: "https://github.com/WolffTech/constellation/releases")!

    var body: some View {
        Form {
            Section {
                LabeledContent("Version", value: Self.versionDescription)
            } footer: {
                Text("Constellation does not check for updates yet. Automatic updates are planned for a later release; until then, new versions are published on GitHub.")
            }
            Section {
                HStack {
                    Spacer()
                    Link("View Releases on GitHub", destination: Self.releasesURL)
                }
            }
        }
        .formStyle(.grouped)
    }

    static var versionDescription: String {
        let info = Bundle.main.infoDictionary ?? [:]
        let version = info["CFBundleShortVersionString"] as? String ?? "–"
        let build = info["CFBundleVersion"] as? String ?? "–"
        return "\(version) (\(build))"
    }
}
