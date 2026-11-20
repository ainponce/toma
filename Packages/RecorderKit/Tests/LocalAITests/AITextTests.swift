// SPDX-License-Identifier: GPL-3.0-or-later
import ProjectFormat
import Testing

@testable import LocalAI

@Suite struct AITextTests {
    @Test func titlesAreCleanedAndBounded() {
        #expect(AIText.title("«1. Instalar el paquete.»", limit: 40) == "Instalar el paquete")
        #expect(AIText.title("  \"Configurar   el\nentorno\"  ", limit: 40) == "Configurar el entorno")
        #expect(AIText.title("“Primeros pasos”.", limit: 40) == "Primeros pasos")
        #expect(AIText.title("- Primeros pasos", limit: 40) == "Primeros pasos")
        #expect(AIText.title("• Primeros pasos", limit: 40) == "Primeros pasos")
        #expect(AIText.title("2) Probar", limit: 40) == "Probar")
        #expect(AIText.title("'Cierre'", limit: 40) == "Cierre")
        // What is not numbering, a quote that does not wrap, a question and an ellipsis stay.
        #expect(AIText.title("3 formas de instalar", limit: 40) == "3 formas de instalar")
        #expect(AIText.title("El comando \"ls\"", limit: 40) == "El comando \"ls\"")
        #expect(AIText.title("¿Qué es Swift?", limit: 40) == "¿Qué es Swift?")
        #expect(AIText.title("1.5 segundos de espera", limit: 40) == "1.5 segundos de espera")

        // 60 characters: cut at the last space within 40.
        let long = "Cómo instalar y configurar el paquete de herramientas en macOS"
        let cut = AIText.title(long, limit: 40)
        #expect(cut == "Cómo instalar y configurar el paquete de")
        #expect(cut.map { $0.count <= 40 } == true)
        // No space: at 40.
        #expect(AIText.title(String(repeating: "a", count: 50), limit: 40) == String(repeating: "a", count: 40))
        // The word that ends right at the limit stays.
        #expect(AIText.title("Uno dos tres", limit: 7) == "Uno dos")
        // A cut leaves no comma or period at the end.
        #expect(AIText.title("Instalar, configurar y probar", limit: 10) == "Instalar")

        for empty in ["", "  ", "\"\"", "«»", "1.", "-", " \n "] {
            #expect(AIText.title(empty, limit: 40) == nil, "\(empty)")
        }
    }

    @Test func summaryKeepsFourSentences() {
        let six = "Uno es el primero. Dos sigue. ¿Tres? ¡Cuatro! Cinco. Seis."
        #expect(AIText.summary(six) == "Uno es el primero. Dos sigue. ¿Tres? ¡Cuatro!")
        #expect(AIText.summary("  Primero esto.\nDespués\n\naquello.  ") == "Primero esto. Después aquello.")
        #expect(AIText.summary("«Un video sobre Swift.»") == "Un video sobre Swift.")
        #expect(AIText.summary("Sin punto final") == "Sin punto final")

        // Over the limit: cut at a sentence.
        let sentence = String(repeating: "palabra ", count: 110).trimmingCharacters(in: .whitespaces) + "."
        #expect(sentence.count > 800)
        let three = [sentence, sentence, sentence].joined(separator: " ")
        let bySentence = AIText.summary(three)
        #expect(bySentence == [sentence, sentence].joined(separator: " "))
        #expect((bySentence?.count ?? 0) <= ProjectInfo.summaryLimit)

        // One sentence over it: cut at a word.
        let huge = String(repeating: "palabra ", count: 320) + "fin."
        #expect(huge.count > 2500)
        let byWord = AIText.summary(huge)
        #expect((byWord?.count ?? 0) <= ProjectInfo.summaryLimit)
        #expect((byWord?.count ?? 0) > ProjectInfo.summaryLimit - 10)
        #expect(byWord?.hasSuffix("palabra") == true)

        for empty in ["", "   ", "\n", "\"\""] {
            #expect(AIText.summary(empty) == nil, "\(empty)")
        }
    }
}
