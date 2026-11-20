// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import Testing
// Not @testable: the app uses only the public API.
import Analysis
import Editing
import ProjectFormat

/// The fixture of the commands by source ranges and of the transcript's commands, namespaced so that no other file of
/// EditingTests meets its names: a take of 30 s from `origin`, by default as two clips, `c-00000001` over [0 s, 10 s) at
/// 1× and `c-00000002` over [10 s, 30 s) at 2×, at 60 fps.
enum BySource {
    static let takeID = "take-001"
    static let otherTakeID = "take-002"
    static let origin = HostTime(nanoseconds: 5_000_000_000_000)

    /// The source instant `seconds` after the start of the take.
    static func at(_ seconds: Double) -> HostTime {
        HostTime(nanoseconds: origin.nanoseconds + UInt64((seconds * 1e9).rounded()))
    }

    /// The take's editable timeline, [0 s, 30 s].
    static let bounds = at(0)...at(30)

    static func clip(_ number: Int, _ from: Double, _ to: Double, speed: Double = 1, take: String = takeID) -> Clip {
        clip("c-0000000\(number)", from, to, speed: speed, take: take)
    }

    /// A clip with the id `id`, as a command makes a new one.
    static func clip(_ id: String, _ from: Double, _ to: Double, speed: Double = 1, take: String = takeID) -> Clip {
        Clip(id: id, take: take, start: at(from), end: at(to), speed: speed)
    }

    static let twoSpeeds = [clip(1, 0, 10), clip(2, 10, 30, speed: 2)]

    static func document(
        _ sequence: [Clip] = twoSpeeds, frameRate: Int = 60, words: [TranscriptWord]? = nil, language: String = "es-MX"
    ) -> EditDocument {
        let toma = DefaultStyle.toma
        return EditDocument(
            documentVersion: EditDocument.currentVersion, logSequence: 0, aspect: .landscape, frameRate: frameRate,
            sequence: sequence, screens: ScreenPlan(initial: [takeID: "display-1"], changes: []), style: toma.style,
            cursor: toma.cursor,
            zoom: ZoomPlan(show: true, auto: toma.zoomAuto, spring: toma.zoomSpring, motionBlur: 0.5, regions: [], suppressed: []),
            camera: CameraPlan(
                show: false, initial: [takeID: .default], changes: [], layout: .bubble, layouts: [],
                spring: CameraLayoutRules.spring),
            audio: AudioPlan(limiter: true, tracks: [:]),
            transcript: words.map {
                Transcript(
                    language: language, engine: "speechTranscriber-1",
                    takes: [TranscriptTake(take: takeID, track: "microphone-1", words: $0)])
            },
            captions: CaptionPlan(show: words != nil, style: .default))
    }

    static func word(_ text: String, _ from: Double, _ to: Double, breakBefore: Bool = false) -> TranscriptWord {
        TranscriptWord(start: at(from), end: at(to), text: text, breakBefore: breakBefore)
    }

    /// `w0`…`w9`, each `w_i` over [i s, i + 0.5 s), or the texts given, in their places.
    static func tenWords(_ texts: [String] = (0..<10).map { "w\($0)" }) -> [TranscriptWord] {
        texts.enumerated().map { word($1, Double($0), Double($0) + 0.5) }
    }

    /// A transcript of `tenWords` over one clip of the whole take at 1×.
    static func transcribed(_ texts: [String] = (0..<10).map { "w\($0)" }, language: String = "es-MX") -> EditDocument {
        document([clip(1, 0, 30)], words: tenWords(texts), language: language)
    }

    static func duration(_ document: EditDocument) -> Int64 { TimeMap(sequence: document.sequence).duration }

    /// `document` with `step` applied, checking on the way that its inverse gives `document` back.
    static func applying(_ step: EditStep, to document: EditDocument) throws -> EditDocument {
        let edited = try document.applying(step.changes)
        #expect(try edited.applying(step.changes.reversed().map(\.inverse)) == document)
        return edited
    }

    /// A stretch of a take that the output plays at one speed, whatever clips it is made of.
    struct Span: Equatable {
        var take: String
        var start: HostTime
        var end: HostTime
        var speed: Double
    }

