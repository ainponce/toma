// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import Sharing
import Testing

@Suite struct ShareConfigurationTests {
    @Test func preferencesDefaultToR2WithTheTomaPrefix() {
        let preferences = SharePreferences()
        #expect(preferences.provider == .r2 && preferences.region == "auto" && preferences.prefix == "toma/")
        #expect(preferences.endpoint.isEmpty && preferences.bucket.isEmpty && preferences.linkDays == 7)
    }
}
