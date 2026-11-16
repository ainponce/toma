// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import Testing
// Not @testable: the app uses only the public API.
import Editing
import ProjectFormat

/// The fixture of the style commands' tests, namespaced so that no other file of EditingTests meets its names: the
/// legacy document of a take of one display recorded for 30 s, with a camera change while recording.
private enum StyleFixture {
    static let takeID = "take-001"
    static let base = HostTime(nanoseconds: 5_000_000_000_000)

    static let take = TakeRecord(
        id: takeID, status: .complete, startedAt: Date(timeIntervalSince1970: 1_800_000_000),
        tracks: [
            TrackRecord(
                id: "display-1", kind: .display,
                source: TrackSource(name: "Display", displayID: 1, globalFrame: Rect(x: 0, y: 0, width: 1440, height: 900), pixelScale: 2),
                segments: [
                    SegmentRecord(
                        index: 1, file: "takes/take-001/display-1/seg-0001.mov", startHostTime: base,
                        endHostTime: base.adding(seconds: 30), endReason: .stopped, droppedFrames: 0, heartbeatFrames: 0)
                ]),
            TrackRecord(id: "mic", kind: .microphone, source: TrackSource(name: "Microphone"), segments: []),
        ],
        cameraStyle: .default)

    static let legacy = EditDocument.legacy(
        take: take,
        events: [
            InputEvent(
                t: base.adding(seconds: 4), kind: .cameraStyle(CameraStyle(shape: .portrait, size: CameraStyle.large, anchor: .top)))
        ])
}

@Test func applyDefaultStyleIsOneStepAndLeavesTheSequence() throws {
    let document = StyleFixture.legacy
    let step = try #require(StyleCommands.applyDefaultStyle(document, .toma))
    #expect(step.label == .applyDefaultStyle)
    let edited = try document.applying(step.changes)
    #expect(try edited.applying(step.changes.reversed().map(\.inverse)) == document)
    // The style, the cursor and the zoom's settings are Toma's.
    #expect(edited.style == DefaultStyle.toma.style)
    #expect(edited.cursor == DefaultStyle.toma.cursor)
    #expect(edited.zoom.auto == DefaultStyle.toma.zoomAuto)
    #expect(edited.zoom.show == DefaultStyle.toma.zoomShow)
    #expect(edited.zoom.spring == DefaultStyle.toma.zoomSpring)
    #expect(edited.zoom.motionBlur == DefaultStyle.toma.zoomMotionBlur)
    // Nothing else.
    #expect(edited.sequence == document.sequence)
    #expect(edited.camera == document.camera)
    #expect(edited.aspect == document.aspect)
    #expect(edited.frameRate == document.frameRate)
    #expect(edited.screens == document.screens)
    #expect(edited.audio == document.audio)
    #expect(edited.zoom.regions == document.zoom.regions)
    #expect(edited.zoom.suppressed == document.zoom.suppressed)
    // Applied again, nothing changes.
    #expect(StyleCommands.applyDefaultStyle(edited, .toma) == nil)

    // A style of the user's, saved from a project drawn as phase 0 drew it, still gets the sampling and the spring of a
    // new project.
    var saved = DefaultStyle.toma
    saved.style = document.style
    saved.style.background = .wallpaper("lavender-1")
    let mine = try document.applying(try #require(StyleCommands.applyDefaultStyle(document, saved)).changes)
    #expect(mine.style.background == .wallpaper("lavender-1"))
    #expect(mine.style.screenSampling == .mipmapped)
    #expect(mine.style.geometryTransition == .spring)
}

@Test func setterWithTheSameValueIsNoStep() throws {
    let document = StyleFixture.legacy
    #expect(document.style.padding == 0.08)
    #expect(StyleCommands.set(document, "/style/padding", 0.08, label: .padding) == nil)
    let step = try #require(StyleCommands.set(document, "/style/padding", 0.1, label: .padding))
    #expect(step.label == .padding)
    #expect(step.target == "/style/padding")
    #expect(step.changes == [try #require(document.setChange("/style/padding", 0.1))])

    // One of Toma's wallpapers, a track's gain by its escaped key, a clip's speed by its index.
    let wallpaper = try #require(StyleCommands.set(document, "/style/background", Background.wallpaper("dune-1"), label: .background))
    #expect(try document.applying(wallpaper.changes).style.background == .wallpaper("dune-1"))
    let gain = try #require(StyleCommands.set(document, "/audio/tracks/take-001~1mic/gain", 0.5, label: .volume))
    #expect(try document.applying(gain.changes).audio.tracks["take-001/mic"]?.gain == 0.5)
    #expect(StyleCommands.set(document, "/sequence/0/speed", 2.0, label: .speed) != nil)

    // Nothing there: an optional value that is not set, an index out of range, a pointer that is not one; and what no
    // edit sets, or no number.
    #expect(document.screens.planner == nil)
    #expect(StyleCommands.set(document, "/screens/planner", "screenFollow-1", label: .screen) == nil)
    #expect(StyleCommands.set(document, "/sequence/1/speed", 2.0, label: .speed) == nil)
    #expect(StyleCommands.set(document, "/sequence/00/speed", 2.0, label: .speed) == nil)
    #expect(StyleCommands.set(document, "style/padding", 0.1, label: .padding) == nil)
    #expect(StyleCommands.set(document, "/logSequence", 4, label: .padding) == nil)
    #expect(StyleCommands.set(document, "/style/padding", Double.nan, label: .padding) == nil)
}

@Test func aspectAndFrameRateAreProjectSteps() throws {
    let document = StyleFixture.legacy
    #expect(StyleCommands.frameRates == [24, 25, 30, 50, 60])
    #expect(StyleCommands.setAspect(document, .landscape) == nil)
    let portrait = try #require(StyleCommands.setAspect(document, .portrait))
    #expect(portrait.label == .aspect)
    #expect(try document.applying(portrait.changes).aspect == .portrait)
    #expect(StyleCommands.setFrameRate(document, 60) == nil)
    #expect(StyleCommands.setFrameRate(document, 31) == nil)
    let thirty = try #require(StyleCommands.setFrameRate(document, 30))
    #expect(thirty.label == .frameRate)
    #expect(thirty.changes == [try #require(document.setChange("/frameRate", 30))])
}
