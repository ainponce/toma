// SPDX-License-Identifier: GPL-3.0-or-later
import CoreMedia
import Foundation
import Testing
@testable import ProjectFormat

@Test func nowMatchesHostClock() {
    let a = HostTime.now()
    let b = HostTime(CMClockGetTime(CMClockGetHostTimeClock()))
    #expect(abs(Int64(b.nanoseconds) - Int64(a.nanoseconds)) < 1_000_000)
}

@Test func eventTimestampSharesTheHostClock() {
    let a = HostTime(eventTimestamp: ProcessInfo.processInfo.systemUptime)
    #expect(abs(Int64(HostTime.now().nanoseconds) - Int64(a.nanoseconds)) < 1_000_000)
}

@Test func encodesAsSingleInteger() throws {
    #expect(String(decoding: try JSONEncoder().encode(HostTime(nanoseconds: 42)), as: UTF8.self) == "42")
}

@Test func secondsAndAddingRoundTrip() {
    let t = HostTime(nanoseconds: 1_000_000_000)
    #expect(t.adding(seconds: 1.5).seconds(since: t) == 1.5)
}
