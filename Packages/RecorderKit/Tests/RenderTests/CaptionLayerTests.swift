// SPDX-License-Identifier: GPL-3.0-or-later
import Analysis
import CoreText
import Foundation
import ProjectFormat
// @testable for `CaptionScene` and `CaptionTypography`.
@testable import Render
import Testing

/// The captions' layer as the frames get it (phase 2 design §5.2, plan 2a Task A8, decisions 10 and 11): which caption is
/// shown at each instant, at what size and where, and which word is highlighted. No Metal.

/// A take of `seconds` on display 1, its legacy document with a transcript of `words` (texts at the start, in seconds of
/// the take, each 0.3 s long unless `length` says) in `language`, its captions shown in `style`.
private func captioned(
    _ words: [(String, Double)], length: Double = 0.3, seconds: Double = 12, language: String = "es-MX",
    style: CaptionStyle = .default, show: Bool = true
) -> EditDocument {
    var document = EditDocument.legacy(take: StageDrawing.bareTake(seconds: seconds), events: [])
    document.transcript = Transcript(
        language: language, engine: "speechTranscriber-1",
        takes: [TranscriptTake(
            take: takeID, track: "microphone-1",
            words: words.map { TranscriptWord(start: base.adding(seconds: $1), end: base.adding(seconds: $1 + length), text: $0) })])
    document.captions = CaptionPlan(show: show, style: style)
    return document
}

/// Words of 0.3 s every 0.4 s from `from` seconds.
private func spoken(_ texts: [String], from: Double = 0) -> [(String, Double)] {
    texts.enumerated().map { ($1, from + Double($0) * 0.4) }
}

private func scene(_ document: EditDocument, size: SIMD2<Int> = SIMD2(1920, 1080)) -> CaptionScene {
    CaptionScene(document: document, timeMap: TimeMap(sequence: document.sequence), outputSize: size)
}

private func ns(_ seconds: Double) -> Int64 { TimeMap.outputNanoseconds(seconds: seconds) }

private func style(
    _ preset: CaptionPreset = .bold, size: OverlaySize = .medium, position: CaptionPosition = .bottom, uppercase: Bool = false,
    highlight: Bool = true
) -> CaptionStyle {
    var style = CaptionStyle.default
    (style.preset, style.size, style.position, style.uppercase, style.highlight) = (preset, size, position, uppercase, highlight)
    return style
}

@Suite struct CaptionLayerTests {
    @Test func noTranscriptOrHiddenIsNoLayer() {
        let legacy = EditDocument.legacy(take: StageDrawing.bareTake(seconds: 4), events: [])
        let hidden = captioned(spoken(["hola", "a", "todos"]), show: false)
        for document in [legacy, hidden] {
            let scene = scene(document)
            for t in stride(from: 0.0, through: 4, by: 0.05) {
                #expect(scene.layer(atOutput: ns(t)) == nil, "\(t) s")
            }
        }
        // Shown, the same words are a layer.
        #expect(scene(captioned(spoken(["hola", "a", "todos"]))).layer(atOutput: ns(0.1)) != nil)
    }

    @Test func layerAtEachInstantIsItsCaption() throws {
        // Three captions: a sentence ends after "tarde.", and a gap of 2 s before the last.
        let document = captioned(
            spoken(["Buenas", "tardes", "a", "todos."]) + spoken(["Hoy", "vamos", "a", "ver", "cómo", "editar."], from: 1.6)
                + spoken(["¿Listos?"], from: 6))
        let size = SIMD2(1920, 1080)
        let scene = scene(document, size: size)
        let captions = CaptionLines.captions(of: document, timeMap: TimeMap(sequence: document.sequence), outputSize: size)
        try #require(captions.count == 3)
        for caption in captions {
            let lines = caption.lines.map { $0.map(\.text).joined(separator: " ") }
            let middle = caption.output.lowerBound + (caption.output.upperBound - caption.output.lowerBound) / 2
            for t in [caption.output.lowerBound, middle, caption.output.upperBound - 1] {
                #expect(scene.layer(atOutput: t)?.lines == lines, "\(caption.text) at \(t)")
            }
            #expect(scene.layer(atOutput: caption.output.upperBound)?.lines != lines, "\(caption.text) ends")
        }
        // Between the second and the third, and after the last, none.
        #expect(scene.layer(atOutput: ns(5)) == nil)
        #expect(scene.layer(atOutput: ns(8)) == nil)
        #expect(scene.layer(atOutput: ns(6.1))?.language == "es-MX")
    }