    /// The clips of `document`, with the ones that go on from each other at the same speed joined: what it plays.
    static func spans(_ document: EditDocument) -> [Span] {
        var spans: [Span] = []
        for clip in document.sequence {
            if let last = spans.last, last.take == clip.take, last.end == clip.start, last.speed == clip.speed {
                spans[spans.count - 1].end = clip.end
            } else {
                spans.append(Span(take: clip.take, start: clip.start, end: clip.end, speed: clip.speed))
            }
        }
        return spans
    }

    /// The indices of the words of the first take of the transcript that are cut.
    static func cutWords(_ document: EditDocument) -> [Int] {
        guard let take = document.transcript?.takes.first else { return [] }
        return take.words.indices.filter { TranscriptTiming.isCut(take.words[$0], take: take.take, in: document.sequence) }
    }

    /// A `makeID` that counts `c-00000010`, `c-00000011`… as it is asked.
    final class CountingIDs {
        private var next = 0x10
        private(set) var made: [String] = []

        func make(_ prefix: String) -> String {
            let hex = String(next, radix: 16)
            next += 1
            let id = prefix + String(repeating: "0", count: 8 - hex.count) + hex
            made.append(id)
            return id
        }
    }

    /// A new `CountingIDs`' `make`.
    static var newIDs: (String) -> String { CountingIDs().make }
}

// MARK: - Deleting by source

@Test func deleteSourceCutsAcrossClipsAndSpeeds() throws {
    let document = BySource.document()
    // Two ranges given out of order and overlapping are their union, [9 s, 11 s).
    let ranges = [BySource.at(9.5)..<BySource.at(11), BySource.at(9)..<BySource.at(10)]
    let step = try SequenceCommands.deleteSource(
        document, take: BySource.takeID, ranges: ranges, label: .transcriptCut, takeBounds: [:], makeID: BySource.newIDs
    ).get()
    #expect(step.label == .transcriptCut)
    #expect(step.target == "c-00000001,c-00000002")
    let edited = try BySource.applying(step, to: document)
    #expect(edited.sequence == [BySource.clip(1, 0, 9), BySource.clip(2, 11, 30, speed: 2)])
    #expect(BySource.duration(edited) == 9_000_000_000 + 9_500_000_000)
    // Inside a clip, it is cut in two: the second piece is a new clip at the same speed.
    let ids = BySource.CountingIDs()
    let inside = try SequenceCommands.deleteSource(
        document, take: BySource.takeID, ranges: [BySource.at(15)..<BySource.at(16)], label: .transcriptCut, takeBounds: [:], makeID: ids.make
    ).get()
    #expect(inside.target == "c-00000002")
    #expect(
        try BySource.applying(inside, to: document).sequence == [
            BySource.clip(1, 0, 10), BySource.clip(2, 10, 15, speed: 2), BySource.clip("c-00000010", 16, 30, speed: 2),
        ])
    #expect(ids.made == ["c-00000010"])
}

@Test func sliversGoWithTheCut() throws {
    // At 30 fps a frame is 33.3 ms.
    let document = BySource.document(frameRate: 30)
    func cut(_ ranges: [Range<HostTime>]) throws -> [Clip] {
        let step = try SequenceCommands.deleteSource(
            document, take: BySource.takeID, ranges: ranges, label: .transcriptCut, takeBounds: [:], makeID: BySource.newIDs
        ).get()
        return try BySource.applying(step, to: document).sequence
    }
    // 34 ms at 1× is a frame: it stays. 20 ms is not: it goes with the cut.
    #expect(try cut([BySource.at(0.034)..<BySource.at(10)]) == [BySource.clip(1, 0, 0.034), BySource.twoSpeeds[1]])
    #expect(try cut([BySource.at(0.02)..<BySource.at(10)]) == [BySource.twoSpeeds[1]])
    // 50 ms at 2× lasts 25 ms: it goes too.
    #expect(try cut([BySource.at(10.05)..<BySource.at(12)]) == [BySource.twoSpeeds[0], BySource.clip(2, 12, 30, speed: 2)])
    // So does a piece of less than a frame between two ranges, and no id is made for it.
    let ids = BySource.CountingIDs()
    let between = try SequenceCommands.deleteSource(
        document, take: BySource.takeID, ranges: [BySource.at(2)..<BySource.at(3), BySource.at(3.02)..<BySource.at(4)],
        label: .transcriptCut, takeBounds: [:], makeID: ids.make
    ).get()
    #expect(
        try BySource.applying(between, to: document).sequence == [
            BySource.clip(1, 0, 2), BySource.clip("c-00000010", 4, 10), BySource.twoSpeeds[1],
        ])
    #expect(ids.made == ["c-00000010"])
}

