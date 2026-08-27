// SPDX-FileCopyrightText: 2026 Nick Wolff <nick@wolff.tech>
// SPDX-License-Identifier: GPL-3.0-only

import ConstellationRDP
import ConstellationRemoteDesktop
import SwiftUI

struct RDPSettingsView: View {
    let settings: RDPSettingsStore

    var body: some View {
        Form {
            Section {
                Picker("Open new sessions", selection: Binding(
                    get: { settings.value.defaultDisplayMode },
                    set: { value in settings.update { $0.defaultDisplayMode = value } })) {
                    Text("Fit to Window").tag(RemoteDesktopDisplayMode.fit)
                    Text("Actual Size").tag(RemoteDesktopDisplayMode.actualSize)
                }
                Toggle("Resize the remote desktop to fit the window", isOn: Binding(
                    get: { settings.value.dynamicResolution },
                    set: { value in settings.update { $0.dynamicResolution = value } }))
                LabeledContent("Desktop size") {
                    HStack(spacing: 4) {
                        DesktopSideField(label: "Width", value: side(\.desktopWidth))
                        Text("×").foregroundStyle(.secondary)
                        DesktopSideField(label: "Height", value: side(\.desktopHeight))
                        Text("pt").foregroundStyle(.secondary)
                    }
                }
                .disabled(settings.value.dynamicResolution)
            } header: {
                Text("Display")
            } footer: {
                Text(settings.value.dynamicResolution
                    ? "The desktop starts at the window size and follows it when the window changes. Retina displays get a matching 200% desktop scale."
                    : "The desktop keeps this size in points for the whole session; Fit to Window scales it down when the window is smaller.")
            }

            Section {
                Picker("Connection", selection: Binding(
                    get: { settings.value.connectionQuality },
                    set: { value in settings.update { $0.connectionQuality = value } })) {
                    Text("Automatic").tag(RDPConnectionQuality.automatic)
                    Text("LAN").tag(RDPConnectionQuality.lan)
                    Text("Broadband").tag(RDPConnectionQuality.broadband)
                    Text("Modem").tag(RDPConnectionQuality.modem)
                }
            } header: {
                Text("Experience")
            } footer: {
                Text("Tells Windows how much to spend on wallpaper, font smoothing, animations and themes. Automatic keeps FreeRDP’s defaults; Modem turns all of them off.")
            }

            Section {
                HStack {
                    Spacer()
                    Button("Restore Defaults") { settings.reset() }
                }
            } footer: {
                Text("Changes apply to sessions opened from now on.")
            }
        }
        .formStyle(.grouped)
    }

    private func side(_ keyPath: WritableKeyPath<RDPSettings, Int>) -> Binding<Int> {
        Binding(
            get: { settings.value[keyPath: keyPath] },
            set: { value in
                let range = RDPSettings.desktopSideRange
                settings.update { $0[keyPath: keyPath] = min(max(value, range.lowerBound), range.upperBound) }
            })
    }
}

private struct DesktopSideField: View {
    let label: String
    @Binding var value: Int

    var body: some View {
        TextField(label, value: $value, format: .number.grouping(.never))
            .labelsHidden()
            .frame(width: 60)
            .accessibilityLabel(label)
    }
}
