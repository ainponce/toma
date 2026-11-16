// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation

/// Why a name cannot be a project's (design §6.3). The app says it in words.
public enum NameProblem: Error, Equatable, Sendable {
    /// Nothing is left once the spaces at the ends are taken away.
    case empty
    /// It has a `/` or a `:`.
    case slashOrColon
    /// It starts with `.`: a hidden file.
    case leadingDot
    /// It has a control character (Unicode category Cc: a new line, a tab inside it, `U+0007`…).
    case controlCharacter
    /// It is longer than `ProjectNames.maxBytes` in UTF-8.
    case tooLong
    /// A project in that folder already has it.
    case taken
}

/// The names of projects: which the user may give one, and the names of copies (design §6.3). A name is the package's
/// without `.toma`. Two names are the same name when they differ only in case or in Unicode normalization ("Café"
/// composed and decomposed), as on APFS. The words (the app's «copia», «copia %d», «vertical»…) come from the app.
public enum ProjectNames {
    /// The longest name, in UTF-8 bytes: room is left for « copia 2» and `.toma` within the 255 bytes of a file name.
    public static let maxBytes = 200

    /// `raw` without the spaces and new lines at its ends, if that is a name the user may give a project in a folder
    /// whose projects are named `existing`; otherwise the first problem it has, in the order of `NameProblem`. A name
    /// that is taken is refused, never changed: the user chose it.
    public static func validate(_ raw: String, existing: [String]) -> Result<String, NameProblem> {
        let name = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        // By scalar, not by character: a «/» or a «.» followed by a combining mark is still that byte on disk.
        let scalars = name.unicodeScalars
        if name.isEmpty { return .failure(.empty) }
        if scalars.contains(where: { $0 == "/" || $0 == ":" }) { return .failure(.slashOrColon) }
        if scalars.first == "." { return .failure(.leadingDot) }
        if scalars.contains(where: { $0.properties.generalCategory == .control }) { return .failure(.controlCharacter) }
        if name.utf8.count > maxBytes { return .failure(.tooLong) }
        if Set(existing.map(key)).contains(key(name)) { return .failure(.taken) }
        return .success(name)
    }

    /// The name of a copy of `base` in a folder whose projects are named `existing`: `"<base> <copy>"` («Demo copia»)
    /// or, while that is taken, `"<base> <numbered(n)>"` for n = 2, 3, … («Demo copia 2»). A copy of a copy is named
    /// from the original, as in Finder: a `base` that ends in « <copy>» or « <numbered(n)>», n ≥ 2, is a copy of what
    /// comes before, so «Demo copia» gives «Demo copia 2», never «Demo copia copia».
    public static func copyName(_ base: String, existing: [String], copy: String, numbered: (Int) -> String) -> String {
        let original = original(ofCopy: base, copy: copy, numbered: numbered) ?? base
        return firstFree("\(original) \(copy)", existing: existing) { "\(original) \(numbered($0))" }
    }

    /// What `name` is a copy of, if it is one: what comes before a final « <copy>» or « <numbered(n)>» for one of the
    /// numbers n ≥ 2 written in it, when something does.
    private static func original(ofCopy name: String, copy: String, numbered: (Int) -> String) -> String? {
        let numbers = name.split { !($0.isASCII && $0.isNumber) }.compactMap { Int($0) }.filter { $0 >= 2 }
        for word in [copy] + numbers.map(numbered) {
            let suffix = " \(word)"
            if name.count > suffix.count, name.hasSuffix(suffix) {
                return String(name.dropLast(suffix.count))
            }
        }
        return nil
    }

    /// The name of a copy of `base` in another format: `"<base> <suffix>"` («Demo vertical») or, while that is taken,
    /// `"<base> <suffix> <n>"` for n = 2, 3, … («Demo vertical 2»).
    public static func formatName(_ base: String, suffix: String, existing: [String]) -> String {
        firstFree("\(base) \(suffix)", existing: existing) { "\(base) \(suffix) \($0)" }
    }

    /// `first` if no name in `existing` is the same name, otherwise the first of `numbered(2)`, `numbered(3)`, … that is
    /// free.
    private static func firstFree(_ first: String, existing: [String], numbered: (Int) -> String) -> String {
        let taken = Set(existing.map(key))
        if !taken.contains(key(first)) { return first }
        var number = 2
        // `first` and `numbered(2)` … `numbered(existing.count + 1)` are `existing.count + 1` different names: one is free.
        while taken.contains(key(numbered(number))), number <= existing.count + 1 {
            number += 1
        }
        return numbered(number)
    }

    /// What two names that are the same name share: the name with its case folded. `String` compares and hashes by
    /// canonical equivalence, so the normalization does not count either.
    private static func key(_ name: String) -> String {
        name.folding(options: .caseInsensitive, locale: nil)
    }
}
