// SPDX-License-Identifier: GPL-3.0-or-later
import Library
import Testing

@Test func validNamesAreTrimmed() {
    #expect(ProjectNames.validate("  Demo  ", existing: []) == .success("Demo"))
    #expect(ProjectNames.validate("\tDemo final\n", existing: []) == .success("Demo final"))
    // What is inside stays as typed: inner spaces, accents, emoji joined with U+200D (a format character, not a
    // control one) and a dot that is not the first character.
    #expect(ProjectNames.validate("Demo  v1.2 👩‍💻 Café", existing: []) == .success("Demo  v1.2 👩‍💻 Café"))
}

@Test func invalidNamesSayWhy() {
    #expect(ProjectNames.validate("", existing: []) == .failure(.empty))
    #expect(ProjectNames.validate("   ", existing: []) == .failure(.empty))
    #expect(ProjectNames.validate("a/b", existing: []) == .failure(.slashOrColon))
    #expect(ProjectNames.validate("a:b", existing: []) == .failure(.slashOrColon))
    #expect(ProjectNames.validate(".x", existing: []) == .failure(.leadingDot))
    // Trimmed first: the dot is then the first character.
    #expect(ProjectNames.validate("  .x", existing: []) == .failure(.leadingDot))
    #expect(ProjectNames.validate("a\u{7}", existing: []) == .failure(.controlCharacter))
    #expect(ProjectNames.validate("a\nb", existing: []) == .failure(.controlCharacter))
    #expect(ProjectNames.validate("a\u{7F}b", existing: []) == .failure(.controlCharacter))

    // The limit is in UTF-8 bytes, not characters: 100 «é» are 200 bytes, one more is 202.
    let twoHundred = String(repeating: "é", count: 100)
    #expect(twoHundred.utf8.count == ProjectNames.maxBytes)
    #expect(ProjectNames.validate(twoHundred, existing: []) == .success(twoHundred))
    #expect(ProjectNames.validate(String(repeating: "a", count: 201), existing: []) == .failure(.tooLong))
    #expect(ProjectNames.validate(twoHundred + "a", existing: []) == .failure(.tooLong))
}

@Test func nameCollisionIgnoresCaseAndNormalization() {
    let composed = "Caf\u{E9}"
    let decomposed = "Cafe\u{301}"
    #expect(Array(composed.unicodeScalars) != Array(decomposed.unicodeScalars))

    let existing = [composed]
    #expect(ProjectNames.validate("café", existing: existing) == .failure(.taken))
    #expect(ProjectNames.validate(decomposed, existing: existing) == .failure(.taken))
    #expect(ProjectNames.validate("  CAFÉ ", existing: existing) == .failure(.taken))
    #expect(ProjectNames.validate("Cafe", existing: existing) == .success("Cafe"))
    // And the other way round: a decomposed name in the folder takes the composed one.
    #expect(ProjectNames.validate(composed, existing: [decomposed]) == .failure(.taken))
}

@Test func copyNamesCount() {
    let numbered: (Int) -> String = { "copia \($0)" }
    #expect(ProjectNames.copyName("Demo", existing: [], copy: "copia", numbered: numbered) == "Demo copia")
    #expect(ProjectNames.copyName("Demo", existing: ["Demo copia"], copy: "copia", numbered: numbered) == "Demo copia 2")
    #expect(
        ProjectNames.copyName("Demo", existing: ["Demo copia", "Demo copia 2"], copy: "copia", numbered: numbered)
            == "Demo copia 3")
    // A copy name taken in another case or normalization is taken too.
    #expect(ProjectNames.copyName("Café", existing: ["cafe\u{301} COPIA"], copy: "copia", numbered: numbered) == "Café copia 2")
    // The words are the app's: English counts the same way.
    #expect(ProjectNames.copyName("Demo", existing: ["Demo copy"], copy: "copy", numbered: { "copy \($0)" }) == "Demo copy 2")
}

@Test func formatNamesCount() {
    #expect(ProjectNames.formatName("Demo", suffix: "vertical", existing: ["Demo"]) == "Demo vertical")
    #expect(ProjectNames.formatName("Demo", suffix: "vertical", existing: ["demo VERTICAL"]) == "Demo vertical 2")
    #expect(
        ProjectNames.formatName("Demo", suffix: "cuadrado", existing: ["Demo cuadrado", "Demo cuadrado 2"]) == "Demo cuadrado 3")
}
