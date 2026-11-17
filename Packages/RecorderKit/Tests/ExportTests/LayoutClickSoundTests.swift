// SPDX-License-Identifier: GPL-3.0-or-later
import Analysis
@testable import Export
import Foundation
import ProjectFormat
import RecorderKitTestSupport
import Testing

// A click that cannot be seen does not sound (1c design §5.4): its sound plays only where the screen's opacity at its
// output instant is at least 0.5 (`LayoutTimeline.screenOpacity`), so not under a settled Camera full screen or Camera
// only, and a document without layouts mixes what 1b mixed.

private let clickCameraID = "camera"
private let clickCameraSource = TrackSource(name: "Synthetic Camera", deviceUniqueID: "synthetic-camera")

private func at(_ seconds: Double) -> HostTime { base.adding(seconds: seconds) }

/// A take of 8 s named `name`: the display and a camera, a silent microphone, and a left click at each of `clicks`
/// (seconds).
private func clickTake(in dir: URL, name: String = "Clicks", clicks: [Double]) async throws -> LoadedProject {
    let builder = try TakeBuilder(in: dir, name: name)
    try await builder.addVideoTrack(
        id: displayID, source: displaySource,
        segments: [VideoSegmentSpec(start: base, seconds: 8, framesPerSecond: 10, width: 320, height: 180)])
    try await builder.addVideoTrack(
        id: clickCameraID, kind: .camera, source: clickCameraSource,
        segments: [VideoSegmentSpec(start: base, seconds: 8, framesPerSecond: 10, width: 320, height: 180)])
    try await builder.addAudioTrack(id: micID, source: micSource, segments: [AudioSegmentSpec(start: base, seconds: 8, amplitude: 0)])
    try builder.addEvents(clicks.flatMap { t in
        [InputEvent(t: at(t), kind: .mouseDown(.left, x: 100, y: 100)), InputEvent(t: at(t + 0.01), kind: .mouseUp(.left, x: 100, y: 100))]
    })
    return try builder.write()
}

/// The legacy document of `project` with soft-1 at full gain and `blocks` (kind, source seconds, instant).
private func clickDocument(_ project: LoadedProject, _ blocks: [(LayoutKind, from: Double, to: Double, instant: Bool)]) -> EditDocument {
    var document = EditDocument.legacy(for: project)
    document.cursor.clickSound = "soft-1"
    document.cursor.clickSoundGain = 1
    document.camera.layouts = blocks.enumerated().map { k, block in
        LayoutBlock(
            id: String(format: "l-%08x", k + 1), take: project.take.id, start: at(block.from), end: at(block.to), kind: block.0,
            instant: block.instant, bubble: nil, split: block.0 == .split ? SplitLayout() : nil)
    }
    return document
}

/// The whole mix of `document`, rendered off the cooperative pool.
private func mixed(_ project: LoadedProject, _ document: EditDocument) async throws -> [Float] {
    let mix = try await EditedMix.make(project: project, document: document, framesPerSecond: 60)
    return try await offThePool {
        var samples: [Float] = []
        mix.render(outputFrames: 0..<mix.totalFrames, into: &samples)
        return samples
    }
}

/// soft-1 from each of the output frames `starts`, over `count` frames of silence.
private func clicks(at starts: [Int], count: Int) throws -> [Float] {
    let sound = try #require(ClickSounds.samples("soft-1"))
    var expected = [Float](repeating: 0, count: count)
    for start in starts {
        for (n, x) in sound.enumerated() { expected[start + n] += x }
    }
    return expected
}

private func screenOpacity(_ project: LoadedProject, _ document: EditDocument, at seconds: Double) -> Double {
    LayoutTimeline(document: document, take: project.take, timeMap: TimeMap(sequence: document.sequence), cameraReadable: true)
        .screenOpacity(atOutput: Int64((seconds * 1e9).rounded()))
}

@Test func clicksUnderAFullCameraAreSilent() async throws {
    try await withTemporaryDirectory { dir in
        let project = try await clickTake(in: dir, clicks: [3])
        // Camera full screen from 1 s, settled from 2.5 s, to 6 s: the click at 3 s is under it.
        let document = clickDocument(project, [(.cameraFull, 1, 6, false)])
        #expect(screenOpacity(project, document, at: 3) == 0)
        let samples = try await mixed(project, document)
        #expect(samples.count == 8 * 48_000 && samples.allSatisfy { $0 == 0 }, "every sample of that sound at 0")
        // Camera only hides the screen too.
        #expect(try await mixed(project, clickDocument(project, [(.cameraOnly, 1, 6, false)])).allSatisfy { $0 == 0 })
    }
}

@Test func clicksInTheBubbleStillSound() async throws {
    try await withTemporaryDirectory { dir in
        let project = try await clickTake(in: dir, clicks: [3])
        let legacy = clickDocument(project, [])
        let plain = try await mixed(project, legacy)
        #expect(plain == (try clicks(at: [144_000], count: 384_000)), "the 1b mix: the sound from the click's frame")
        // The same click outside the block, in a Bubble block, in a split and in Screen only: as in 1b.
        for document in [
            clickDocument(project, [(.cameraFull, 4.5, 7, false)]), clickDocument(project, [(.bubble, 2, 4, false)]),
            clickDocument(project, [(.split, 2, 4, false)]), clickDocument(project, [(.screenOnly, 2, 4, false)]),
        ] {
            #expect(try await mixed(project, document).map(\.bitPattern) == plain.map(\.bitPattern), "\(document.camera.layouts)")
        }
        // The camera not shown: every layout is seen as Screen only, and the click sounds.
        var hidden = clickDocument(project, [(.cameraFull, 1, 6, false)])
        hidden.camera.show = false
        #expect(try await mixed(project, hidden).map(\.bitPattern) == plain.map(\.bitPattern))
    }
}

/// At the edges of a block, the screen's opacity decides: at least 0.5 sounds, under it not; a click that does not sound
/// does not keep the next one within 40 ms quiet.
@Test func clickSoundsFollowTheScreensOpacityAtTheirInstant() async throws {
    try await withTemporaryDirectory { dir in
        let project = try await clickTake(in: dir, clicks: [3])
        // Camera full screen starting 0.1 s before the click (the screen still at 0.63) and 0.2 s before (at 0.26).
        let early = clickDocument(project, [(.cameraFull, 2.9, 6, false)]), late = clickDocument(project, [(.cameraFull, 2.8, 6, false)])
        #expect(screenOpacity(project, early, at: 3) >= 0.5 && screenOpacity(project, late, at: 3) < 0.5)
        let plain = try await mixed(project, clickDocument(project, []))
        #expect(try await mixed(project, early).map(\.bitPattern) == plain.map(\.bitPattern))
        #expect(try await mixed(project, late).allSatisfy { $0 == 0 })

        // An instant block that ends between two clicks 30 ms apart: the first is under it, the second sounds.
        let pair = try await clickTake(in: dir, name: "Pair", clicks: [2.98, 3.01])
        let instant = clickDocument(pair, [(.cameraFull, 1, 3, true)])
        #expect(screenOpacity(pair, instant, at: 2.98) == 0 && screenOpacity(pair, instant, at: 3.01) == 1)
        #expect(try await mixed(pair, instant) == (try clicks(at: [144_480], count: 384_000)))
    }
}
