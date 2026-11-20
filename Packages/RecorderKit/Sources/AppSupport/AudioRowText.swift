// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import ProjectFormat

/// The numbers an audio row of the timeline writes and reads (phase 3 plan 3c, decisions 13 and 14): a gain as its
/// capsule and VoiceOver say it, a gain typed into the capsule, and how far a cut of the sound moved.
public enum AudioRowText {
    /// The side a cut of the sound moved to: a J cut (the next clip heard sooner) or an L cut (the clip before heard longer).
    public enum Cut: Equatable, Sendable {
        case j
        case l
    }

    /// The number of `dB` the capsule writes before " dB", in `locale`: to a tenth, without a trailing zero, "+" before a
    /// gain over 0 and "−" (U+2212) before one under it, nothing before 0 (what rounds to it). `nil` for −∞
    /// (`GainRange.silence` or less), which is written otherwise; a value that is not a number is 0.
    public static func decibels(_ dB: Double, locale: Locale) -> String? {
        guard !dB.isNaN else { return "0" }
        guard dB > GainRange.silence else { return nil }
        let tenths = Int64((dB * 10).rounded())
        guard tenths != 0 else { return "0" }
        let magnitude = tenths.magnitude
        let whole = "\(magnitude / 10)"
        let number = magnitude % 10 == 0 ? whole : whole + (locale.decimalSeparator ?? ".") + "\(magnitude % 10)"
        return (tenths > 0 ? "+" : "\u{2212}") + number
    }

    /// The gain `text` asks for, in dB, as typed (the commands hold it to their range): a number with a point or a comma,
    /// "+", "-" or "−" before it and "dB" after it if it has them, or −∞ (`GainRange.silence`) typed as "−∞" or "-inf".
    /// `nil` for anything else.
    public static func gain(from text: String) -> Double? {
        var typed = text.trimmingCharacters(in: .whitespaces).lowercased()
        if typed.hasSuffix("db") { typed = String(typed.dropLast(2)).trimmingCharacters(in: .whitespaces) }
        typed = typed.replacingOccurrences(of: "\u{2212}", with: "-").replacingOccurrences(of: ",", with: ".")
        if typed == "-∞" || typed == "-inf" { return GainRange.silence }
        // Digits, at most one point, and a sign only in front: what `Double` would also read as "inf", "nan" or "1e3" is
        // not a gain anyone types.
        var body = Substring(typed)
        if body.first == "+" || body.first == "-" { body = body.dropFirst() }
        guard !body.isEmpty, body.allSatisfy({ $0.isASCII && ($0.isNumber || $0 == ".") }), body.filter({ $0 == "." }).count <= 1,
            body != "."
        else { return nil }
        return Double(typed)
    }

    /// How far a cut of the sound moved, `ns` of output either way, in seconds with two decimals in `locale`: "0,30 s".
    public static func shift(_ ns: Int64, locale: Locale) -> String {
        let hundredths = UInt64((Double(ns.magnitude) / 1e7).rounded())
        let fraction = hundredths % 100
        return "\(hundredths / 100)\(locale.decimalSeparator ?? ".")\(fraction < 10 ? "0" : "")\(fraction) s"
    }

    /// The cut a sound moved by `shift` ns of output is: a J cut before the picture's, an L cut after it; `nil` at it.
    public static func cut(_ shift: Int64) -> Cut? {
        shift < 0 ? .j : shift > 0 ? .l : nil
    }
}
