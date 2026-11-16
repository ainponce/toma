// SPDX-License-Identifier: GPL-3.0-or-later
import AppSupport
import Testing

/// A speed of 1.333 is shown «1,33», and OK on the field as it was prefilled leaves it at 1.333, not 1.33 (final fix wave
/// re-review): the rounding is for display only.
@Test func aCustomSpeedLeftAsShownStaysExactlyAsItWas() {
    let entry = CustomSpeedEntry(shown: "1,33")
    #expect(entry.speed(from: "1,33") == nil)
    #expect(entry.speed(from: "  1,33 ") == nil)
    // Typed: read as typed, with a comma or a point, with or without "×".
    #expect(entry.speed(from: "1,5") == 1.5)
    #expect(entry.speed(from: "1.33") == 1.33, "typed again by hand, it is what was typed")
    #expect(entry.speed(from: "2×") == 2)
    #expect(entry.speed(from: " 0,25 × ") == 0.25)
    #expect(entry.speed(from: "fast") == nil)
    #expect(entry.speed(from: "") == nil)
    #expect(entry.speed(from: "inf") == nil)
}
