// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation
import ProjectFormat

/// What a detector found. `token` is the generic high-entropy string; it is told apart from `secret` (a known key
/// shape) in the sheet but is blurred as one (`origin`).
public enum SensitiveKind: String, Codable, Sendable, CaseIterable {
    case email, phone, card, secret, token, face

    public var origin: PrivacyOrigin {
        switch self {
        case .email: .email
        case .phone: .phone
        case .card: .card
        case .secret, .token: .secret
        case .face: .face
        }
    }
}

public struct SensitiveMatch: Equatable, Sendable {
    public var kind: SensitiveKind
    /// The matched text, as a range of the line the detectors were given (so Vision's `boundingBox(for:)` takes it).
    public var range: Range<String.Index>

    public init(kind: SensitiveKind, range: Range<String.Index>) {
        self.kind = kind
        self.range = range
    }
}

/// `sensitiveScan-1`'s detectors (design §7.2), frozen: pure functions of one recognized line of text. They favor
/// recall (a missed secret is worse than an extra blur) but leave out the usual look-alikes: dates, times, versions,
/// IP addresses, decimals, UUIDs and ordinary words.
public enum SensitiveDetectors {
    public static let id = "sensitiveScan-1"
    public static let secretPrefixes: [String] = [
        "sk-", "sk_live_", "pk_live_", "rk_live_", "ghp_", "gho_", "ghs_", "github_pat_", "glpat-",
        "xoxa-", "xoxb-", "xoxp-", "xoxr-",
    ]
    public static let minimumTokenLength = 24
    public static let minimumEntropy = 4.0

    /// The findings of one line, left to right and without overlapping. Over the same text the first of: secret,
    /// card, email, phone, token wins.
    public static func matches(in line: String) -> [SensitiveMatch] {
        var candidates: [(priority: Int, match: SensitiveMatch)] = []
        func add(_ kind: SensitiveKind, _ range: Range<String.Index>) {
            let priority: Int
            switch kind {
            case .secret: priority = 0
            case .card: priority = 1
            case .email: priority = 2
            case .phone: priority = 3
            default: priority = 4
            }
            candidates.append((priority, SensitiveMatch(kind: kind, range: range)))
        }
        for range in secretRanges(in: line) { add(.secret, range) }
        for range in cardRanges(in: line) { add(.card, range) }
        for range in emailRanges(in: line) { add(.email, range) }
        for range in phoneRanges(in: line) { add(.phone, range) }
        for range in tokenRanges(in: line) { add(.token, range) }

        var accepted: [SensitiveMatch] = []
        for candidate in candidates.sorted(by: {
            ($0.priority, $0.match.range.lowerBound) < ($1.priority, $1.match.range.lowerBound)
        }) {
            let range = candidate.match.range
            if accepted.contains(where: { $0.range.overlaps(range) }) { continue }
            accepted.append(candidate.match)
        }
        return accepted.sorted { $0.range.lowerBound < $1.range.lowerBound }
    }

    /// Regexes are not `Sendable`; these are built once and only ever read.
    private struct Patterns: @unchecked Sendable {
        let email = #/[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}/#
        let secret: Regex<Substring> = {
            let prefixes = SensitiveDetectors.secretPrefixes.map { NSRegularExpression.escapedPattern(for: $0) }
                .joined(separator: "|")
            let pattern = "(?:(?:\(prefixes))[A-Za-z0-9_\\-]{8,}|AKIA[0-9A-Z]{16}|AIza[0-9A-Za-z_\\-]{35}"
                + "|eyJ[A-Za-z0-9_\\-]+\\.[A-Za-z0-9_\\-]+\\.[A-Za-z0-9_\\-]+)"
            // The pattern is built from constants.
            return try! Regex(pattern)
        }()
        /// What is never a phone number even with eight digits: dates, times and dotted versions or addresses.
        let notPhone: [Regex<Substring>] = [
            #/\d{4}[-/.]\d{1,2}[-/.]\d{1,2}/#,
            #/\d{1,2}[-/.]\d{1,2}[-/.]\d{2,4}/#,
            #/[0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12}/#,
            #/\d{1,2}:\d{2}(?::\d{2})?(?:\.\d+)?/#,
            #/\d{1,3}(?:\.\d{1,3}){2,}(?!\d)/#,
        ]
        let phone = #/\+?\(?\d(?:[ .\-()]{0,2}\d){6,}/#
        let tokenRun = #/[A-Za-z0-9_\-+/=]{24,}/#
        let uuid = #/[0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12}/#
    }

