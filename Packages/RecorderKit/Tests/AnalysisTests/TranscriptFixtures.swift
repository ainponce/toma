// SPDX-License-Identifier: GPL-3.0-or-later
import ProjectFormat

@testable import Analysis

/// Documents with a take of 30 s and a transcript over it, for the transcript timing and caption tests.
enum TranscriptFixtures {
    static let origin = HostTime(nanoseconds: 5_000_000_000_000)
    static let takeID = "take-001"

    static func source(_ seconds: Double) -> HostTime { origin.adding(seconds: seconds) }

    static func clip(_ number: Int, from: Double, to: Double, speed: Double = 1) -> Clip {
        Clip(id: "c-0000000\(number)", take: takeID, start: source(from), end: source(to), speed: speed)
    }

    static func word(_ text: String, at start: Double, length: Double = 0.3, breakBefore: Bool = false) -> TranscriptWord {
        TranscriptWord(start: source(start), end: source(start + length), text: text, breakBefore: breakBefore)
    }

    /// Words of 0.3 s every 0.4 s from `from`.
    static func words(_ texts: [String], from: Double = 0) -> [TranscriptWord] {
        texts.enumerated().map { word($1, at: from + Double($0) * 0.4) }
    }

    static func document(
        sequence: [Clip]? = nil, words: [TranscriptWord], language: String = "es-MX", style: CaptionStyle = .default
    ) -> EditDocument {
        let toma = DefaultStyle.toma
        return EditDocument(
            documentVersion: EditDocument.currentVersion, logSequence: 0, aspect: .landscape, frameRate: 60,
            sequence: sequence ?? [clip(1, from: 0, to: 30)],
            screens: ScreenPlan(initial: [takeID: "display-1"], changes: []), style: toma.style, cursor: toma.cursor,
            zoom: ZoomPlan(show: true, auto: toma.zoomAuto, spring: toma.zoomSpring, motionBlur: 0.5, regions: [], suppressed: []),
            camera: CameraPlan(show: false, initial: [takeID: .default], changes: [], layout: .bubble, layouts: [], spring: CameraLayoutRules.spring),
            audio: AudioPlan(limiter: true, tracks: [:]),
            transcript: Transcript(
                language: language, engine: "speechTranscriber-1",
                takes: [TranscriptTake(take: takeID, track: "microphone-1", words: words)]),
            captions: CaptionPlan(show: true, style: style))
    }

    static func captions(_ document: EditDocument, size: SIMD2<Int> = SIMD2(1920, 1080)) -> [Caption] {
        CaptionLines.captions(of: document, timeMap: TimeMap(sequence: document.sequence), outputSize: size)
    }
}
