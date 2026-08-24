import AppKit
import Foundation

/// Choices the terminal settings pane offers instead of free text.
enum TerminalCatalogs {
    /// Installed font families that have a fixed-pitch face.
    static func monospacedFontFamilies() -> [String] {
        NSFontManager.shared.availableFontFamilies.filter { family in
            let descriptor = NSFontDescriptor(fontAttributes: [.family: family])
            return NSFont(descriptor: descriptor, size: 12)?.isFixedPitch == true
        }
        .sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
    }

    /// Theme names from the Ghostty resources bundled in `Contents/Resources/ghostty/themes`.
    /// Empty when the bundle has no resources, in which case `theme =` cannot resolve anyway.
    static func themes(in bundle: Bundle = .main) -> [String] {
        guard let directory = bundle.resourceURL?.appendingPathComponent("ghostty/themes"),
              let names = try? FileManager.default.contentsOfDirectory(atPath: directory.path) else { return [] }
        return names
            .filter { !$0.hasPrefix(".") }
            .sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
    }
}
