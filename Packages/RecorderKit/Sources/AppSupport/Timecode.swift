// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation

/// The editor's times (design §5.2 and §5.3).
public enum Timecode {
    /// An output duration in whole seconds, rounded down: `2:14`, or `1:02:14` from an hour on. A negative or undefined
    /// one is `0:00`.
    public static func duration(_ seconds: Double) -> String {
        let whole = Int(clamped(seconds).rounded(.down))
        return clock(whole, hours: whole >= 3600)
    }

    /// A time of the transport with hundredths, rounded down so a frame never shows the next one: `0:42,18` in Spanish and
    /// `0:42.18` in English (`locale`'s decimal separator), and `h:mm:ss,cc` when `total`, what the output lasts, is an hour
    /// or more, so the time and the total read alike. A negative or undefined time is 0.
    public static func precise(_ seconds: Double, total: Double, locale: Locale) -> String {
        // A hair over, so a time that is a whole hundredth in decimal (42.18) is not read as the one before it.
        let hundredths = Int((clamped(seconds) * 100 + 1e-6).rounded(.down))
        let separator = locale.decimalSeparator ?? "."
        let fraction = hundredths % 100
        return clock(hundredths / 100, hours: clamped(total) >= 3600) + separator + (fraction < 10 ? "0" : "") + String(fraction)
    }

    /// `m:ss`, or `h:mm:ss` with `hours`.
    private static func clock(_ seconds: Int, hours: Bool) -> String {
        let (h, m, s) = (seconds / 3600, seconds / 60 % 60, seconds % 60)
        let ss = (s < 10 ? "0" : "") + String(s)
        guard hours else { return "\(seconds / 60):\(ss)" }
        return "\(h):\(m < 10 ? "0" : "")\(m):\(ss)"
    }

    /// `seconds`, or 0 if it is negative or not finite; at most ten thousand hours, so it always fits an `Int`.
    private static func clamped(_ seconds: Double) -> Double {
        seconds.isFinite ? min(max(seconds, 0), 36_000_000) : 0
    }
}
