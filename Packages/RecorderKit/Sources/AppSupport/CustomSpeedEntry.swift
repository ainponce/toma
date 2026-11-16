// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation

/// The field of "Custom Speed…" (design §5.5): prefilled with the speed in the user's language, rounded for display
/// only («1,33» for 1.333), and read back as typed («1,5», "1.5", "2×"). A field left as it was prefilled changes
/// nothing, so the speed stays exactly as it was: the rounding is never an edit.
public struct CustomSpeedEntry: Sendable, Equatable {
    /// What the field was prefilled with.
    public let shown: String

    public init(shown: String) {
        self.shown = shown
    }

    /// The speed `text` asks for: `nil` when it is the prefilled text (but for spaces around it), or not a number.
    public func speed(from text: String) -> Double? {
        let typed = text.trimmingCharacters(in: .whitespaces)
        guard typed != shown.trimmingCharacters(in: .whitespaces) else { return nil }
        let number = typed.replacingOccurrences(of: ",", with: ".").replacingOccurrences(of: "×", with: "")
            .trimmingCharacters(in: .whitespaces)
        guard let speed = Double(number), speed.isFinite else { return nil }
        return speed
    }
}
