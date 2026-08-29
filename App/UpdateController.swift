// SPDX-FileCopyrightText: 2026 Nick Wolff <nick@wolff.tech>
// SPDX-License-Identifier: GPL-3.0-only

import AppKit
import Observation
import Sparkle

/// Sparkle updates from the appcast named by `SUFeedURL` in Info.plist.
/// Archives must verify against `SUPublicEDKey`; the release workflow signs
/// them with the matching private key. One feed, one channel: every tag is
/// a release, and 0.x is the beta period.
@MainActor
@Observable
final class UpdateController {
    let version: String
    let build: String
    /// False while a check or an install is already running.
    private(set) var canCheckForUpdates = false
    /// Mirrors of Sparkle's own defaults; `refresh()` re-reads them because
    /// Sparkle's first-launch permission prompt changes them behind the view.
    var automaticallyChecksForUpdates = false {
        didSet { if oldValue != automaticallyChecksForUpdates { updater?.automaticallyChecksForUpdates = automaticallyChecksForUpdates } }
    }
    var automaticallyDownloadsUpdates = false {
        didSet { if oldValue != automaticallyDownloadsUpdates { updater?.automaticallyDownloadsUpdates = automaticallyDownloadsUpdates } }
    }

    @ObservationIgnored private var controller: SPUStandardUpdaterController?
    @ObservationIgnored private var canCheckObservation: NSKeyValueObservation?

    private var updater: SPUUpdater? { controller?.updater }

    /// Whether an updater runs. Test hosts never start one: Sparkle would
    /// schedule checks and raise its permission prompt during the suite.
    var isAvailable: Bool { controller != nil }

    init(
        bundle: Bundle = .main,
        isTestHost: Bool = ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil
    ) {
        let info = bundle.infoDictionary ?? [:]
        version = info["CFBundleShortVersionString"] as? String ?? "0"
        build = info["CFBundleVersion"] as? String ?? "0"
        guard !isTestHost else { return }
        let controller = SPUStandardUpdaterController(startingUpdater: true, updaterDelegate: nil, userDriverDelegate: nil)
        self.controller = controller
        // SPUUpdater is main-thread only, so its KVO notifications arrive there.
        canCheckObservation = controller.updater.observe(\.canCheckForUpdates, options: [.initial, .new]) { [weak self] updater, _ in
            MainActor.assumeIsolated { self?.canCheckForUpdates = updater.canCheckForUpdates }
        }
        refresh()
    }

    func checkForUpdates() {
        controller?.checkForUpdates(nil)
    }

    func refresh() {
        automaticallyChecksForUpdates = updater?.automaticallyChecksForUpdates ?? false
        automaticallyDownloadsUpdates = updater?.automaticallyDownloadsUpdates ?? false
    }
}
