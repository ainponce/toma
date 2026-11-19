// SPDX-License-Identifier: GPL-3.0-or-later

/// What the findings sheet and the cache keep of a found text: a masked form, never the text itself (design §7.2).
public enum SensitiveText {
    static let dots = "•••"

    /// The masked form of `text`, found by a detector of `kind`:
    /// - email: `an•••@g•••.com` (the first two letters of the user, the first of the domain and its last label);
    /// - card: `•••• 4242`; phone: `•••• 01` (the last digits only);
    /// - secret: the known prefix and `•••` (`sk-•••`, `ghp_•••`, `eyJ•••`, `AKIA•••`);
    /// - token: its first three characters and `•••`; face: no text (the sheet says "Cara").
    ///
    /// A short text never shows itself whole: an email of one letter before the `@` shows none of them.
    public static func masked(_ text: Substring, kind: SensitiveKind) -> String {
        switch kind {
        case .email: return maskedEmail(text)
        case .card: return "•••• " + lastDigits(of: text, count: 4)
        case .phone: return "•••• " + lastDigits(of: text, count: 2)
        case .secret: return maskedSecret(text)
        case .token: return String(text.prefix(min(3, max(0, text.count - 1)))) + dots
        case .face: return ""
        }
    }

    private static func lastDigits(of text: Substring, count: Int) -> String {
        let digits = text.filter { $0.isASCII && $0.isNumber }
        return String(digits.suffix(min(count, max(0, digits.count - 1))))
    }

    private static func maskedEmail(_ text: Substring) -> String {
        guard let at = text.lastIndex(of: "@") else { return String(text.prefix(2)) + dots }
        let user = text[text.startIndex..<at]
        let domain = text[text.index(after: at)...]
        let userKeep = min(2, max(0, user.count - 1))
        var result = String(user.prefix(userKeep)) + dots + "@"
        if let lastDot = domain.lastIndex(of: "."), lastDot != domain.startIndex {
            let name = domain[domain.startIndex..<lastDot]
            result += String(name.prefix(min(1, max(0, name.count - 1)))) + dots + String(domain[lastDot...])
        } else {
            result += String(domain.prefix(min(1, max(0, domain.count - 1)))) + dots
        }
        return result
    }

    /// Longest first, so `github_pat_` is never read as something shorter.
    private static let maskPrefixes: [String] = (SensitiveDetectors.secretPrefixes + ["AKIA", "AIza", "eyJ"])
        .sorted { $0.count > $1.count }

    private static func maskedSecret(_ text: Substring) -> String {
        if let prefix = maskPrefixes.first(where: { text.hasPrefix($0) }) { return prefix + dots }
        return String(text.prefix(min(3, max(0, text.count - 1)))) + dots
    }
}
