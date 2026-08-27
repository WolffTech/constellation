// SPDX-FileCopyrightText: 2026 Nick Wolff <nick@wolff.tech>
// SPDX-License-Identifier: GPL-3.0-only

import Foundation
import Testing
@testable import ConstellationTerminal

struct TerminalCommandTests {
    @Test func quotesEveryWordForSh() {
        let command = TerminalCommand(
            executable: "/usr/bin/ssh",
            arguments: ["-o", "HostKeyAlias=Nick's box", "-p", "22", "user@host"])
        #expect(command.shellCommandLine == "'/usr/bin/ssh' '-o' 'HostKeyAlias=Nick'\\''s box' '-p' '22' 'user@host'")
    }

    @Test func quotesShellMetacharactersLiterally() {
        let command = TerminalCommand(executable: "/bin/echo", arguments: ["$HOME", "a;b", "`id`", "", "two words"])
        #expect(command.shellCommandLine == "'/bin/echo' '$HOME' 'a;b' '`id`' '' 'two words'")
    }

    @Test func localShellUsesLoginShell() {
        let command = TerminalCommand.localShell()
        #expect(command.arguments == ["-l"])
        #expect(command.workingDirectory != nil)
    }
}

struct GhosttyConfigTextTests {
    @Test func defaultsClearGhosttyBindingsAndUseXterm() {
        let text = GhosttyConfigText.render(.default)
        let lines = text.split(separator: "\n").map(String.init)
        #expect(lines.contains("keybind = clear"))
        #expect(lines.contains("term = xterm-256color"))
        #expect(lines.contains("font-size = 13"))
        #expect(lines.contains("confirm-close-surface = false"))
        #expect(!lines.contains { $0.hasPrefix("font-family") })
        #expect(!lines.contains { $0.hasPrefix("theme") })
    }

    @Test func rendersOptionalFontAndTheme() {
        var appearance = TerminalAppearance.default
        appearance.fontFamily = "JetBrains Mono"
        appearance.fontSize = 14.5
        appearance.theme = "Catppuccin Mocha"
        let text = GhosttyConfigText.render(appearance)
        #expect(text.contains("font-family = JetBrains Mono\n"))
        #expect(text.contains("font-size = 14.5\n"))
        #expect(text.contains("theme = Catppuccin Mocha\n"))
    }

    @Test func rendersLightDarkPairOnlyWhenThemesDiffer() {
        var appearance = TerminalAppearance.default
        appearance.theme = "Rose Pine Dawn"
        appearance.darkTheme = "Rose Pine"
        #expect(GhosttyConfigText.render(appearance).contains("theme = light:Rose Pine Dawn,dark:Rose Pine\n"))

        appearance.darkTheme = "Rose Pine Dawn"
        #expect(GhosttyConfigText.render(appearance).contains("theme = Rose Pine Dawn\n"))

        appearance.theme = nil
        appearance.darkTheme = "Rose Pine"
        #expect(GhosttyConfigText.render(appearance).contains("theme = Rose Pine\n"))
    }

    @Test func ghosttyConfigModeLeavesAppearanceKeysToTheUserButKeepsOwnedBehavior() {
        var appearance = TerminalAppearance.default
        appearance.fontFamily = "JetBrains Mono"
        appearance.theme = "Catppuccin Mocha"
        appearance.usesGhosttyConfig = true
        let lines = GhosttyConfigText.render(appearance).split(separator: "\n").map(String.init)
        for key in ["font-family", "font-size", "theme", "scrollback-limit", "macos-option-as-alt", "window-padding"] {
            #expect(!lines.contains { $0.hasPrefix(key) }, "\(key) should come from the user's config")
        }
        #expect(lines.contains("keybind = clear"))
        #expect(lines.contains("term = xterm-256color"))
        #expect(lines.contains("shell-integration = none"))
        #expect(lines.contains("confirm-close-surface = false"))
    }

    @Test func decodesSettingsSavedBeforeGhosttyConfigMode() throws {
        let json = Data(#"{"fontSize":14,"scrollbackLimitBytes":1000000,"optionAsAlt":false}"#.utf8)
        let appearance = try JSONDecoder().decode(TerminalAppearance.self, from: json)
        #expect(appearance == TerminalAppearance(fontSize: 14, scrollbackLimitBytes: 1_000_000, optionAsAlt: false))
        #expect(!appearance.usesGhosttyConfig)
    }
}
