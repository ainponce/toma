// SPDX-License-Identifier: GPL-3.0-or-later
import AppSupport
import Foundation
import ProjectFormat
import Testing

@Suite struct AudioRowTextTests {
    private static let spanish = Locale(identifier: "es_AR")
    private static let english = Locale(identifier: "en_US")

    @Test func aGainIsWrittenToATenthWithItsSign() {
        #expect(AudioRowText.decibels(0, locale: Self.english) == "0")
        #expect(AudioRowText.decibels(-6, locale: Self.english) == "\u{2212}6")
        #expect(AudioRowText.decibels(6, locale: Self.english) == "+6")
        #expect(AudioRowText.decibels(3.5, locale: Self.spanish) == "+3,5")
        #expect(AudioRowText.decibels(3.5, locale: Self.english) == "+3.5")
        #expect(AudioRowText.decibels(-12.04, locale: Self.spanish) == "\u{2212}12")
        #expect(AudioRowText.decibels(-0.04, locale: Self.english) == "0", "what rounds to 0 has no sign")
        #expect(AudioRowText.decibels(12, locale: Self.english) == "+12")
        #expect(AudioRowText.decibels(.nan, locale: Self.english) == "0")
    }

    @Test func minusInfinityHasNoNumber() {
        #expect(AudioRowText.decibels(GainRange.silence, locale: Self.english) == nil)
        #expect(AudioRowText.decibels(-200, locale: Self.english) == nil)
        #expect(AudioRowText.decibels(-.infinity, locale: Self.english) == nil)
        #expect(AudioRowText.decibels(-119.9, locale: Self.english) != nil)
    }

    @Test func aTypedGainIsReadAsTyped() {
        #expect(AudioRowText.gain(from: "-6") == -6)
        #expect(AudioRowText.gain(from: "\u{2212}6") == -6)
        #expect(AudioRowText.gain(from: "+3,5") == 3.5)
        #expect(AudioRowText.gain(from: "3.5 dB") == 3.5)
        #expect(AudioRowText.gain(from: " -4,5dB ") == -4.5)
        #expect(AudioRowText.gain(from: "0") == 0)
        #expect(AudioRowText.gain(from: "12 DB") == 12)
        // What the capsule shows reads back as itself.
        for dB in [-48.0, -6, -0.5, 0, 0.5, 6, 12] {
            for locale in [Self.spanish, Self.english] {
                let shown = AudioRowText.decibels(dB, locale: locale)
                #expect(shown.flatMap(AudioRowText.gain(from:)) == dB)
            }
        }
    }

    @Test func minusInfinityCanBeTyped() {
        for text in ["-∞", "\u{2212}∞", "−∞ dB", "-inf", "-INF dB"] {
            #expect(AudioRowText.gain(from: text) == GainRange.silence, "\(text)")
        }
    }

    @Test func whatIsNotAGainIsNothing() {
        for text in ["", "  ", "loud", "∞", "+∞", "inf", "6-", "1,2,3", "nan", "dB"] {
            #expect(AudioRowText.gain(from: text) == nil, "\(text)")
        }
    }

    @Test func aMovedCutIsItsDistanceInSeconds() {
        #expect(AudioRowText.shift(-300_000_000, locale: Self.spanish) == "0,30 s")
        #expect(AudioRowText.shift(300_000_000, locale: Self.english) == "0.30 s")
        #expect(AudioRowText.shift(1_234_000_000, locale: Self.spanish) == "1,23 s")
        #expect(AudioRowText.shift(5_000_000, locale: Self.english) == "0.01 s")
        #expect(AudioRowText.shift(0, locale: Self.english) == "0.00 s")
        #expect(AudioRowText.shift(.min, locale: Self.english).hasSuffix(" s"))
    }

    @Test func aCutIsJBeforeAndLAfter() {
        #expect(AudioRowText.cut(-1) == .j)
        #expect(AudioRowText.cut(-300_000_000) == .j)
        #expect(AudioRowText.cut(1) == .l)
        #expect(AudioRowText.cut(0) == nil)
    }
}
