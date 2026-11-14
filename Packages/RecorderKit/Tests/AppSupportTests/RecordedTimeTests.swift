// SPDX-License-Identifier: GPL-3.0-or-later
import AppSupport
import Foundation
import Testing

@Suite struct RecordedTimeTests {
    @Test func elapsedExcludesPausedTime() {
        let zero = Date(timeIntervalSinceReferenceDate: 0)
        var time = RecordedTime()
        #expect(time.elapsed(at: zero) == .zero)  // nothing recorded yet
        time.began(at: zero)
        #expect(time.elapsed(at: zero + 9.9) == .seconds(9))  // whole seconds
        time.paused(at: zero + 10)
        #expect(time.elapsed(at: zero + 20) == .seconds(10))  // stands still while paused
        time.resumed(at: zero + 25)
        #expect(time.elapsed(at: zero + 40) == .seconds(25))
    }
}