@Test func deleteSourceOnlyTouchesThatTake() throws {
    let other = BySource.clip(3, 0, 5, take: BySource.otherTakeID)
    let document = BySource.document([BySource.clip(1, 0, 10), other, BySource.clip(2, 10, 30, speed: 2)])
    let step = try SequenceCommands.deleteSource(
        document, take: BySource.takeID, ranges: [BySource.at(5)..<BySource.at(15)], label: .transcriptCut,
        takeBounds: [:], makeID: BySource.newIDs
    ).get()
    #expect(step.target == "c-00000001,c-00000002")
    #expect(
        try BySource.applying(step, to: document).sequence == [
            BySource.clip(1, 0, 5), other, BySource.clip(2, 15, 30, speed: 2),
        ])
    // A range of the other take over source it does not show: a step without changes.
    let nothing = try SequenceCommands.deleteSource(
        document, take: BySource.otherTakeID, ranges: [BySource.at(20)..<BySource.at(25)], label: .transcriptCut,
        takeBounds: [:], makeID: BySource.newIDs
    ).get()
    #expect(nothing == EditStep(label: .transcriptCut, target: "", changes: []))
    let empty = try SequenceCommands.deleteSource(
        document, take: BySource.takeID, ranges: [], label: .transcriptPauses, takeBounds: [:], makeID: BySource.newIDs
    ).get()
    #expect(empty.changes.isEmpty)
}

/// A clip taken out can leave one of another take before a cut of the sound: the L cut that heard `c-00000001` 1 s past
/// its end now hears `take-002`, which ends where its clip does, so it is held to 0, as the mix holds it; held to the
/// clips alone (no bounds of the takes) it stays.
@Test func deleteSourceHoldsTheCutsOfTheSoundToWhatTheTakesHave() throws {
    let other = BySource.clip(3, 0, 5, take: BySource.otherTakeID)
    var late = BySource.clip(2, 10, 30, speed: 2)
    late.audioShift = 1_000_000_000
    let document = BySource.document([other, BySource.clip(1, 0, 10), late])
    let bounds = [BySource.takeID: BySource.bounds, BySource.otherTakeID: BySource.at(0)...BySource.at(5)]
    #expect(SequenceRules.audioShift(of: document.sequence, at: 2, takeBounds: bounds) == 1_000_000_000)
    func cut(_ takeBounds: [String: ClosedRange<HostTime>]) throws -> EditDocument {
        let step = try SequenceCommands.deleteSource(
            document, take: BySource.takeID, ranges: [BySource.at(0)..<BySource.at(10)], label: .transcriptCut,
            takeBounds: takeBounds, makeID: BySource.newIDs
        ).get()
        return try BySource.applying(step, to: document)
    }
    let held = try cut(bounds)
    #expect(held.sequence.map(\.id) == ["c-00000003", "c-00000002"])
    #expect(held.sequence.map(\.audioShift) == [0, 0])
    #expect(held.sequence[1].audioShift == SequenceRules.audioShift(of: held.sequence, at: 1, takeBounds: bounds))
    #expect(try cut([:]).sequence.map(\.audioShift) == [0, 1_000_000_000])
}

