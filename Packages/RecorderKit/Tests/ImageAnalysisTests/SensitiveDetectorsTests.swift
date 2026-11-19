// SPDX-License-Identifier: GPL-3.0-or-later

import Testing
@testable import ImageAnalysis

@Suite("SensitiveDetectors")
struct SensitiveDetectorsTests {
    /// The found texts of one kind, in order.
    private func found(_ line: String, _ kind: SensitiveKind? = nil) -> [String] {
        SensitiveDetectors.matches(in: line).filter { kind == nil || $0.kind == kind }.map { String(line[$0.range]) }
    }

    private func kinds(_ line: String) -> [SensitiveKind] { SensitiveDetectors.matches(in: line).map(\.kind) }

    /// `digits` followed by the Luhn check digit.
    private func luhn(_ digits: String) -> String {
        let values = digits.map { UInt8(String($0))! }
        for check in UInt8(0)...9 where SensitiveDetectors.passesLuhn(values + [check]) { return digits + String(check) }
        fatalError()
    }

    /// A deterministic pseudo-random base-62 string.
    private func randomToken(length: Int, seed: UInt64 = 0x5EED) -> String {
        let alphabet = Array("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789")
        var state = seed
        return String((0..<length).map { _ in
            state = state &* 6364136223846793005 &+ 1442695040888963407
            return alphabet[Int((state >> 33) % UInt64(alphabet.count))]
        })
    }

    @Test func emailsAreFound() {
        #expect(found("Escribir a ana.perez@gmail.com.") == ["ana.perez@gmail.com"])
        #expect(found("(juan+tag@mail.empresa.com.ar)", .email) == ["juan+tag@mail.empresa.com.ar"])
        #expect(found("a@b").isEmpty)
        #expect(found("@usuario y user@localhost").isEmpty)
    }

    @Test func phonesNeedEightDigits() {
        #expect(found("Tel: +54 11 4567-8901 ahora") == ["+54 11 4567-8901"])
        #expect(found("(011) 4567-8901", .phone) == ["(011) 4567-8901"])
        #expect(found("555.123.4567", .phone) == ["555.123.4567"])
        #expect(found("12345678", .phone) == ["12345678"])
        #expect(found("4567-890").isEmpty)
        #expect(found("1234567").isEmpty)
    }

    @Test func datesAndTimesAreNotPhones() {
        for line in ["2026-11-19", "19/11/2026", "12:30:45", "2026-11-19 12:30:45", "2026-11-19 10:20", "20261119",
                     "19.11.2026", "Version 10.15.7.2345", "192.168.100.1", "3.14159265", "1234567.89", "10.0.0.1"] {
            #expect(found(line, .phone).isEmpty, "\(line)")
        }
    }

    @Test func cardsPassLuhn() {
        #expect(found("Visa 4242 4242 4242 4242 ok") == ["4242 4242 4242 4242"])
        #expect(found("4242-4242-4242-4242", .card) == ["4242-4242-4242-4242"])
        #expect(found("4242424242424242", .card) == ["4242424242424242"])
        #expect(!kinds("4242 4242 4242 4241").contains(.card))
        #expect(found("4222222222222", .card) == ["4222222222222"])
        let nineteen = luhn("4242424242424242" + "00")
        #expect(nineteen.count == 19 && found(nineteen, .card) == [nineteen])
        #expect(!kinds(luhn("42424242424")).contains(.card))   // 12 digits
        #expect(!kinds(luhn(String(repeating: "7", count: 19))).contains(.card))   // 20 digits
        // A card inside a longer run of numbers.
        #expect(found("Orden 77 4242 4242 4242 4242", .card) == ["4242 4242 4242 4242"])
    }

    @Test func keysByPrefix() {
        let samples = [
            "sk-abcdEFGH1234", "sk_live_51HabcDEF99", "pk_live_51HabcDEF99", "rk_live_51HabcDEF99", "ghp_abcdEFGH1234",
            "gho_abcdEFGH1234", "ghs_abcdEFGH1234", "github_pat_11ABCDEFG0abcd", "glpat-abcdEFGH1234",
            "xoxa-1234567890ab", "xoxb-1234567890ab", "xoxp-1234567890ab", "xoxr-1234567890ab",
            "AKIAIOSFODNN7EXAMPLE", "AIza" + String(repeating: "aB3_-", count: 7),
        ]
        for sample in samples {
            let line = "export KEY=\(sample) # nota"
            #expect(found(line, .secret) == [sample], "\(sample)")
        }
        #expect(found("usa sk- para las claves").isEmpty)
        #expect(found("sk-corto").isEmpty)   // fewer than 8 after the prefix
        #expect(found("desk-organizer-planning risk-assessment-team").isEmpty)   // the prefix inside a word
    }

    @Test func jwtIsASecret() {
        let jwt = "eyJhbGciOiJIUzI1NiJ9.eyJzdWIiOiIxMjM0NTY3ODkwIn0.dBjftJeZ4CVPmB92K27uhbUJU1p1r_wW1gFWFOEjXk"
        #expect(found("Authorization: Bearer \(jwt)") == [jwt])
        #expect(kinds(jwt) == [.secret])
    }