    private static let patterns = Patterns()

    // MARK: Luhn and entropy

    /// The Luhn check over decimal digits (each 0...9), from the last one.
    static func passesLuhn(_ digits: [UInt8]) -> Bool {
        guard digits.count > 1, digits.allSatisfy({ $0 <= 9 }) else { return false }
        var sum = 0
        for (offset, digit) in digits.reversed().enumerated() {
            var value = Int(digit)
            if offset % 2 == 1 {
                value *= 2
                if value > 9 { value -= 9 }
            }
            sum += value
        }
        return sum % 10 == 0
    }

    /// Shannon entropy in bits per character.
    static func entropy(_ text: Substring) -> Double {
        guard !text.isEmpty else { return 0 }
        var counts: [Character: Int] = [:]
        for character in text { counts[character, default: 0] += 1 }
        let total = Double(text.count)
        return counts.values.reduce(0) { sum, count in
            let p = Double(count) / total
            return sum - p * log2(p)
        }
    }

    /// Swift's regex has no lookbehind: whether the character before `range` is one that makes the match a piece of
    /// something longer.
    private static func isPreceded(by test: (Character) -> Bool, range: Range<String.Index>, in text: String) -> Bool {
        guard range.lowerBound > text.startIndex else { return false }
        return test(text[text.index(before: range.lowerBound)])
    }

    // MARK: Email

    private static func emailRanges(in line: String) -> [Range<String.Index>] {
        line.matches(of: patterns.email).map(\.range)
    }

    // MARK: Secrets

    private static func secretRanges(in line: String) -> [Range<String.Index>] {
        line.matches(of: patterns.secret).map(\.range).filter { !isPreceded(by: { $0.isASCII && ($0.isLetter || $0.isNumber) }, range: $0, in: line) }
    }

    // MARK: Cards

    /// Runs of digits joined by one space or hyphen; inside each, the longest stretch of whole groups of 13 to 19
    /// digits that passes Luhn.
    private static func cardRanges(in line: String) -> [Range<String.Index>] {
        struct Group { var start: String.Index; var end: String.Index; var digits: [UInt8] }
        var groups: [Group] = []
        var index = line.startIndex
        while index < line.endIndex {
            guard let value = digit(line[index]) else { index = line.index(after: index); continue }
            let start = index
            var digits = [value]
            index = line.index(after: index)
            while index < line.endIndex, let next = digit(line[index]) {
                digits.append(next)
                index = line.index(after: index)
            }
            groups.append(Group(start: start, end: index, digits: digits))
        }
        // Chains of groups that touch through exactly one separator.
        var results: [Range<String.Index>] = []
        var chainStart = 0
        while chainStart < groups.count {
            var chainEnd = chainStart
            while chainEnd + 1 < groups.count, isCardSeparator(line, between: groups[chainEnd].end, and: groups[chainEnd + 1].start) {
                chainEnd += 1
            }
            var first = chainStart
            while first <= chainEnd {
                var found = false
                var last = chainEnd
                while last >= first {
                    let digits = groups[first...last].flatMap(\.digits)
                    if (13...19).contains(digits.count), passesLuhn(digits) {
                        results.append(groups[first].start..<groups[last].end)
                        first = last + 1
                        found = true
                        break
                    }
                    last -= 1
                }
                if !found { first += 1 }
            }
            chainStart = chainEnd + 1
        }
        return results
    }

    private static func digit(_ character: Character) -> UInt8? {
        guard let ascii = character.asciiValue, ascii >= 48, ascii <= 57 else { return nil }
        return ascii - 48
    }

    private static func isCardSeparator(_ line: String, between end: String.Index, and start: String.Index) -> Bool {
        guard line.index(after: end) == start else { return false }
        return line[end] == " " || line[end] == "-"
    }

    // MARK: Phones

