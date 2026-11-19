// SPDX-License-Identifier: GPL-3.0-or-later
import Analysis
import Foundation
import ProjectFormat
// @testable for `CameraSyncScene` and `FrameEvaluator.frame(at:)`.
@testable import Render
import Testing

// The camera's sync against the sound (plan 2a task A9, phase 2 design §5.9): the camera's frame taken at
// `t − syncOffset` in source time, held to what was recorded; the screen and the cursor never move.
// Over a take whose screen runs 10 s and whose camera runs from 1 s to 9 s, so output seconds are source seconds.

private let screen = Rect(x: 0, y: 0, width: 640, height: 360)
private let size = SIMD2(640, 360)
private let ms: Int64 = 1_000_000

private func cameraTake() -> TakeRecord {
    makeTake(tracks: [
        displayTrack(globalFrame: screen, segments: [segment(start: base, end: base.adding(seconds: 10))]),
        displayTrack(
            id: cameraID, kind: .camera, globalFrame: nil,
            segments: [segment(track: cameraID, index: 1, start: base.adding(seconds: 1), end: base.adding(seconds: 9))]),
    ])
}

private func document(_ take: TakeRecord = cameraTake(), offset: Int64, _ change: (inout EditDocument) -> Void = { _ in })
    -> EditDocument
{
    var document = EditDocument.legacy(take: take, events: [])
    document.camera.syncOffset = offset
    change(&document)
    return document
}

private func instant(_ seconds: Double, plus nanoseconds: Int64 = 0) -> HostTime {
    HostTime(nanoseconds: UInt64(Int64(base.adding(seconds: seconds).nanoseconds) + nanoseconds))
}

@Test func zeroIsTheSameInstant() {
    let take = cameraTake()
    let sync = CameraSyncScene(document: document(take, offset: 0), take: take)
    // Also outside what the camera recorded.
    for t in [instant(0), instant(0.5), instant(5), instant(9.5), HostTime(nanoseconds: 0), HostTime(nanoseconds: .max)] {
        #expect(sync.cameraTime(atSource: t) == t)
    }
}

@Test func positiveShowsTheEarlierFrame() {
    let take = cameraTake()
    let later = CameraSyncScene(document: document(take, offset: 40 * ms), take: take)
    #expect(later.cameraTime(atSource: instant(5)) == instant(5, plus: -40 * ms))
    let earlier = CameraSyncScene(document: document(take, offset: -40 * ms), take: take)
    #expect(earlier.cameraTime(atSource: instant(5)) == instant(5, plus: 40 * ms))
}

@Test func cameraTimeIsClampedToWhatWasRecorded() {
    let take = cameraTake()
    let later = CameraSyncScene(document: document(take, offset: 40 * ms), take: take)
    #expect(later.cameraTime(atSource: instant(1.01)) == instant(1))
    #expect(later.cameraTime(atSource: instant(0)) == instant(1))
    #expect(later.cameraTime(atSource: HostTime(nanoseconds: 0)) == instant(1))
    let earlier = CameraSyncScene(document: document(take, offset: -40 * ms), take: take)
    #expect(earlier.cameraTime(atSource: instant(8.99)) == instant(9))
    #expect(earlier.cameraTime(atSource: instant(20)) == instant(9))
    // Without a camera there is nothing to hold it to.
    let bare = StageDrawing.bareTake()
    let none = CameraSyncScene(document: document(bare, offset: 40 * ms), take: bare)
    #expect(none.cameraTime(atSource: instant(1)) == instant(1))
}

@Test func offsetsOutOfRangeAreClamped() {
    let take = cameraTake()
    let big = CameraSyncScene(document: document(take, offset: 900 * ms), take: take)
    #expect(big.cameraTime(atSource: instant(5)) == instant(5, plus: -300 * ms))
    let small = CameraSyncScene(document: document(take, offset: -900 * ms), take: take)
    #expect(small.cameraTime(atSource: instant(5)) == instant(5, plus: 300 * ms))
}

@Test func everyPathReadsTheShiftedCamera() {
    let take = cameraTake()
    let block = { (kind: LayoutKind) -> LayoutBlock in
        LayoutBlock(
            id: "l-00000001", take: takeID, start: base.adding(seconds: 0), end: base.adding(seconds: 10), kind: kind,
            instant: false, bubble: nil, split: kind == .split ? SplitLayout() : nil)
    }
    let documents: [(String, EditDocument)] = [
        ("legacy bubble", document(take, offset: 100 * ms)),
        ("camera full", document(take, offset: 100 * ms) { $0.camera.layouts = [block(.cameraFull)] }),
        ("split", document(take, offset: 100 * ms) { $0.camera.layouts = [block(.split)] }),
    ]
    for (name, doc) in documents {
        let evaluator = FrameEvaluator(take: take, events: [], document: doc, outputSize: size)
        for t in [2.0, 5.0, 8.0] {
            let frame = evaluator.frame(at: t)
            #expect(frame.camera?.sourceTime == instant(t, plus: -100 * ms), "\(name) at \(t) s")
            // The screen at its own instant.
            if let shown = frame.screen { #expect(shown.sourceTime == instant(t), "\(name) at \(t) s") }
        }
    }
}

@Test func theMaskFollowsTheShiftedTime() throws {
    let take = cameraTake()
    let file = URL(fileURLWithPath: "/caches/masks/\(takeID)/\(cameraID)/seg-0001-100-7-personMask-1.mov")
    var analysis = AnalysisInputs()
    analysis.personMasks[CameraSegment(take: takeID, track: cameraID, segment: 1)] = file
    let doc = document(take, offset: 100 * ms) { $0.camera.background = .blurred }
    let evaluator = FrameEvaluator(take: take, events: [], document: doc, outputSize: size, analysis: analysis)
    let camera = try #require(evaluator.frame(at: 5).camera)
    #expect(camera.sourceTime == instant(5, plus: -100 * ms))
    let mask = try #require(camera.background?.mask)
    #expect(mask.time == camera.sourceTime)
}