    @Test func highEntropyTokensOnly() {
        let token = randomToken(length: 32)
        #expect(token.contains(where: \.isNumber) && token.contains(where: \.isLetter))
        #expect(found("token \(token) fin", .token) == [token])
        #expect(found("API_KEY=\(token)", .token) == [token])
        #expect(found("abcdefghijklmnopqrstuvwxyzABCD").isEmpty)   // 30 letters
        #expect(found("123e4567-e89b-12d3-a456-426614174000").isEmpty)   // a UUID
        #expect(found(String(repeating: "a1", count: 15)).isEmpty)   // long but no entropy
        #expect(found(String(token.prefix(23))).isEmpty)   // too short
    }

    @Test func ordinaryTextIsLeftAlone() {
        for line in ["The quick brown fox jumps over the lazy dog 123", "Versión 2.4.1 (build 5678) publicada el 3 de mayo",
                     "Reunión a las 10:30 con el equipo de ventas", "~/Library/Application Support/Toma/Projects/cache",
                     "internationalization-2026-localization-v2", "https://github.com/ainponce/screen-recorder/issues/12",
                     "Total: 1.234,56 USD", "Pedido 4821 de 3 artículos", "IMG_20261119_123045.png", "build-a1b2c3d4e5f60718", "feature/fase-2-privacy-detectors-v3-final"] {
            #expect(found(line).isEmpty, "\(line)")
        }
    }

    @Test func precedenceAndNoOverlap() {
        let live = "sk_live_" + randomToken(length: 40)
        #expect(kinds(live) == [.secret])
        #expect(kinds("john1234567890@gmail.com") == [.email])
        // A card is not also a phone; an email in a URL query is one email.
        #expect(kinds("4242 4242 4242 4242") == [.card])
        let line = "ana@x.com 4242 4242 4242 4242 sk-abcdEFGH1234"
        let result = SensitiveDetectors.matches(in: line)
        #expect(result.map(\.kind) == [.email, .card, .secret])
        for (a, b) in zip(result, result.dropFirst()) { #expect(a.range.upperBound <= b.range.lowerBound) }
    }

    @Test func rangesAreOfTheOriginalLine() {
        let line = "Año nuevo 🎉🇦🇷 niño: ana@gmail.com y 4242 4242 4242 4242 y +54 11 4567-8901 ñ"
        #expect(found(line) == ["ana@gmail.com", "4242 4242 4242 4242", "+54 11 4567-8901"])
        let date = "Año 🎉 2026-11-19 12:30 y 4567-8901 22"
        #expect(found(date, .phone) == ["4567-8901 22"])
    }

    @Test func luhnAndEntropy() {
        #expect(SensitiveDetectors.passesLuhn([4, 2, 4, 2, 4, 2, 4, 2, 4, 2, 4, 2, 4, 2, 4, 2]))
        #expect(!SensitiveDetectors.passesLuhn([4, 2, 4, 2, 4, 2, 4, 2, 4, 2, 4, 2, 4, 2, 4, 1]))
        #expect(!SensitiveDetectors.passesLuhn([]) && !SensitiveDetectors.passesLuhn([0]))
        #expect(SensitiveDetectors.entropy("aaaa") == 0)
        #expect(abs(SensitiveDetectors.entropy("abcd") - 2) < 1e-9)
    }

    @Test func originAndId() {
        #expect(SensitiveKind.token.origin == .secret && SensitiveKind.secret.origin == .secret)
        #expect(SensitiveKind.face.origin == .face && SensitiveKind.email.origin == .email)
        #expect(SensitiveDetectors.id == "sensitiveScan-1")
    }

    @Test func maskedLooksLikeTheDesign() {
        func mask(_ text: String, _ kind: SensitiveKind) -> String { SensitiveText.masked(Substring(text), kind: kind) }
        #expect(mask("ana.perez@gmail.com", .email) == "an•••@g•••.com")
        #expect(mask("juan@mail.empresa.com.ar", .email) == "ju•••@m•••.ar")
        #expect(mask("a@b.co", .email) == "•••@•••.co")
        #expect(mask("4242 4242 4242 4242", .card) == "•••• 4242")
        #expect(mask("4242-4242-4242-4242", .card) == "•••• 4242")
        #expect(mask("sk-abcdEFGH1234", .secret) == "sk-•••")
        #expect(mask("sk_live_51HabcDEF99", .secret) == "sk_live_•••")
        #expect(mask("ghp_abcdEFGH1234", .secret) == "ghp_•••")
        #expect(mask("github_pat_11ABCDEFG0abcd", .secret) == "github_pat_•••")
        #expect(mask("eyJhbGciOiJIUzI1NiJ9.eyJzdWIi.dBjft", .secret) == "eyJ•••")
        #expect(mask("AKIAIOSFODNN7EXAMPLE", .secret) == "AKIA•••")
        #expect(mask("+54 11 4567-8901", .phone) == "•••• 01")
        #expect(mask("Zk3q9TxW0pLm4RvB7nYc2HsD8eFa", .token) == "Zk3•••")
        #expect(mask("cualquier cosa", .face) == "")
    }

    @Test func maskedNeverRevealsTheWholeText() {
        func mask(_ text: String, _ kind: SensitiveKind) -> String { SensitiveText.masked(Substring(text), kind: kind) }
        #expect(!mask("1234", .phone).contains("1234"))
        #expect(!mask("ab", .token).contains("ab"))
        #expect(mask("", .email) == "•••")
        // A mask of what the detectors find never holds the plain text.
        let token = randomToken(length: 32)
        #expect(!mask(token, .token).contains(token))
    }
}