@Test func deleteEverythingIsLastClip() {
    let document = BySource.document()
    for range in [BySource.at(0)..<BySource.at(30), HostTime(nanoseconds: 0)..<HostTime(nanoseconds: .max)] {
        #expect(
            SequenceCommands.deleteSource(
                document, take: BySource.takeID, ranges: [range], label: .transcriptCut, takeBounds: [:], makeID: BySource.newIDs)
                == .failure(.lastClip))
    }
    // Less than a frame left is nothing left either.
    #expect(
        SequenceCommands.deleteSource(
            document, take: BySource.takeID, ranges: [BySource.at(0.01)..<BySource.at(30)], label: .transcriptCut,
            takeBounds: [:], makeID: BySource.newIDs) == .failure(.lastClip))
}

// MARK: - Restoring by source

@Test func restoreIsTheInverseOfCut() throws {
    let document = BySource.document()
    let range = BySource.at(12)..<BySource.at(14)
    let cut = try SequenceCommands.deleteSource(
        document, take: BySource.takeID, ranges: [range], label: .transcriptCut, takeBounds: [:], makeID: BySource.newIDs
    ).get()
    let edited = try BySource.applying(cut, to: document)
    let step = try #require(
        SequenceCommands.restore(edited, take: BySource.takeID, range: range, bounds: BySource.bounds, makeID: BySource.newIDs))
    #expect(step.label == .transcriptRestore)
    let restored = try BySource.applying(step, to: edited)
    #expect(BySource.spans(restored) == BySource.spans(document))
    #expect(BySource.duration(restored) == BySource.duration(document))
    // Never joined: the clip the cut made is still there.
    #expect(restored.sequence.count == 3)
}

@Test func restoreTakesThePreviousSpeed() throws {
    let document = BySource.document([BySource.clip(1, 0, 5), BySource.clip(2, 7, 30, speed: 2)])
    let step = try #require(
        SequenceCommands.restore(
            document, take: BySource.takeID, range: BySource.at(5)..<BySource.at(7), bounds: BySource.bounds,
            makeID: BySource.newIDs))
    #expect(step.target == "c-00000001")
    #expect(try BySource.applying(step, to: document).sequence == [BySource.clip(1, 0, 7), BySource.clip(2, 7, 30, speed: 2)])
    // A piece that touches neither is a new clip in its place, at the previous one's speed; so is one that touches only
    // the next clip, at another speed.
    for (from, to) in [(5.5, 6.5), (6.0, 7.0)] {
        let ids = BySource.CountingIDs()
        let piece = try #require(
            SequenceCommands.restore(
                document, take: BySource.takeID, range: BySource.at(from)..<BySource.at(to), bounds: BySource.bounds,
                makeID: ids.make))
        #expect(piece.target == "c-00000010")
        #expect(
            try BySource.applying(piece, to: document).sequence == [
                BySource.clip(1, 0, 5), BySource.clip("c-00000010", from, to), BySource.clip(2, 7, 30, speed: 2),
            ])
    }
}

@Test func restoreBridgesTwoClips() throws {
    let document = BySource.document([BySource.clip(1, 0, 5), BySource.clip(2, 7, 30)])
    // The exact gap, or more than it: what is kept already stays as it is.
    for (from, to) in [(5.0, 7.0), (4.0, 8.0)] {
        let step = try #require(
            SequenceCommands.restore(
                document, take: BySource.takeID, range: BySource.at(from)..<BySource.at(to), bounds: BySource.bounds,
                makeID: BySource.newIDs))
        #expect(try BySource.applying(step, to: document).sequence == [BySource.clip(1, 0, 7), BySource.clip(2, 7, 30)])
    }
    // Two gaps in one step: each piece lengthens the clip before it.
    let three = BySource.document([BySource.clip(1, 0, 5), BySource.clip(2, 7, 10), BySource.clip(3, 12, 30)])
    let both = try #require(
        SequenceCommands.restore(
            three, take: BySource.takeID, range: BySource.at(5)..<BySource.at(12), bounds: BySource.bounds,
            makeID: BySource.newIDs))
    #expect(both.target == "c-00000001,c-00000002")
    #expect(
        try BySource.applying(both, to: three).sequence == [
            BySource.clip(1, 0, 7), BySource.clip(2, 7, 12), BySource.clip(3, 12, 30),
        ])
    // Before the first clip and after it: that clip is lengthened both ways, in one replacement.
    let first = BySource.document([BySource.clip(1, 3, 10), BySource.clip(2, 12, 30)])
    let around = try #require(
        SequenceCommands.restore(
            first, take: BySource.takeID, range: BySource.at(1)..<BySource.at(12), bounds: BySource.bounds,
            makeID: BySource.newIDs))
    #expect(around.target == "c-00000001")
    #expect(around.changes.count == 1)
    #expect(try BySource.applying(around, to: first).sequence == [BySource.clip(1, 1, 12), BySource.clip(2, 12, 30)])
}

