// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation

/// The JSON settings shared by every file of the project format.
///
/// Dates are ISO 8601 without fractional seconds, which is why every `Date`
/// written to disk is rounded to whole seconds when it is created.
public enum ProjectJSON {
    public static func encoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys, .prettyPrinted, .withoutEscapingSlashes]
        return encoder
    }

    public static func decoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}

extension Date {
    /// This date rounded down to a whole second, the precision dates have on disk.
    var roundedToWholeSeconds: Date {
        Date(timeIntervalSince1970: timeIntervalSince1970.rounded(.down))
    }
}
