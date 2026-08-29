// SPDX-FileCopyrightText: 2026 Nick Wolff <nick@wolff.tech>
// SPDX-License-Identifier: GPL-3.0-only

import Foundation
import Testing
@testable import Constellation

struct UpdateControllerTests {
    /// The host app's Info.plist is what ships; a placeholder key or a feed
    /// on another repository would make every release unverifiable.
    @Test func hostAppIsWiredToThisRepositoryFeed() throws {
        let info = try #require(Bundle.main.infoDictionary)
        let feed = try #require(info["SUFeedURL"] as? String)
        #expect(feed == "https://github.com/WolffTech/constellation/releases/latest/download/appcast.xml")
        let key = try #require(info["SUPublicEDKey"] as? String)
        #expect(key.wholeMatch(of: /[A-Za-z0-9+\/]{43}=/) != nil)
    }

    @MainActor
    @Test func testHostNeverStartsAnUpdater() {
        let updates = UpdateController(isTestHost: true)
        #expect(!updates.isAvailable)
        #expect(!updates.canCheckForUpdates)
    }
}
