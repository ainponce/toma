// SPDX-License-Identifier: GPL-3.0-or-later

/// The id of a share link (fases 4 y 5 design §8.2): 10 characters at random of base 32 in lowercase, the name of the
/// folder (`<prefix><id>/`) its three objects go to. 50 bits: two links of a bucket never meet.
public enum ShareID {
    public static let length = 10
    /// RFC 4648's base 32 alphabet, in lowercase: no `0`, `1`, `8` or `9`, so an id read aloud is never ambiguous.
    public static let alphabet = "abcdefghijklmnopqrstuvwxyz234567"

    /// A new id, from the system's random number generator.
    public static func random() -> String {
        var generator = SystemRandomNumberGenerator()
        let letters = Array(alphabet)
        return String((0..<length).map { _ in letters[Int(generator.next(upperBound: UInt(letters.count)))] })
    }

    /// Whether `id` is `length` characters of `alphabet`.
    public static func isValid(_ id: String) -> Bool {
        id.count == length && id.allSatisfy { alphabet.contains($0) }
    }
}
