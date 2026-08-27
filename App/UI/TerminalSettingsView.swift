// SPDX-FileCopyrightText: 2026 Nick Wolff <nick@wolff.tech>
// SPDX-License-Identifier: GPL-3.0-only

import SwiftUI

struct TerminalSettingsView: View {
    let settings: TerminalSettingsStore
    @State private var fonts: [String] = []
    @State private var themes: [String] = []

    var body: some View {
        Form {
            Section {
                Toggle("Use my Ghostty configuration", isOn: Binding(
                    get: { settings.appearance.usesGhosttyConfig },
                    set: { value in settings.update { $0.usesGhosttyConfig = value } }))
                if !settings.diagnostics.isEmpty {
                    ForEach(settings.diagnostics, id: \.self) { message in
                        Label(message, systemImage: "exclamationmark.triangle")
                            .foregroundStyle(.orange)
                            .font(.callout)
                    }
                }
            } footer: {
                Text("Reads the config files Ghostty itself uses for font, colors, padding, scrollback and Option handling. Constellation keeps its own shortcuts and terminal type.")
            }

            Group {
                Section("Font") {
                    Picker("Family", selection: fontFamily) {
                        Text("Ghostty default").tag(String?.none)
                        Divider()
                        ForEach(fontChoices, id: \.self) { Text($0).tag(String?.some($0)) }
                    }
                    LabeledContent("Size") {
                        HStack(spacing: 4) {
                            TextField("Size", value: fontSize, format: .number)
                                .labelsHidden()
                                .frame(width: 50)
                            Stepper("Size", value: fontSize, in: 8...32, step: 0.5)
                                .labelsHidden()
                            Text("pt").foregroundStyle(.secondary)
                        }
                    }
                }

                Section("Colors") {
                    if themes.isEmpty {
                        TextField("Theme", text: themeText, prompt: Text("Ghostty theme name"))
                        TextField("Dark mode theme", text: darkThemeText, prompt: Text("Same as light"))
                    } else {
                        Picker("Theme", selection: theme) {
                            Text("Ghostty default").tag(String?.none)
                            Divider()
                            ForEach(themeChoices, id: \.self) { Text($0).tag(String?.some($0)) }
                        }
                        Picker("Dark mode theme", selection: darkTheme) {
                            Text("Same as light").tag(String?.none)
                            Divider()
                            ForEach(darkThemeChoices, id: \.self) { Text($0).tag(String?.some($0)) }
                        }
                    }
                }

                Section("Behavior") {
                    Picker("Scrollback", selection: Binding(
                        get: { settings.appearance.scrollbackLimitBytes },
                        set: { value in settings.update { $0.scrollbackLimitBytes = value } })) {
                        Text("1 MB").tag(1_000_000)
                        Text("10 MB").tag(10_000_000)
                        Text("50 MB").tag(50_000_000)
                        Text("100 MB").tag(100_000_000)
                    }
                    Toggle("Use Option as Alt", isOn: Binding(
                        get: { settings.appearance.optionAsAlt },
                        set: { value in settings.update { $0.optionAsAlt = value } }))
                }
            }
            // Ignored while the user's Ghostty config decides them.
            .disabled(settings.appearance.usesGhosttyConfig)

            Section {
                HStack {
                    Spacer()
                    Button("Restore Defaults") { settings.reset() }
                }
            }
        }
        .formStyle(.grouped)
        .task {
            fonts = TerminalCatalogs.monospacedFontFamilies()
            themes = TerminalCatalogs.themes()
        }
        .alert("Terminal settings could not be applied", isPresented: Binding(
            get: { settings.presentedError != nil },
            set: { if !$0 { settings.presentedError = nil } })) {
                Button("OK") {}
            } message: {
                Text(settings.presentedError ?? "")
            }
    }

    /// The saved value stays selectable even if the font or theme is no longer installed.
    private var fontChoices: [String] {
        including(settings.appearance.fontFamily, in: fonts)
    }

    private var themeChoices: [String] {
        including(settings.appearance.theme, in: themes)
    }

    private var darkThemeChoices: [String] {
        including(settings.appearance.darkTheme, in: themes)
    }

    private func including(_ current: String?, in choices: [String]) -> [String] {
        guard let current, !current.isEmpty, !choices.contains(current) else { return choices }
        return [current] + choices
    }

    private var fontFamily: Binding<String?> {
        Binding(
            get: { settings.appearance.fontFamily },
            set: { value in settings.update { $0.fontFamily = value } })
    }

    private var fontSize: Binding<Double> {
        Binding(
            get: { settings.appearance.fontSize },
            set: { value in settings.update { $0.fontSize = min(max(value, 8), 32) } })
    }

    private var theme: Binding<String?> {
        Binding(
            get: { settings.appearance.theme },
            set: { value in settings.update { $0.theme = value } })
    }

    private var themeText: Binding<String> {
        Binding(
            get: { settings.appearance.theme ?? "" },
            set: { value in settings.update { $0.theme = value.isEmpty ? nil : value } })
    }

    private var darkTheme: Binding<String?> {
        Binding(
            get: { settings.appearance.darkTheme },
            set: { value in settings.update { $0.darkTheme = value } })
    }

    private var darkThemeText: Binding<String> {
        Binding(
            get: { settings.appearance.darkTheme ?? "" },
            set: { value in settings.update { $0.darkTheme = value.isEmpty ? nil : value } })
    }
}
