// SPDX-FileCopyrightText: 2026 Nick Wolff <nick@wolff.tech>
// SPDX-License-Identifier: GPL-3.0-only

import ConstellationCore

extension ConnectionProtocol {
    /// SF Symbol used wherever a profile's protocol is shown.
    var symbolName: String {
        switch self {
        case .ssh: "terminal"
        case .vnc, .appleScreenSharing: "display"
        case .rdp: "rectangle.on.rectangle"
        }
    }
}

extension MachineLibrarySnapshot {
    /// Profiles with the machine's default first, then by name — the order the UI lists them.
    func orderedProfiles(for machine: Machine) -> [ConnectionProfile] {
        profiles(for: machine.id).sorted { lhs, rhs in
            if (lhs.id == machine.defaultProfileID) != (rhs.id == machine.defaultProfileID) {
                return lhs.id == machine.defaultProfileID
            }
            return lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
        }
    }
}