    @Test func fontShrinksToFitTheWidth() throws {
        // 24 wide characters in a vertical output, Large: their nominal width is far wider than 90 % of 1080 px.
        let size = SIMD2(1080, 1920)
        let wide = captioned([("WWWWWWWWWWWWWWWWWWWWWWWW", 0)], style: style(size: .large))
        let layer = try #require(scene(wide, size: size).layer(atOutput: ns(0.1)))
        let nominal = CaptionMetrics.fontSize(.large, outputSize: size)
        #expect(layer.fontSize < nominal)
        let font = try #require(CaptionTypography.font(for: layer))
        let widest = layer.lines.map { CaptionTypography.width(of: $0, font: font, layer: layer) }.max() ?? 0
        #expect(widest <= 0.9 * 1080 + 1e-9 && widest > 0.85 * 1080, "\(widest)")
        // The box holds the line and Classic's padding.
        #expect(abs(layer.box.width - (widest + 2 * CaptionMetrics.boxPaddingEm.x * layer.fontSize)) < 1e-6)
        #expect(abs(layer.box.x + layer.box.width / 2 - 540) < 1e-9)
        // Small, ordinary words keep the nominal size.
        let small = captioned(spoken(["hola", "mundo"]), style: style(size: .small))
        let kept = try #require(scene(small, size: size).layer(atOutput: ns(0.1)))
        #expect(kept.fontSize == CaptionMetrics.fontSize(.small, outputSize: size))
        // In capitals, measured as drawn.
        let upper = captioned(spoken(["ñandú", "pingüino"]), style: style(uppercase: true))
        #expect(scene(upper).layer(atOutput: ns(0.5))?.lines == ["ÑANDÚ PINGÜINO"])
    }

