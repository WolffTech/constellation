// SPDX-FileCopyrightText: 2026 Nick Wolff <nick@wolff.tech>
// SPDX-License-Identifier: GPL-3.0-only

import ConstellationRDP
import ConstellationRemoteDesktop
import ConstellationVNC
import Foundation
import Observation

/// A settings value that lives in `UserDefaults` as JSON.
protocol PersistedSettings: Codable, Equatable, Sendable {
    static var defaultsKey: String { get }
    static var `default`: Self { get }
}

/// Owns one `PersistedSettings` value: loads it at launch, saves every change.
/// Settings missing from the saved value, such as ones added since it was
/// saved, take their defaults. Values that still fail to decode (a
/// hand-edited plist) fall back to the defaults rather than failing startup.
@MainActor
@Observable
final class SettingsStore<Value: PersistedSettings> {
    var value: Value {
        didSet { save() }
    }

    @ObservationIgnored
    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        value = defaults.data(forKey: Value.defaultsKey).flatMap(Self.decode) ?? .default
    }

    /// Lays the saved keys over the encoded defaults before decoding, so a
    /// missing key doesn't discard every other saved setting.
    private static func decode(_ data: Data) -> Value? {
        guard let saved = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let defaultData = try? JSONEncoder().encode(Value.default),
              let fallback = try? JSONSerialization.jsonObject(with: defaultData) as? [String: Any],
              let merged = try? JSONSerialization.data(withJSONObject: fallback.merging(saved) { $1 })
        else { return nil }
        return try? JSONDecoder().decode(Value.self, from: merged)
    }

    func update(_ change: (inout Value) -> Void) {
        var updated = value
        change(&updated)
        value = updated
    }

    func reset() {
        value = .default
    }

    private func save() {
        guard let data = try? JSONEncoder().encode(value) else { return }
        defaults.set(data, forKey: Value.defaultsKey)
    }
}

/// Defaults applied to every VNC session when it connects. Per-profile
/// choices (clipboard, account) stay on the profile.
struct VNCSettings: PersistedSettings {
    static let defaultsKey = "vncSettings"
    static let `default` = VNCSettings()

    var colorDepth: VNCColorDepth = .bits24
    var sharesSession = true
    var keyboardMode: VNCKeyboardMode = .forwardUnusedShortcuts
    var defaultDisplayMode: RemoteDesktopDisplayMode = .fit
}

/// Defaults applied to every RDP session when it connects.
struct RDPSettings: PersistedSettings {
    static let defaultsKey = "rdpSettings"
    static let `default` = RDPSettings()

    /// Sizes outside this range are rejected by servers or absurd on screen.
    static let desktopSideRange = 640...7680

    var defaultDisplayMode: RemoteDesktopDisplayMode = .fit
    /// Ask the server to follow the window size. Off, the desktop keeps
    /// `desktopWidth` × `desktopHeight` in points.
    var dynamicResolution = true
    var desktopWidth = 1280
    var desktopHeight = 800
    var connectionQuality: RDPConnectionQuality = .automatic
}

struct GeneralSettings: PersistedSettings {
    static let defaultsKey = "generalSettings"
    static let `default` = GeneralSettings()

    var showsLocalMachine = true
    /// Multiplies how far RDP and VNC sessions scroll; see
    /// `ScrollWheelAccumulator.speedRange`.
    var scrollSpeed = 1.0
}

typealias GeneralSettingsStore = SettingsStore<GeneralSettings>
typealias VNCSettingsStore = SettingsStore<VNCSettings>
typealias RDPSettingsStore = SettingsStore<RDPSettings>
