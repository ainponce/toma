// SPDX-License-Identifier: GPL-3.0-or-later
import Testing
// Not @testable: the app uses only the public API.
import Analysis
import Editing
import ProjectFormat

private typealias F = VoiceFixture

@Test func wordGapsOfThreeSecondsOrMore() {
    // 4 s before the first word, a 3.2 s gap and a 2.9 s one, and the last word ending 3 s before the end... 2 s here.
    let doc = F.document(words: [(4, 5), (5.5, 6), (9.2, 9.8), (12.7, 13), (13, 18)])
    let silences = VoiceSilences.fromWords(doc, timeMap: F.timeMap(doc))
    #expect(silences == [F.range(0, 4), F.range(6, 9.2)])
}

@Test func theTailAfterTheLastWordCounts() {
    let doc = F.document(words: [(0, 1), (1.2, 2)])
    #expect(VoiceSilences.fromWords(doc, timeMap: F.timeMap(doc)) == [F.range(2, 20)])
    #expect(VoiceSilences.fromWords(F.document(), timeMap: F.timeMap(F.document())).isEmpty)
}

@Test func cutWordsDoNotBreakTheSilence() {
    // The word at 8 to 9 is cut with the clip over it: the output closes it, and the gap around it is one.
    let clips = [
        Clip(id: "c-00000001", take: F.takeID, start: F.at(0), end: F.at(8), speed: 1),
        Clip(id: "c-00000002", take: F.takeID, start: F.at(9), end: F.at(20), speed: 1),
    ]
    let doc = F.document(words: [(0, 1), (8, 9), (10, 11)], sequence: clips)
    // Output: w0 [0,1), w2 [9,10) after the cut closed; the gap between them is 8 s.
    #expect(VoiceSilences.fromWords(doc, timeMap: F.timeMap(doc)) == [F.range(1, 9), F.range(10, 19)])
}

@Test func quietSpansMapToOutputWithCutsClosed() {
    // A 5 s silence in the source [3, 8) with a cut of [5, 6) inside it: 4 s in the output, one range.
    let clips = [
        Clip(id: "c-00000001", take: F.takeID, start: F.at(0), end: F.at(5), speed: 1),
        Clip(id: "c-00000002", take: F.takeID, start: F.at(6), end: F.at(20), speed: 1),
    ]
    let map = TimeMap(sequence: clips)
    let silences = VoiceSilences.fromQuiet([F.at(3)..<F.at(8), F.at(12)..<F.at(13)], take: F.takeID, timeMap: map)
    #expect(silences == [F.range(3, 7)])
    // Two that touch once the cut is closed are one.
    let joined = VoiceSilences.fromQuiet([F.at(3)..<F.at(5), F.at(6)..<F.at(8)], take: F.takeID, timeMap: map)
    #expect(joined == [F.range(3, 7)])
    #expect(VoiceSilences.fromQuiet([], take: F.takeID, timeMap: map).isEmpty)
}

@Test func silencesBecomeShrunkScreenOnlyBlocks() throws {
    let doc = F.document()
    let step = try #require(VoiceSilences.hideCamera(doc, silences: [F.range(5, 9)], timeMap: F.timeMap(doc), makeID: F.IDs().make))
    #expect(step.label == .cameraHideSilences)
    let edited = try F.applying(step, to: doc)
    let block = try #require(edited.camera.layouts.first)
    #expect(edited.camera.layouts.count == 1)
    #expect(block.id == "l-00000010")
    #expect(block.kind == .screenOnly)
    #expect(!block.instant)
    #expect(block.start == F.at(5.5))
    #expect(block.end == F.at(8.5))
    // Shorter than 3 s is not a silence.
    #expect(VoiceSilences.hideCamera(doc, silences: [F.range(5, 7.9)], timeMap: F.timeMap(doc), makeID: F.IDs().make) == nil)
}

