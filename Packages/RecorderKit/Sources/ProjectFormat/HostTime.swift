// SPDX-License-Identifier: GPL-3.0-or-later
import CoreMedia
import Darwin
import Foundation

/// A point in time on the host clock: nanoseconds of `CLOCK_UPTIME_RAW`.
/// This is the same clock as `CMClockGetHostTimeClock()` and `NSEvent.timestamp`,
/// so every recorded stream can be aligned against it.
public struct HostTime: Codable, Hashable, Comparable, Sendable {
    public var nanoseconds: UInt64

    public init(nanoseconds: UInt64) {
        self.nanoseconds = nanoseconds
    }

    public static func now() -> HostTime {
        HostTime(nanoseconds: clock_gettime_nsec_np(CLOCK_UPTIME_RAW))
    }

    /// Converts a `CMTime` expressed on the host clock.
    public init(_ time: CMTime) {
        let converted = CMTimeConvertScale(time, timescale: 1_000_000_000, method: .default)
        self.init(nanoseconds: UInt64(max(0, converted.value)))
    }

    /// Converts `NSEvent.timestamp` (seconds since boot, host clock).
    public init(eventTimestamp: TimeInterval) {
        self.init(nanoseconds: UInt64((max(0, eventTimestamp) * 1_000_000_000).rounded()))
    }

    public var cmTime: CMTime {
        CMTime(value: CMTimeValue(nanoseconds), timescale: 1_000_000_000)
    }

    public func seconds(since other: HostTime) -> Double {
        (Double(nanoseconds) - Double(other.nanoseconds)) / 1_000_000_000
    }

    public func adding(seconds: Double) -> HostTime {
        let delta = (seconds * 1_000_000_000).rounded()
        if delta >= 0 {
            return HostTime(nanoseconds: nanoseconds &+ UInt64(delta))
        }
        return HostTime(nanoseconds: nanoseconds &- min(UInt64(-delta), nanoseconds))
    }

    public static func < (lhs: HostTime, rhs: HostTime) -> Bool {
        lhs.nanoseconds < rhs.nanoseconds
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        self.init(nanoseconds: try container.decode(UInt64.self))
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(nanoseconds)
    }
}
