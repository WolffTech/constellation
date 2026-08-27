// SPDX-FileCopyrightText: 2026 Nick Wolff <nick@wolff.tech>
// SPDX-License-Identifier: GPL-3.0-only

import ConstellationRemoteDesktop
import ConstellationVNC
import SwiftUI

struct VNCSettingsView: View {
    let settings: VNCSettingsStore

    var body: some View {
        Form {
            Section {
                Picker("Open new sessions", selection: Binding(
                    get: { settings.value.defaultDisplayMode },
                    set: { value in settings.update { $0.defaultDisplayMode = value } })) {
                    Text("Fit to Window").tag(RemoteDesktopDisplayMode.fit)
                    Text("Actual Size").tag(RemoteDesktopDisplayMode.actualSize)
                }
                Picker("Color depth", selection: Binding(
                    get: { settings.value.colorDepth },
                    set: { value in settings.update { $0.colorDepth = value } })) {
                    Text("24-bit (best quality)").tag(VNCColorDepth.bits24)
                    Text("16-bit").tag(VNCColorDepth.bits16)
                    Text("8-bit (least bandwidth)").tag(VNCColorDepth.bits8)
                }
            } header: {
                Text("Display")
            } footer: {
                Text("Lower color depths use less bandwidth on slow links. The session's display mode can still be changed from its toolbar.")
            }

            Section {
                Picker("macOS shortcuts", selection: Binding(
                    get: { settings.value.keyboardMode },
                    set: { value in settings.update { $0.keyboardMode = value } })) {
                    Text("Send unused shortcuts to the remote desktop").tag(VNCKeyboardMode.forwardUnusedShortcuts)
                    Text("Send every shortcut to the remote desktop").tag(VNCKeyboardMode.forwardAllShortcuts)
                    Text("Keep every shortcut on this Mac").tag(VNCKeyboardMode.local)
                }
            } header: {
                Text("Keyboard")
            } footer: {
                Text("Applies while the remote desktop has focus. Sending every shortcut means Constellation’s own shortcuts, such as closing the session, reach the remote desktop instead.")
            }

            Section {
                Toggle("Let other viewers stay connected", isOn: Binding(
                    get: { settings.value.sharesSession },
                    set: { value in settings.update { $0.sharesSession = value } }))
            } header: {
                Text("Sharing")
            } footer: {
                Text("Off, the server is asked to disconnect anyone else viewing the desktop when a session starts.")
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
}