@Test func existingBlocksAreNotOverlapped() throws {
    let existing = F.block("l-0000000a", from: 6, to: 7)
    let doc = F.document(blocks: [existing])
    let step = try #require(VoiceSilences.hideCamera(doc, silences: [F.range(5, 9)], timeMap: F.timeMap(doc), makeID: F.IDs().make))
    let edited = try F.applying(step, to: doc)
    #expect(edited.camera.layouts.map(\.id) == ["l-00000010", "l-0000000a", "l-00000011"])
    #expect(edited.camera.layouts[0].start == F.at(5.5) && edited.camera.layouts[0].end == F.at(6))
    #expect(edited.camera.layouts[2].start == F.at(7) && edited.camera.layouts[2].end == F.at(8.5))
    // The piece of 0.3 s before a block at 5.8 s does not enter.
    let near = F.document(blocks: [F.block("l-0000000a", from: 5.8, to: 7)])
    let short = try #require(VoiceSilences.hideCamera(near, silences: [F.range(5, 9)], timeMap: F.timeMap(near), makeID: F.IDs().make))
    let result = try F.applying(short, to: near)
    #expect(result.camera.layouts.map(\.id) == ["l-0000000a", "l-00000010"])
}

@Test func nothingToHideIsNil() {
    let doc = F.document()
    #expect(VoiceSilences.hideCamera(doc, silences: [], timeMap: F.timeMap(doc), makeID: F.IDs().make) == nil)
    let full = F.document(blocks: [F.block("l-0000000a", from: 0, to: 20)])
    #expect(VoiceSilences.hideCamera(full, silences: [F.range(5, 9)], timeMap: F.timeMap(full), makeID: F.IDs().make) == nil)
}

@Test func allSilencesAreOneStep() throws {
    let doc = F.document()
    let silences = [F.range(1, 4.5), F.range(8, 12), F.range(15, 19)]
    let step = try #require(VoiceSilences.hideCamera(doc, silences: silences, timeMap: F.timeMap(doc), makeID: F.IDs().make))
    #expect(step.changes.count == 3)
    #expect(step.target == "l-00000010,l-00000011,l-00000012")
    let edited = try F.applying(step, to: doc)
    #expect(edited.camera.layouts.map(\.id).allSatisfy { $0.hasPrefix("l-") })
    #expect(edited.camera.layouts.map(\.start) == [F.at(1.5), F.at(8.5), F.at(15.5)])
    #expect(edited.camera.layouts.map(\.kind) == [.screenOnly, .screenOnly, .screenOnly])
}

@Test func quietOfEveryTakeJoinsAcrossTakes() {
    // take-001 [0, 10) then take-002 (60 s later in the host) [0, 10): output [0, 10) and [10, 20).
    let second = "take-002"
    func later(_ seconds: Double) -> HostTime { F.at(60 + seconds) }
    let clips = [
        Clip(id: "c-00000001", take: F.takeID, start: F.at(0), end: F.at(10), speed: 1),
        Clip(id: "c-00000002", take: second, start: later(0), end: later(10), speed: 1),
    ]
    let map = TimeMap(sequence: clips)
    // 2 s of quiet at the end of the first take and 2 s at the start of the second: one silence of 4 s at the joint;
    // 1 s in the middle of the second is not one.
    let quiet: [String: [Range<HostTime>]] = [
        F.takeID: [F.at(8)..<F.at(10)],
        second: [later(0)..<later(2), later(5)..<later(6)],
    ]
    #expect(VoiceSilences.fromQuiet(ofTakes: quiet, timeMap: map) == [F.range(8, 12)])
    // Each take alone finds none of 3 s.
    #expect(VoiceSilences.fromQuiet(quiet[F.takeID]!, take: F.takeID, timeMap: map).isEmpty)
    #expect(VoiceSilences.fromQuiet(quiet[second]!, take: second, timeMap: map).isEmpty)
    // One take is the phase 2's.
    let one = [F.at(3)..<F.at(8)]
    #expect(VoiceSilences.fromQuiet(ofTakes: [F.takeID: one], timeMap: map) == VoiceSilences.fromQuiet(one, take: F.takeID, timeMap: map))
    #expect(VoiceSilences.fromQuiet(ofTakes: [:], timeMap: map).isEmpty)
}
