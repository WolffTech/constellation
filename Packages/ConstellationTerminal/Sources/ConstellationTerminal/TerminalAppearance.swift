// SPDX-FileCopyrightText: 2026 Nick Wolff <nick@wolff.tech>
// SPDX-License-Identifier: GPL-3.0-only

import Foundation

/// App-owned terminal appearance. Constellation turns this into a libghostty
/// configuration. The user's own Ghostty config files are read only when
/// `usesGhosttyConfig` is on, and Constellation's behavioral settings
/// (keybinds, `term`, close handling) still win over them.
public struct TerminalAppearance: Sendable, Equatable, Codable {
    /// `nil` uses libghostty's bundled default font.
    public var fontFamily: String?
    public var fontSize: Double
    /// A Ghostty built-in theme name. `nil` uses libghostty's default colors.
    public var theme: String?
    public var scrollbackLimitBytes: Int
    /// Treat Option as Alt (Meta) so `Option-B`-style shell bindings work.
    public var optionAsAlt: Bool
    /// Load the files Ghostty.app itself reads (`~/.config/ghostty/config`,
    /// `~/Library/Application Support/com.mitchellh.ghostty/config`) and let
    /// them decide font, colors, padding, scrollback and Option handling.
    /// The fields above are ignored while this is on.
    public var usesGhosttyConfig: Bool

    public init(
        fontFamily: String? = nil,
        fontSize: Double = 13,
        theme: String? = nil,
        scrollbackLimitBytes: Int = 10_000_000,
        optionAsAlt: Bool = true,
        usesGhosttyConfig: Bool = false
    ) {
        self.fontFamily = fontFamily
        self.fontSize = fontSize
        self.theme = theme
        self.scrollbackLimitBytes = scrollbackLimitBytes
        self.optionAsAlt = optionAsAlt
        self.usesGhosttyConfig = usesGhosttyConfig
    }

    public static let `default` = TerminalAppearance()

    // Settings saved before `usesGhosttyConfig` existed lack the key.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        fontFamily = try container.decodeIfPresent(String.self, forKey: .fontFamily)
        fontSize = try container.decode(Double.self, forKey: .fontSize)
        theme = try container.decodeIfPresent(String.self, forKey: .theme)
        scrollbackLimitBytes = try container.decode(Int.self, forKey: .scrollbackLimitBytes)
        optionAsAlt = try container.decode(Bool.self, forKey: .optionAsAlt)
        usesGhosttyConfig = try container.decodeIfPresent(Bool.self, forKey: .usesGhosttyConfig) ?? false
    }
}
