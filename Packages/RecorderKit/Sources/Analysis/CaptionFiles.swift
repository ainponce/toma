// SPDX-License-Identifier: GPL-3.0-or-later

/// The captions as `.srt` and `.vtt` text (plan decision 12): the same lines and times as the picture, rounded to the
/// millisecond, every end at least 1 ms after its start.
public enum CaptionFiles {
    public static func srt(_ captions: [Caption]) -> String {
        let blocks = captions.enumerated().map { index, caption in
            let (start, end) = milliseconds(caption)
            return "\(index + 1)\n\(timestamp(start, separator: ",")) --> \(timestamp(end, separator: ","))\n\(caption.text)\n"
        }
        return blocks.joined(separator: "\n")
    }

    public static func vtt(_ captions: [Caption]) -> String {
        let blocks = captions.map { caption in
            let (start, end) = milliseconds(caption)
            return "\(timestamp(start, separator: ".")) --> \(timestamp(end, separator: "."))\n\(escaped(caption.text))\n"
        }
        return (["WEBVTT\n"] + blocks).joined(separator: "\n")
    }

    private static func milliseconds(_ caption: Caption) -> (Int64, Int64) {
        let start = rounded(caption.output.lowerBound)
        return (start, max(rounded(caption.output.upperBound), start + 1))
    }

    private static func rounded(_ nanoseconds: Int64) -> Int64 {
        let (shifted, overflow) = nanoseconds.addingReportingOverflow(500_000)
        return (overflow ? Int64.max : max(shifted, 0)) / 1_000_000
    }

    private static func timestamp(_ milliseconds: Int64, separator: String) -> String {
        let (hours, minutes) = (milliseconds / 3_600_000, milliseconds / 60_000 % 60)
        let (seconds, millis) = (milliseconds / 1000 % 60, milliseconds % 1000)
        return "\(pad(hours, 2)):\(pad(minutes, 2)):\(pad(seconds, 2))\(separator)\(pad(millis, 3))"
    }

    private static func pad(_ value: Int64, _ width: Int) -> String {
        let digits = String(value)
        return String(repeating: "0", count: max(width - digits.count, 0)) + digits
    }

    private static func escaped(_ text: String) -> String {
        text.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
    }
}
