// SPDX-License-Identifier: GPL-3.0-or-later
import Analysis
import Foundation
import ProjectFormat
import Testing

// The stage of every take is the output's (phase 3 design §9): in "Like the Recording", the ratio of the take of the
// first clip (`StageLayout.contentRatioTake(of:ownTake:)`), given to the stage of any other take, whose screens are
// fitted inside it; the editor works that ratio out from the takes' screens read once, as the export does from the
// events.

private enum Stages {
    static let base = HostTime(nanoseconds: 5_000_000_000_000)

    /// A take of one display, `width` × 900 pt, recorded for 60 s from `start` seconds after `base`.
    static func take(_ id: String, width: Double, start: Double) -> TakeRecord {
        let from = base.adding(seconds: start)
        return TakeRecord(
            id: id, status: .complete, startedAt: Date(timeIntervalSince1970: 1_800_000_000 + start),
            tracks: [TrackRecord(
                id: "display-1", kind: .display,
                source: TrackSource(
                    name: "Display", displayID: 1, globalFrame: Rect(x: 0, y: 0, width: width, height: 900), pixelScale: 2),
                segments: [SegmentRecord(
                    index: 1, file: "takes/\(id)/display-1/seg-0001.mov", startHostTime: from, endHostTime: from.adding(seconds: 60),
                    endReason: .stopped, droppedFrames: 0, heartbeatFrames: 0)])])
    }

    /// 16:9 and 4:3.
    static let wide = take("take-001", width: 1600, start: 0)
    static let narrow = take("take-002", width: 1200, start: 100)

    /// "Like the Recording" over `[first 0–10, second 0–10]`, each on its display.
    static func document(_ first: TakeRecord, _ second: TakeRecord) -> EditDocument {
        var document = EditDocument.legacy(take: first, events: [])
        document.aspect = .auto
        func clip(_ id: String, _ take: TakeRecord) -> Clip {
            let start = take.tracks[0].segments[0].startHostTime
            return Clip(id: id, take: take.id, start: start, end: start.adding(seconds: 10), speed: 1)
        }
        document.sequence = [clip("c-00000001", first), clip("c-00000002", second)]
        document.screens.initial = [first.id: "display-1", second.id: "display-1"]
        return document
    }
}

@Test func anotherTakesStageIsTheOutputs() throws {
    let document = Stages.document(Stages.wide, Stages.narrow)
    #expect(StageLayout.contentRatioTake(of: document, ownTake: "take-002") == "take-001")
    let ratio = try #require(StageLayout.contentRatio(take: Stages.wide, document: document, events: []))
    #expect(abs(ratio - 16.0 / 9) < 1e-12)

    // On its own, the 4:3 take would make a 4:3 stage (phase 2's rule, of one take).
    let own = StagePoints(take: Stages.narrow, events: [], document: document)
    #expect(own.stageSize == SIMD2(4.0 / 3, 1))
    // Given the output's ratio, its stage is 16:9 and its screen 4:3 inside it, centred, the whole height inside the
    // padding.
    let stage = StagePoints(take: Stages.narrow, events: [], document: document, contentRatio: .some(ratio))
    #expect(stage.stageSize == SIMD2(16.0 / 9, 1))
    #expect(stage.contentRatio == ratio)
    let rect = try #require(stage.screenRect(at: Stages.base.adding(seconds: 105)))
    let padding = document.style.padding * 16 / 9
    #expect(abs(rect.height - (1 - 2 * padding)) < 1e-12)
    #expect(abs(rect.width / rect.height - 4.0 / 3) < 1e-12)
    #expect(abs(rect.x + rect.width / 2 - 8.0 / 9) < 1e-12)
    // The same from the take's screens read once, and for its paths; the given ratio is part of what they were built of.
    let screens = TakeScreens(take: Stages.narrow, events: [])
    #expect(StagePoints(take: Stages.narrow, document: document, screens: screens, contentRatio: .some(ratio)).screenRect(
        at: Stages.base.adding(seconds: 105)) == rect)
    let paths = MotionPaths(take: Stages.narrow, events: [], document: document, contentRatio: .some(ratio))
    #expect(paths.stage.stageSize == stage.stageSize)
    #expect(paths.areThePaths(of: document))
    #expect(!paths.areThePaths(of: document, contentRatio: nil))
    // After an edit, the ratio they were built with, unless another one is given.
    var edited = document
    edited.style.padding = 0.1
    let after = MotionPaths(take: Stages.narrow, events: [], document: edited, after: paths)
    let fresh = MotionPaths(take: Stages.narrow, events: [], document: edited, contentRatio: .some(ratio))
    #expect(after.stage.stageSize == SIMD2(16.0 / 9, 1))
    #expect(after.stage.screenRect(at: Stages.base.adding(seconds: 105)) == fresh.stage.screenRect(at: Stages.base.adding(seconds: 105)))
    #expect(after.areThePaths(of: edited, contentRatio: .some(ratio)))
    #expect(MotionPaths(take: Stages.narrow, events: [], document: document, after: paths).stage.stageSize == stage.stageSize)
    let ownAgain = MotionPaths(take: Stages.narrow, events: [], document: edited, after: paths, contentRatio: nil)
    #expect(ownAgain.stage.stageSize == own.stageSize)
    #expect(ownAgain.areThePaths(of: edited, contentRatio: nil))
    // A take without a screen first: 16:9, as the output is.
    #expect(StagePoints(take: Stages.narrow, events: [], document: document, contentRatio: .some(nil)).stageSize
        == SIMD2(16.0 / 9, 1))
}

/// The editor's rule (`TakeScreens.contentRatio(of:takes:ownTake:screens:)`) is the export's
/// (`StageLayout.contentRatio(project:document:)`'s): the take of the first clip, whichever take is the project's, and a
/// clip with content first is its point's take; without clips, the project's own; none for a take it has no screens of.
@Test func theEditorsRatioIsTheFirstClipsTake() {
    let takes = [Stages.wide, Stages.narrow]
    let screens = Dictionary(uniqueKeysWithValues: takes.map { ($0.id, TakeScreens(take: $0, events: [])) })
    func ratio(_ document: EditDocument, own: String, _ screens: [String: TakeScreens]) -> Double? {
        TakeScreens.contentRatio(of: document, takes: takes, ownTake: own, screens: screens)
    }
    let wideFirst = Stages.document(Stages.wide, Stages.narrow)
    let narrowFirst = Stages.document(Stages.narrow, Stages.wide)
    for own in ["take-001", "take-002"] {
        #expect(ratio(wideFirst, own: own, screens) == 1600.0 / 900, "\(own)")
        #expect(ratio(narrowFirst, own: own, screens) == 1200.0 / 900, "\(own)")
    }
    // A frozen frame of the 4:3 take first.
    var frozen = wideFirst
    let point = Stages.narrow.tracks[0].segments[0].startHostTime.adding(seconds: 2)
    frozen.sequence.insert(
        Clip(id: "c-00000003", take: "take-002", start: point, end: point, speed: 1, content: .freeze(duration: 1_000_000_000)),
        at: 0)
    #expect(ratio(frozen, own: "take-001", screens) == 1200.0 / 900)
    // Without clips, the project's own.
    var empty = wideFirst
    empty.sequence = []
    #expect(ratio(empty, own: "take-002", screens) == 1200.0 / 900)
    // A take without its screens read: none.
    #expect(ratio(narrowFirst, own: "take-001", ["take-001": screens["take-001"]!]) == nil)
}
