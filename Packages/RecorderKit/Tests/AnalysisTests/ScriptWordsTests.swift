// SPDX-License-Identifier: GPL-3.0-or-later
import Testing

@testable import Analysis

/// A script of 12 sentences of 10 words, 120 words, shared with the alignment tests.
enum ScriptFixtures {
    static let sentences = [
        "Bienvenidos a este tutorial sobre nuestra aplicación para grabar pantallas.",
        "Primero elegimos qué ventana queremos mostrar durante la sesión completa.",
        "Después ajustamos el micrófono verificando que el volumen sea correcto.",
        "Luego presionamos grabar y comenzamos nuestra explicación sin ninguna prisa.",
        "¿Notaron ahora cómo suavemente cambia el zoom hacia el cursor?",
        "Esa animación sigue cada movimiento sin perder jamás nuestra atención.",
        "Podemos añadir subtítulos automáticos generados directamente desde nuestra propia voz.",
        "También recortamos silencios incómodos borrando palabras desde el texto transcrito.",
        "Cuando terminamos, revisamos juntos todo el resultado antes de exportar.",
        "El archivo final queda listo para compartir con cualquier persona.",
        "Gracias por acompañarme hoy, espero que disfruten muchísimo esta herramienta.",
        "Nos vemos pronto con muchas novedades sorprendentes, hasta luego amigos.",
    ]
    static let text = sentences.joined(separator: " ")
    static let script = ScriptWords(text)

    /// The normalized words `range` of the script, as the speaker would say them.
    static func said(_ range: Range<Int>) -> [String] { range.map { script.words[$0].text } }
}

@Suite struct ScriptWordsTests {
    @Test func scriptHasOneHundredTwentyWords() {
        #expect(ScriptFixtures.script.words.count == 120)
    }

    @Test func normalizationIgnoresCaseAccentsAndSigns() {
        #expect(ScriptWords.normalized("¿Qué?") == "que")
        #expect(ScriptWords.normalized("Canción,") == "cancion")
        #expect(ScriptWords.normalized("3D") == "3d")
        #expect(ScriptWords.normalized("«ÁÉÍÓÚ Ñandú»") == "aeiounandu")
        #expect(ScriptWords.normalized("...") == "")
        #expect(ScriptWords.normalized("") == "")
    }

    @Test func normalizationOfDecomposedAccentsMatchesComposed() {
        #expect(ScriptWords.normalized("cancio\u{301}n") == ScriptWords.normalized("canción"))
    }

    @Test func wordsKeepTheirUTF16RangeInTheScript() {
        let text = "¡Hola, mundo!  Ñandú 😀 canción — 3D."
        let script = ScriptWords(text)
        #expect(script.words.map(\.text) == ["hola", "mundo", "nandu", "cancion", "3d"])
        let utf16 = Array(text.utf16)
        let written = script.words.map { String(decoding: utf16[$0.characters], as: UTF16.self) }
        #expect(written == ["Hola", "mundo", "Ñandú", "canción", "3D"])
    }

    @Test func hyphensAndDashesSeparateWordsButApostrophesDoNot() {
        #expect(ScriptWords("ocho-cientos y don't stop it’s").words.map(\.text) == ["ocho", "cientos", "y", "dont", "stop", "its"])
        #expect(ScriptWords("'hola' 'adios'").words.map(\.text) == ["hola", "adios"])
    }

    @Test func emptyAndSignOnlyScriptsHaveNoWords() {
        #expect(ScriptWords("").words.isEmpty)
        #expect(ScriptWords("  \n ¿¡ ... — ").words.isEmpty)
        #expect(ScriptWords("").sentenceStart(of: 0) == 0)
        #expect(ScriptWords("").sentenceStart(of: 5) == 0)
    }

    @Test func sentenceStartOfAWord() {
        let script = ScriptFixtures.script
        // Sentence 2 (index 1) is words 10..<20; the first word of the script starts sentence 0.
        #expect(script.sentenceStart(of: 14) == 10)
        #expect(script.sentenceStart(of: 10) == 10)
        #expect(script.sentenceStart(of: 19) == 10)
        #expect(script.sentenceStart(of: 20) == 20)
        #expect(script.sentenceStart(of: 3) == 0)
        #expect(script.sentenceStart(of: 119) == 110)
    }

    @Test func sentenceStartIsClamped() {
        let script = ScriptFixtures.script
        #expect(script.sentenceStart(of: -4) == 0)
        #expect(script.sentenceStart(of: 5_000) == 110)
    }

    @Test func everyKindOfSentenceEndStartsANewSentence() {
        let script = ScriptWords("uno dos. tres cuatro? cinco seis! siete ocho… nueve diez\nonce doce")
        #expect(script.words.count == 12)
        #expect((0..<12).map { script.sentenceStart(of: $0) } == [0, 0, 2, 2, 4, 4, 6, 6, 8, 8, 10, 10])
    }

    @Test func aLineBreakEndsASentenceWithoutPunctuation() {
        let script = ScriptWords("titulo de la seccion\nprimera frase sin punto\r\nsegunda")
        #expect(script.sentenceStart(of: 3) == 0)
        #expect(script.sentenceStart(of: 6) == 4)
        #expect(script.sentenceStart(of: 8) == 8)
    }

    @Test func signsThatDoNotEndASentenceDoNot() {
        // A decimal point, a comma, a dash, and "a.b" keep the sentence going; a closing quote after the full stop does not hide it.
        let script = ScriptWords("mide 3.5 metros, dice a.b - luego \"basta.\" ahora sigue")
        #expect(script.words.map(\.text) == ["mide", "3", "5", "metros", "dice", "a", "b", "luego", "basta", "ahora", "sigue"])
        #expect(script.sentenceStart(of: 7) == 0)
        #expect(script.sentenceStart(of: 10) == 9)
    }

    @Test func spanishQuestionMarksOpenNothing() {
        let script = ScriptWords("¿Vienes hoy? ¡Claro que sí! ¿Seguro?")
        #expect(script.words.map(\.text) == ["vienes", "hoy", "claro", "que", "si", "seguro"])
        #expect((0..<6).map { script.sentenceStart(of: $0) } == [0, 0, 2, 2, 2, 5])
    }

    @Test func sameScriptSameWords() {
        #expect(ScriptWords(ScriptFixtures.text) == ScriptWords(ScriptFixtures.text))
        #expect(ScriptWords("uno. dos") != ScriptWords("uno dos"))
    }
}
