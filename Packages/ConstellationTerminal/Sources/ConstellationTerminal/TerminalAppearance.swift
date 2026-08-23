import Foundation

/// App-owned terminal appearance. Constellation turns this into a libghostty
/// configuration; the user's own Ghostty config file is never read.
public struct TerminalAppearance: Sendable, Equatable, Codable {
    /// `nil` uses libghostty's bundled default font.
    public var fontFamily: String?
    public var fontSize: Double
    /// A Ghostty built-in theme name. `nil` uses libghostty's default colors.
    public var theme: String?
    public var scrollbackLimitBytes: Int
    /// Treat Option as Alt (Meta) so `Option-B`-style shell bindings work.
    public var optionAsAlt: Bool

    public init(
        fontFamily: String? = nil,
        fontSize: Double = 13,
        theme: String? = nil,
        scrollbackLimitBytes: Int = 10_000_000,
        optionAsAlt: Bool = true
    ) {
        self.fontFamily = fontFamily
        self.fontSize = fontSize
        self.theme = theme
        self.scrollbackLimitBytes = scrollbackLimitBytes
        self.optionAsAlt = optionAsAlt
    }

    public static let `default` = TerminalAppearance()
}
