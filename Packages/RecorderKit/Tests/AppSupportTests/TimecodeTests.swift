// SPDX-License-Identifier: GPL-3.0-or-later
import AppSupport
import Foundation
import Testing

@Suite struct TimecodeTests {
    private let spanish = Locale(identifier: "es")
    private let english = Locale(identifier: "en")

    @Test func timecodeFormats() {
        #expect(Timecode.duration(134) == "2:14")
        #expect(Timecode.duration(3734) == "1:02:14")
        #expect(Timecode.precise(42.18, total: 134, locale: spanish) == "0:42,18")
        #expect(Timecode.precise(42.18, total: 134, locale: english) == "0:42.18")
        #expect(Timecode.precise(3725.5, total: 4000, locale: spanish) == "1:02:05,50")
    }

    @Test func durationIsInWholeSecondsRoundedDown() {
        #expect(Timecode.duration(0) == "0:00")
        #expect(Timecode.duration(59.999) == "0:59")
        #expect(Timecode.duration(60) == "1:00")
        #expect(Timecode.duration(3599.9) == "59:59")
        #expect(Timecode.duration(3600) == "1:00:00")
        #expect(Timecode.duration(36_000) == "10:00:00")
        #expect(Timecode.duration(-3) == "0:00")
        #expect(Timecode.duration(.nan) == "0:00")
        #expect(Timecode.duration(.infinity) == "0:00")
    }

    @Test func preciseHasHundredthsAndHoursOnlyFromAnHourOfTotal() {
        // Hundredths rounded down: a frame never shows the next hundredth.
        #expect(Timecode.precise(0, total: 134, locale: spanish) == "0:00,00")
        #expect(Timecode.precise(1.0 / 60, total: 134, locale: spanish) == "0:00,01")
        #expect(Timecode.precise(134, total: 134, locale: spanish) == "2:14,00")
        #expect(Timecode.precise(0.29, total: 134, locale: english) == "0:00.29")
        #expect(Timecode.precise(599.999, total: 600, locale: english) == "9:59.99")
        // From an hour of total, every time has its hour.
        #expect(Timecode.precise(42.18, total: 3600, locale: spanish) == "0:00:42,18")
        #expect(Timecode.precise(4000, total: 4000, locale: english) == "1:06:40.00")
        // Never negative or undefined.
        #expect(Timecode.precise(-1, total: 134, locale: spanish) == "0:00,00")
        #expect(Timecode.precise(.nan, total: 134, locale: spanish) == "0:00,00")
    }
}