    @Test func boxSitsAtEightPercentOfTheEdge() throws {
        for size in [SIMD2(1920, 1080), SIMD2(1080, 1920), SIMD2(1080, 1080)] {
            for preset in CaptionPreset.allCases {
                let words = spoken(["Esto", "es", "una", "prueba", "de", "subtítulos", "con", "dos", "líneas", "y", "algo", "más"])
                let bottom = try #require(scene(captioned(words, style: style(preset, position: .bottom)), size: size)
                    .layer(atOutput: ns(0.5)))
                let top = try #require(scene(captioned(words, style: style(preset, position: .top)), size: size)
                    .layer(atOutput: ns(0.5)))
                let height = Double(size.y)
                #expect(abs(bottom.box.y + bottom.box.height - 0.92 * height) < 1e-9, "\(size) \(preset)")
                #expect(top.box.y == 0.08 * height, "\(size) \(preset)")
                #expect(top.box.width == bottom.box.width && top.box.height == bottom.box.height)
                // The box is the lines at CoreText's height and the padding, centred.
                let font = try #require(CaptionTypography.font(for: bottom))
                let lines = Double(bottom.lines.count)
                let expected = lines * CaptionTypography.lineHeight(of: font) + 2 * CaptionMetrics.boxPaddingEm.y * bottom.fontSize
                #expect(abs(bottom.box.height - expected) < 1e-9)
                #expect(abs(bottom.box.x + bottom.box.width / 2 - Double(size.x) / 2) < 1e-9)
            }
        }
    }

    @Test func highlightHoldsUntilTheNextWord() throws {
        let words = spoken(["Uno", "dos", "tres"])
        let shown = scene(captioned(words))
        // While "Uno" is said and in the gap after it (0.3 to 0.4 s), "Uno"; then "dos" from its start.
        for t in [0.0, 0.2, 0.35, 0.399] {
            #expect(try #require(shown.layer(atOutput: ns(t))).highlight == CaptionHighlight(line: 0, range: 0..<3), "\(t) s")
        }
        #expect(try #require(shown.layer(atOutput: ns(0.4))).highlight == CaptionHighlight(line: 0, range: 4..<7))
        // The last word holds to the end of the caption.
        #expect(try #require(shown.layer(atOutput: ns(1.25))).highlight == CaptionHighlight(line: 0, range: 8..<12))
        // A word on the second line counts from that line's start.
        let long = spoken(["Esto", "es", "una", "prueba", "de", "subtítulos", "con", "dos", "líneas", "y", "algo", "más"])
        let two = try #require(scene(captioned(long)).layer(atOutput: ns(0.4 * 11 + 0.1)))
        try #require(two.lines.count == 2)
        let last = try #require(two.highlight)
        #expect(last.line == 1 && String(Array(two.lines[1])[last.range]) == "más")
        // Without the highlight, none, in every preset.
        for preset in CaptionPreset.allCases {
            let plain = scene(captioned(words, style: style(preset, highlight: false)))
            #expect(try #require(plain.layer(atOutput: ns(0.5))).highlight == nil)
        }
    }

    @Test func fontFollowsTheTranscriptsLanguage() throws {
        // The same Han character falls back to the font of the transcript's language.
        func fallback(_ language: String) throws -> String {
            let layer = try #require(scene(captioned([("直す", 0)], language: language)).layer(atOutput: ns(0.1)))
            #expect(layer.language == language)
            let font = try #require(CaptionTypography.font(for: layer))
            let used = CTFontCreateForString(font, "直" as CFString, CFRange(location: 0, length: 1))
            return CTFontCopyFamilyName(used) as String
        }
        #expect(try fallback("ja-JP").contains("Hiragino"))
        #expect(try fallback("zh-CN").contains("PingFang"))
        // Each preset's weight of the system font.
        let layer = try #require(scene(captioned([("Hola", 0)])).layer(atOutput: ns(0.1)))
        var weights: [Double] = []
        for preset in [CaptionPreset.minimal, .classic, .bold] {
            var drawn = layer
            drawn.style.preset = preset
            let font = try #require(CaptionTypography.font(for: drawn))
            let traits = CTFontCopyTraits(font) as NSDictionary
            weights.append((traits[kCTFontWeightTrait as String] as? NSNumber)?.doubleValue ?? -1)
        }
        #expect(weights.count == 3 && abs(weights[0]) < 0.01 && abs(weights[1] - 0.3) < 0.01 && abs(weights[2] - 0.56) < 0.01, "\(weights)")
    }

    @Test func layersAreHashedByWhatTheyDraw() {
        let layer = CaptionLayer(
            lines: ["Hola"], highlight: CaptionHighlight(line: 0, range: 0..<4), style: .default, language: "es-MX", fontSize: 64.8,
            box: Rect(x: 10, y: 20, width: 300, height: 100))
        var other = layer
        #expect(Set([layer, other]).count == 1)
        other.style.highlightColor = RGBA(1, 0, 0, 1)
        #expect(Set([layer, other]).count == 2 && layer != other)
    }

    @Test func layersAheadAreTheNextOnesDrawn() throws {
        // Two captions: "Buenas tardes a todos." and, after a gap of 1.4 s, "Hoy vamos.". What a frame has ahead
        // (`RenderFrame.captionsAhead`) is the next two layers the frames draw, exactly: the next words highlighted, then
        // the next caption's first; between captions, the next caption's.
        let document = captioned(spoken(["Buenas", "tardes", "a", "todos."]) + spoken(["Hoy", "vamos."], from: 3))
        let evaluator = FrameEvaluator(take: StageDrawing.bareTake(seconds: 12), events: [], document: document, outputSize: SIMD2(1920, 1080))
        func drawn(at t: Double) -> CaptionLayer? { evaluator.frame(at: t).captions }
        for (t, next) in [
            (0.1, [0.4, 0.8]), (0.5, [0.8, 1.2]), (1.0, [1.2, 3.0]), (1.3, [3.0, 3.4]), (2.5, [3.0, 3.4]), (3.1, [3.4]),
        ] {
            let ahead = evaluator.frame(at: t).captionsAhead
            let expected = next.compactMap { drawn(at: $0) }
            #expect(expected.count == next.count && ahead == expected, "at \(t) s")
            #expect(!ahead.contains { $0 == drawn(at: t) }, "at \(t) s: never the layer drawn")
        }
        #expect(evaluator.frame(at: 3.6).captionsAhead.isEmpty, "the last word")
        // Without the highlight, a caption is one layer: the next caption's.
        let plain = FrameEvaluator(
            take: StageDrawing.bareTake(seconds: 12), events: [],
            document: captioned(spoken(["Buenas", "tardes", "a", "todos."]) + spoken(["Hoy", "vamos."], from: 3), style: style(.classic, highlight: false)),
            outputSize: SIMD2(1920, 1080))
        #expect(plain.frame(at: 0.5).captionsAhead == [try #require(plain.frame(at: 3.1).captions)])
        // Without captions, nothing ahead.
        let legacy = FrameEvaluator(
            take: StageDrawing.bareTake(seconds: 12), events: [], document: captioned(spoken(["Hola"]), show: false),
            outputSize: SIMD2(1920, 1080))
        #expect(legacy.frame(at: 0.1).captionsAhead.isEmpty)
    }
}
