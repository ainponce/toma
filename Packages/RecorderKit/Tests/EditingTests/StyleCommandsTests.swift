// SPDX-License-Identifier: GPL-3.0-or-later
import Analysis
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

    /// A camera change while recording, at 4 s, and a click in the middle of the display at 10 s.
    static let events = [
        InputEvent(t: base.adding(seconds: 4), kind: .cameraStyle(CameraStyle(shape: .portrait, size: CameraStyle.large, anchor: .top))),
        InputEvent(t: base.adding(seconds: 10), kind: .mouseDown(.left, x: 720, y: 450)),
        InputEvent(t: base.adding(seconds: 10.05), kind: .mouseUp(.left, x: 720, y: 450)),
    ]

    static let legacy = EditDocument.legacy(take: take, events: events)

    static func apply(_ style: DefaultStyle, to document: EditDocument, events: [InputEvent] = events) -> EditStep? {
        StyleCommands.applyDefaultStyle(document, style, take: take, events: events)
    }
}

@Test func applyDefaultStyleIsOneStepAndLeavesTheSequence() throws {
    let document = StyleFixture.legacy
    #expect(document.zoom.regions.isEmpty)
    let step = try #require(StyleFixture.apply(.toma, to: document))
    #expect(step.label == .applyDefaultStyle)
    let edited = try document.applying(step.changes)
    #expect(try edited.applying(step.changes.reversed().map(\.inverse)) == document)
    // The style, the cursor and the zoom's settings are Toma's, the cursor Toma's arrow: the take recorded no images.
    #expect(edited.style == DefaultStyle.toma.style)
    var cursor = DefaultStyle.toma.cursor
    cursor.style = .toma
    #expect(edited.cursor == cursor)
    #expect(edited.zoom.auto == DefaultStyle.toma.zoomAuto)
    #expect(edited.zoom.show == DefaultStyle.toma.zoomShow)
    #expect(edited.zoom.spring == DefaultStyle.toma.zoomSpring)
    #expect(edited.zoom.motionBlur == DefaultStyle.toma.zoomMotionBlur)
    // In the same step, the automatic zoom planned for the document so styled: the click at 10 s.
    var unplanned = edited
    unplanned.zoom.regions = []
    let planned = AutoZoomPlanner.plan(take: StyleFixture.take, events: StyleFixture.events, document: unplanned)
    #expect(planned.count == 1)
    #expect(edited.zoom.regions == planned)
    // Nothing else.
    #expect(edited.sequence == document.sequence)
    #expect(edited.camera == document.camera)
    #expect(edited.aspect == document.aspect)
    #expect(edited.frameRate == document.frameRate)
    #expect(edited.screens == document.screens)
    #expect(edited.audio == document.audio)
    #expect(edited.zoom.suppressed == document.zoom.suppressed)
    // Applied again, nothing changes.
    #expect(StyleFixture.apply(.toma, to: edited) == nil)

    // A take that recorded its cursor's images is drawn with them.
    let images = StyleFixture.events
        + [InputEvent(t: StyleFixture.base.adding(seconds: 1), kind: .cursorImage(hash: String(repeating: "a", count: 32), hotspot: SIMD2(0.1, 0.1), size: SIMD2(16, 16), kind: nil))]
    #expect(try document.applying(try #require(StyleFixture.apply(.toma, to: document, events: images)).changes).cursor.style == .system)

    // A style of the user's, saved from a project drawn as phase 0 drew it, still gets the sampling and the spring of a
    // new project.
    var saved = DefaultStyle.toma
    saved.style = document.style
    saved.style.background = .wallpaper("lavender-1")
    let mine = try document.applying(try #require(StyleFixture.apply(saved, to: document)).changes)
    #expect(mine.style.background == .wallpaper("lavender-1"))
    #expect(mine.style.screenSampling == .mipmapped)
    #expect(mine.style.geometryTransition == .spring)
}

@Test func applyingAStyleWithoutTheAutomaticZoomTakesItsBlocksAway() throws {
    var document = try StyleFixture.legacy.applying(try #require(StyleFixture.apply(.toma, to: StyleFixture.legacy)).changes)
    let auto = try #require(document.zoom.regions.first)
    let user = ZoomRegion(
        id: "z-0000000c", take: StyleFixture.takeID, start: StyleFixture.base.adding(seconds: 20),
        end: StyleFixture.base.adding(seconds: 22), origin: .user, depth: 1.6, focus: .follow, instant: false)
    document.zoom.regions.append(user)
    var off = DefaultStyle.toma
    off.zoomAuto.enabled = false
    let step = try #require(StyleFixture.apply(off, to: document))
    #expect(step.label == .applyDefaultStyle)
    #expect(step.changes.contains(try #require(document.removeChange(.zoomRegions, at: 0))))
    let edited = try document.applying(step.changes)
    #expect(edited.zoom.regions == [user])
    #expect(edited.zoom.auto.enabled == false)
    #expect(!edited.zoom.regions.contains(auto))
}

@Test func setterWithTheSameValueIsNoStep() throws {
    let document = StyleFixture.legacy
    #expect(document.style.padding == 0.08)
    #expect(StyleCommands.set(document, "/style/padding", 0.08, label: .padding) == nil)
    let step = try #require(StyleCommands.set(document, "/style/padding", 0.1, label: .padding))
    #expect(step.label == .padding)
    #expect(step.target == "/style/padding")
    #expect(step.changes == [try #require(document.setChange("/style/padding", 0.1))])

    // One of Toma's wallpapers, a track's gain by its escaped key, a colour of the gradient by its index, the camera and
    // the zooms shown or not.
    let wallpaper = try #require(StyleCommands.set(document, "/style/background", Background.wallpaper("dune-1"), label: .background))
    #expect(try document.applying(wallpaper.changes).style.background == .wallpaper("dune-1"))
    let gain = try #require(StyleCommands.set(document, "/audio/tracks/take-001~1mic/gain", 0.5, label: .volume))
    #expect(try document.applying(gain.changes).audio.tracks["take-001/mic"]?.gain == 0.5)
    #expect(StyleCommands.set(document, "/style/background/start/0", 0.5, label: .background) != nil)
    #expect(StyleCommands.set(document, "/camera/show", false, label: .camera) != nil)
    #expect(StyleCommands.set(document, "/zoom/show", false, label: .zoomChange) != nil)

    // Nothing there: an optional value that is not set, an index out of range, a pointer that is not one; or no number.
    #expect(document.screens.planner == nil)
    #expect(StyleCommands.set(document, "/style/background/start/4", 0.5, label: .background) == nil)
    #expect(StyleCommands.set(document, "/style/background/start/00", 0.5, label: .background) == nil)
    #expect(StyleCommands.set(document, "style/padding", 0.1, label: .padding) == nil)
    #expect(StyleCommands.set(document, "/style/padding", Double.nan, label: .padding) == nil)
    // What has a command of its own, which keeps its rules: the clips, the blocks and changes of the tracks, the
    // automatic zoom's settings, the camera's styles, the screens, the aspect, the frame rate, what no edit sets.
    for pointer in [
        "/sequence/0/speed", "/sequence", "/camera/changes/0/style/size", "/camera/initial/take-001/size", "/zoom/auto/depth",
        "/zoom/regions", "/zoom/suppressed", "/screens/planner", "/screens/initial/take-001", "/aspect", "/frameRate",
        "/logSequence", "", "/",
    ] {
        #expect(StyleCommands.set(document, pointer, 2.0, label: .padding) == nil, "\(pointer)")
    }
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

@Test func reframeIsOneStep() throws {
    let doc = EditDocument.legacy(
        take: TakeRecord(id: "take-001", status: .complete, startedAt: Date(timeIntervalSince1970: 1_800_000_000), tracks: []),
        events: [])
    #expect(StyleCommands.setReframe(doc, .fit) == nil)
    let step = try #require(StyleCommands.setReframe(doc, .followCursor))
    #expect(step.label == .styleReframe)
    #expect(step.target == "/style/reframe")
    #expect(step.changes.count == 1)
    #expect(try doc.applying(step.changes).style.reframe == .followCursor)
}
