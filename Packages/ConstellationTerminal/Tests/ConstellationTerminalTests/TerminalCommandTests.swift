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
}