@Test func restoreBeforeTheFirstClipTakesTheNextSpeed() throws {
    let document = BySource.document([BySource.clip(1, 3, 30, speed: 2)])
    let step = try #require(
        SequenceCommands.restore(
            document, take: BySource.takeID, range: BySource.at(1)..<BySource.at(3), bounds: BySource.bounds,
            makeID: BySource.newIDs))
    #expect(try BySource.applying(step, to: document).sequence == [BySource.clip(1, 1, 30, speed: 2)])
    // One that does not reach it goes before it, at its speed.
    let ids = BySource.CountingIDs()
    let before = try #require(
        SequenceCommands.restore(
            document, take: BySource.takeID, range: BySource.at(0.5)..<BySource.at(2), bounds: BySource.bounds,
            makeID: ids.make))
    #expect(
        try BySource.applying(before, to: document).sequence == [
            BySource.clip("c-00000010", 0.5, 2, speed: 2), BySource.clip(1, 3, 30, speed: 2),
        ])
}

@Test func restoreInsideAClipIsNil() {
    let document = BySource.document()
    for range in [BySource.at(2)..<BySource.at(8), BySource.at(5)..<BySource.at(15), BySource.at(4)..<BySource.at(4)] {
        #expect(
            SequenceCommands.restore(
                document, take: BySource.takeID, range: range, bounds: BySource.bounds, makeID: BySource.newIDs) == nil)
    }
    // Out of the take's bounds, nothing either.
    #expect(
        SequenceCommands.restore(
            document, take: BySource.takeID, range: BySource.at(30)..<BySource.at(40), bounds: BySource.bounds,
            makeID: BySource.newIDs) == nil)
}

@Test func restoreIsClampedToTheEditableBounds() throws {
    let document = BySource.document([BySource.clip(1, 2, 28)])
    let bounds = BySource.at(0.5)...BySource.at(30)
    let step = try #require(
        SequenceCommands.restore(
            document, take: BySource.takeID, range: HostTime(nanoseconds: 0)..<BySource.at(2), bounds: bounds,
            makeID: BySource.newIDs))
    #expect(try BySource.applying(step, to: document).sequence == [BySource.clip(1, 0.5, 28)])
    let after = try #require(
        SequenceCommands.restore(
            document, take: BySource.takeID, range: BySource.at(27)..<HostTime(nanoseconds: .max), bounds: bounds,
            makeID: BySource.newIDs))
    #expect(try BySource.applying(after, to: document).sequence == [BySource.clip(1, 2, 30)])
}

@Test func restoreGoesInItsSourcePlaceAmongOtherTakes() throws {
    let other = BySource.clip(3, 0, 5, take: BySource.otherTakeID)
    let document = BySource.document([BySource.clip(1, 0, 5), other, BySource.clip(2, 10, 30, speed: 2)])
    let ids = BySource.CountingIDs()
    let step = try #require(
        SequenceCommands.restore(
            document, take: BySource.takeID, range: BySource.at(6)..<BySource.at(8), bounds: BySource.bounds,
            makeID: ids.make))
    #expect(
        try BySource.applying(step, to: document).sequence == [
            BySource.clip(1, 0, 5), BySource.clip("c-00000010", 6, 8), other, BySource.clip(2, 10, 30, speed: 2),
        ])
    // A piece shorter than a frame is not made.
    #expect(
        SequenceCommands.restore(
            document, take: BySource.takeID, range: BySource.at(6)..<BySource.at(6.01), bounds: BySource.bounds,
            makeID: BySource.newIDs) == nil)
}