    /// What is never a phone number even with eight digits: dates, times and dotted versions or addresses.
    private static func phoneRanges(in line: String) -> [Range<String.Index>] {
        // The look-alikes are blanked (one character for each, so the offsets stay) before looking for phones.
        var characters = Array(line)
        for regex in patterns.notPhone {
            let current = String(characters)
            for match in current.matches(of: regex)
            where !isPreceded(by: { digit($0) != nil }, range: match.range, in: current) {
                let lower = current.distance(from: current.startIndex, to: match.range.lowerBound)
                let upper = current.distance(from: current.startIndex, to: match.range.upperBound)
                for offset in lower..<upper { characters[offset] = "_" }
            }
        }
        let blanked = String(characters)
        var results: [Range<String.Index>] = []
        for match in blanked.matches(of: patterns.phone) {
            let text = blanked[match.range]
            guard isPhoneShaped(text) else { continue }
            // Glued to letters or `_` it is part of an identifier (`IMG_20261119_123045`, `abc1234567890`).
            if isPreceded(by: { $0.isLetter || $0 == "_" }, range: match.range, in: blanked)
                || (match.range.upperBound < blanked.endIndex
                    && (blanked[match.range.upperBound].isLetter || blanked[match.range.upperBound] == "_")) { continue }
            let lower = blanked.distance(from: blanked.startIndex, to: match.range.lowerBound)
            let upper = blanked.distance(from: blanked.startIndex, to: match.range.upperBound)
            results.append(line.index(line.startIndex, offsetBy: lower)..<line.index(line.startIndex, offsetBy: upper))
        }
        return results
    }

    private static func isPhoneShaped(_ text: Substring) -> Bool {
        let digits = text.filter { digit($0) != nil }
        guard digits.count >= 8 else { return false }
        // 20261119: a compact date.
        if digits.count == 8, digits.count == text.count,
           let year = Int(digits.prefix(4)), (1900...2099).contains(year),
           let month = Int(digits.dropFirst(4).prefix(2)), (1...12).contains(month),
           let day = Int(digits.suffix(2)), (1...31).contains(day) {
            return false
        }
        // Only dots between the digits: a decimal (1234567.89), a version (10.15.7.2345) or an address; 555.123.4567 stays.
        let body = text.drop { $0 == "+" }
        if body.allSatisfy({ digit($0) != nil || $0 == "." }) && body.contains(".") {
            let groups = body.split(separator: ".", omittingEmptySubsequences: false)
            if groups.count != 3 || groups.allSatisfy({ $0.count <= 3 }) { return false }
        }
        return true
    }

    // MARK: Generic tokens

    private static func tokenRanges(in line: String) -> [Range<String.Index>] {
        var results: [Range<String.Index>] = []
        for match in line.matches(of: patterns.tokenRun) {
            // `NAME=value`: an inner `=` ends the name; a trailing `=` is base64 padding and stays.
            var start = match.range.lowerBound
            var cursor = start
            var segments: [Range<String.Index>] = []
            while cursor < match.range.upperBound {
                if line[cursor] == "=", line.index(after: cursor) < match.range.upperBound,
                   line[line.index(after: cursor)] != "=" {
                    segments.append(start..<cursor)
                    start = line.index(after: cursor)
                }
                cursor = line.index(after: cursor)
            }
            segments.append(start..<match.range.upperBound)
            for segment in segments where isToken(line[segment]) { results.append(segment) }
        }
        return results
    }

    private static func isToken(_ text: Substring) -> Bool {
        guard text.count >= minimumTokenLength else { return false }
        guard text.contains(where: { $0.isASCII && $0.isLetter }), text.contains(where: { digit($0) != nil }) else { return false }
        if text.wholeMatch(of: patterns.uuid) != nil { return false }
        // A slug or a path (`feature/fase-2-privacy-v3`): half of it or more is lowercase words between separators.
        let words = text.split(whereSeparator: { "-_/+=".contains($0) })
        let wordCharacters = words.filter { $0.count >= 3 && $0.allSatisfy { $0.isASCII && $0.isLowercase } }
            .reduce(0) { $0 + $1.count }
        if words.count >= 3, wordCharacters * 2 >= text.count { return false }
        return entropy(text) >= minimumEntropy
    }
}
