// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import RecorderKitTestSupport
import Render
import Testing
@testable import ProjectFormat

private func ns(_ nanoseconds: UInt64) -> HostTime { HostTime(nanoseconds: nanoseconds) }

/// The example of `edit.json` of design §6.2: a new project with two clips (the second at 2×), a change of screen, an
/// automatic zoom, a manual one and a deleted automatic one.
enum DesignExample {
    /// The example as the design writes it, with objects on one line.
    static let json = """
        {
          "aspect" : "16:9",
          "audio" : {
            "limiter" : true,
            "tracks" : {
              "take-001/mic" : { "gain" : 1, "muted" : false },
              "take-001/system-audio" : { "gain" : 0.8, "muted" : false }
            }
          },
          "camera" : {
            "changes" : [
              { "id" : "k-1c2d0a9e", "origin" : "recorded", "style" : { "anchor" : "topLeading", "shape" : "circle", "size" : 0.24 }, "t" : 81290000000000, "take" : "take-001" }
            ],
            "initial" : { "take-001" : { "anchor" : "bottomTrailing", "shape" : "circle", "size" : 0.24 } },
            "show" : true
          },
          "cursor" : {
            "clickEffect" : "ripple-1",
            "clickSound" : "none",
            "clickSoundGain" : 0.5,
            "hideWhenIdle" : true,
            "idleDelay" : 2,
            "motionBlur" : 0.5,
            "scale" : 1.5,
            "show" : true,
            "smoothing" : { "damping" : 1, "response" : 0.16 },
            "style" : "system"
          },
          "documentVersion" : 1,
          "frameRate" : 60,
          "logSequence" : 128,
          "screens" : {
            "changes" : [ { "id" : "p-9a01b2c3", "origin" : "auto", "t" : 81260000000000, "take" : "take-001", "track" : "display-2" } ],
            "initial" : { "take-001" : "display-1" },
            "planner" : "screenFollow-1"
          },
          "sequence" : [
            { "end" : 81276901234567, "id" : "c-00a1b2c3", "speed" : 1, "start" : 81234567890123, "take" : "take-001" },
            { "end" : 81334000000000, "id" : "c-00d4e5f6", "speed" : 2, "start" : 81277458000000, "take" : "take-001" }
          ],
          "style" : {
            "background" : { "type" : "wallpaper", "wallpaper" : "aurora-1" },
            "backgroundBlur" : 0,
            "cornerRadius" : 0.012,
            "frame" : { "type" : "none" },
            "geometryTransition" : "spring",
            "padding" : 0.08,
            "screenSampling" : "mipmapped",
            "shadow" : 0.6
          },
          "zoom" : {
            "auto" : { "depth" : 2, "enabled" : true, "follow" : true, "groupGap" : 2.5, "holdWhileTyping" : true, "leadIn" : 0.5, "leadOut" : 1, "planner" : "autoZoom-1", "triggers" : "clicks" },
            "motionBlur" : 0.5,
            "regions" : [
              { "end" : 81245000000000, "focus" : { "type" : "follow" }, "id" : "z-3fa2b1c0", "instant" : false, "origin" : "auto", "start" : 81241000000000, "take" : "take-001" },
              { "depth" : 1.6, "end" : 81300000000000, "focus" : { "type" : "fixed", "x" : 0.31, "y" : 0.72 }, "id" : "z-7e11d0aa", "instant" : false, "origin" : "user", "start" : 81296000000000, "take" : "take-001" }
            ],
            "show" : true,
            "spring" : { "damping" : 1, "response" : 0.7 },
            "suppressed" : [ { "end" : 81320000000000, "start" : 81318000000000, "take" : "take-001" } ]
          }
        }
        """

    /// The value the example holds, field by field.
    static let document = EditDocument(
        documentVersion: 1,
        logSequence: 128,
        aspect: .landscape,
        frameRate: 60,
        sequence: [
            Clip(id: "c-00a1b2c3", take: "take-001", start: ns(81_234_567_890_123), end: ns(81_276_901_234_567), speed: 1),
            Clip(id: "c-00d4e5f6", take: "take-001", start: ns(81_277_458_000_000), end: ns(81_334_000_000_000), speed: 2),
        ],
        screens: ScreenPlan(
            initial: ["take-001": "display-1"],
            changes: [ScreenChange(id: "p-9a01b2c3", take: "take-001", t: ns(81_260_000_000_000), track: "display-2", origin: .auto)],
            planner: "screenFollow-1"),
        style: StageStyle(
            background: .wallpaper("aurora-1"), backgroundBlur: 0, padding: 0.08, cornerRadius: 0.012, shadow: 0.6,
            frame: .none, screenSampling: .mipmapped, geometryTransition: .spring),
        cursor: CursorStyle(
            show: true, style: .system, scale: 1.5, smoothing: .spring(SpringSpec(damping: 1, response: 0.16)), hideWhenIdle: true,
            idleDelay: 2, clickEffect: "ripple-1", clickSound: "none", clickSoundGain: 0.5, motionBlur: 0.5),
        zoom: ZoomPlan(
            show: true,
            auto: AutoZoomSettings(
                enabled: true, triggers: .clicks, holdWhileTyping: true, depth: 2, groupGap: 2.5, leadIn: 0.5, leadOut: 1,
                follow: true, planner: "autoZoom-1"),
            spring: SpringSpec(damping: 1, response: 0.7),
            motionBlur: 0.5,
            regions: [
                ZoomRegion(
                    id: "z-3fa2b1c0", take: "take-001", start: ns(81_241_000_000_000), end: ns(81_245_000_000_000), origin: .auto,
                    focus: .follow, instant: false),
                ZoomRegion(
                    id: "z-7e11d0aa", take: "take-001", start: ns(81_296_000_000_000), end: ns(81_300_000_000_000), origin: .user,
                    depth: 1.6, focus: .fixed(x: 0.31, y: 0.72), instant: false),
            ],
            suppressed: [SourceRange(take: "take-001", start: ns(81_318_000_000_000), end: ns(81_320_000_000_000))]),
        camera: CameraPlan(
            show: true,
            initial: ["take-001": CameraStyle(shape: .circle, size: 0.24, anchor: .bottomTrailing)],
            changes: [
                CameraChange(
                    id: "k-1c2d0a9e", take: "take-001", t: ns(81_290_000_000_000),
                    style: CameraStyle(shape: .circle, size: 0.24, anchor: .topLeading), origin: .recorded),
            ]),
        audio: AudioPlan(
            limiter: true,
            tracks: ["take-001/mic": TrackGain(gain: 1, muted: false), "take-001/system-audio": TrackGain(gain: 0.8, muted: false)])
    )

    /// The example as `ProjectJSON.encoder()` writes it: one key per line, as in `docs/format/README.md`.
    static let canonical = """
        {
          "aspect" : "16:9",
          "audio" : {
            "limiter" : true,
            "tracks" : {
              "take-001/mic" : {
                "gain" : 1,
                "muted" : false
              },
              "take-001/system-audio" : {
                "gain" : 0.8,
                "muted" : false
              }
            }
          },
          "camera" : {
            "changes" : [
              {
                "id" : "k-1c2d0a9e",
                "origin" : "recorded",
                "style" : {
                  "anchor" : "topLeading",
                  "shape" : "circle",
                  "size" : 0.24
                },
                "t" : 81290000000000,
                "take" : "take-001"
              }
            ],
            "initial" : {
              "take-001" : {
                "anchor" : "bottomTrailing",
                "shape" : "circle",
                "size" : 0.24
              }
            },
            "show" : true
          },
          "cursor" : {
            "clickEffect" : "ripple-1",
            "clickSound" : "none",
            "clickSoundGain" : 0.5,
            "hideWhenIdle" : true,
            "idleDelay" : 2,
            "motionBlur" : 0.5,
            "scale" : 1.5,
            "show" : true,
            "smoothing" : {
              "damping" : 1,
              "response" : 0.16
            },
            "style" : "system"
          },
          "documentVersion" : 1,
          "frameRate" : 60,
          "logSequence" : 128,
          "screens" : {
            "changes" : [
              {
                "id" : "p-9a01b2c3",
                "origin" : "auto",
                "t" : 81260000000000,
                "take" : "take-001",
                "track" : "display-2"
              }
            ],
            "initial" : {
              "take-001" : "display-1"
            },
            "planner" : "screenFollow-1"
          },
          "sequence" : [
            {
              "end" : 81276901234567,
              "id" : "c-00a1b2c3",
              "speed" : 1,
              "start" : 81234567890123,
              "take" : "take-001"
            },
            {
              "end" : 81334000000000,
              "id" : "c-00d4e5f6",
              "speed" : 2,
              "start" : 81277458000000,
              "take" : "take-001"
            }
          ],
          "style" : {
            "background" : {
              "type" : "wallpaper",
              "wallpaper" : "aurora-1"
            },
            "backgroundBlur" : 0,
            "cornerRadius" : 0.012,
            "frame" : {
              "type" : "none"
            },
            "geometryTransition" : "spring",
            "padding" : 0.08,
            "screenSampling" : "mipmapped",
            "shadow" : 0.6
          },
          "zoom" : {
            "auto" : {
              "depth" : 2,
              "enabled" : true,
              "follow" : true,
              "groupGap" : 2.5,
              "holdWhileTyping" : true,
              "leadIn" : 0.5,
              "leadOut" : 1,
              "planner" : "autoZoom-1",
              "triggers" : "clicks"
            },
            "motionBlur" : 0.5,
            "regions" : [
              {
                "end" : 81245000000000,
                "focus" : {
                  "type" : "follow"
                },
                "id" : "z-3fa2b1c0",
                "instant" : false,
                "origin" : "auto",
                "start" : 81241000000000,
                "take" : "take-001"
              },
              {
                "depth" : 1.6,
                "end" : 81300000000000,
                "focus" : {
                  "type" : "fixed",
                  "x" : 0.31,
                  "y" : 0.72
                },
                "id" : "z-7e11d0aa",
                "instant" : false,
                "origin" : "user",
                "start" : 81296000000000,
                "take" : "take-001"
              }
            ],
            "show" : true,
            "spring" : {
              "damping" : 1,
              "response" : 0.7
            },
            "suppressed" : [
              {
                "end" : 81320000000000,
                "start" : 81318000000000,
                "take" : "take-001"
              }
            ]
          }
        }
        """
}

private func encoded(_ document: EditDocument) throws -> String {
    String(decoding: try ProjectJSON.encoder().encode(document), as: UTF8.self)
}

@Test func documentExampleRoundTripsByteForByte() throws {
    #expect(try EditDocument.decode(Data(DesignExample.json.utf8)) == DesignExample.document)
    #expect(try encoded(DesignExample.document) == DesignExample.canonical)
    #expect(try encoded(try EditDocument.decode(Data(DesignExample.canonical.utf8))) == DesignExample.canonical)
}

@Test func everyBackgroundFrameAndFocusRoundTrips() throws {
    let backgrounds: [Background] = [
        .tomaClassic, .color(RGBA(0.1, 0.2, 0.3, 1)), .wallpaper("aurora-1"), .image(file: "assets/0123456789abcdef0123456789abcdef.png"),
        .desktop,
    ]
    let frames: [WindowFrame] = [.none, .macWindow(appearance: .dark, title: "Notes", buttons: true)]
    for background in backgrounds {
        for frame in frames {
            var document = DesignExample.document
            document.style.background = background
            document.style.frame = frame
            document.cursor.smoothing = .off
            document.zoom.regions[0].focus = .fixed(x: 0.5, y: 0.25)
            #expect(try EditDocument.decode(Data(try encoded(document).utf8)) == document)
        }
    }
    var document = DesignExample.document
    document.style.background = .color(RGBA(0.1, 0.2, 0.3, 1))
    document.style.frame = .macWindow(appearance: .light, title: "", buttons: false)
    document.cursor.smoothing = .off
    let text = try encoded(document)
    #expect(text.contains(#""smoothing" : "off""#))
    #expect(text.contains("\"color\" : [\n        0.1,\n        0.2,\n        0.3,\n        1\n      ]"))
    #expect(text.contains(#""appearance" : "light""#))
}

@Test func optionalsAreOmittedNeverNull() throws {
    var document = DesignExample.document
    document.zoom.regions = [document.zoom.regions[0]]
    document.screens.planner = nil
    let text = try encoded(document)
    #expect(document.zoom.regions[0].depth == nil)
    #expect(!text.contains("\"depth\" : 1"))
    #expect(!text.contains("\"planner\" : \"screenFollow-1\""))
    // Only `zoom.auto` has a depth and a planner left.
    #expect(text.components(separatedBy: "\"depth\"").count == 2)
    #expect(text.components(separatedBy: "\"planner\"").count == 2)
    #expect(!text.contains("null"))
    #expect(try EditDocument.decode(Data(text.utf8)) == document)
}

@Test func legacyOfAPhaseZeroTake() async throws {
    try await withTemporaryDirectory { dir in
        let project = try await GoldenProjects.make("phaseZero", in: dir)
        let segment = try #require(project.take.track("display-1")?.segments.first)
        let start = segment.startHostTime
        let end = try #require(segment.endHostTime)
        let document = EditDocument.legacy(for: project)
        #expect(document == EditDocument.legacy(take: project.take, events: project.events))
        #expect(document.documentVersion == EditDocument.currentVersion)
        #expect(document.logSequence == 0)
        #expect(document.sequence == [Clip(id: "c-00000001", take: "take-001", start: start, end: end, speed: 1)])
        #expect(document.aspect == .landscape)
        #expect(document.frameRate == 60)
        #expect(document.screens == ScreenPlan(initial: ["take-001": "display-1"], changes: []))
        let style = document.style
        #expect(style.background == .tomaClassic)
        #expect(style.backgroundBlur == 0)
        #expect(style.padding == 0.08)
        #expect(style.cornerRadius == 0.012)
        #expect(style.shadow == 0)
        #expect(style.frame == .none)
        #expect(style.screenSampling == .bilinear)
        #expect(style.geometryTransition == .none)
        let cursor = document.cursor
        #expect(cursor.show)
        #expect(cursor.style == .toma)
        #expect(cursor.scale == 1)
        #expect(cursor.smoothing == .off)
        #expect(!cursor.hideWhenIdle)
        #expect(cursor.idleDelay == 2)
        #expect(cursor.clickEffect == "none")
        #expect(cursor.clickSound == "none")
        #expect(cursor.clickSoundGain == 0.5)
        #expect(cursor.motionBlur == 0)
        var auto = DefaultStyle.toma.zoomAuto
        auto.enabled = false
        #expect(
            document.zoom
                == ZoomPlan(show: true, auto: auto, spring: SpringSpec(damping: 1, response: 0.7), motionBlur: 0, regions: [], suppressed: []))
        #expect(document.camera == CameraPlan(show: true, initial: ["take-001": .default], changes: []))
        #expect(document.audio == AudioPlan(limiter: false, tracks: ["take-001/mic": TrackGain(gain: 1, muted: false)]))
    }
}

@Test func legacyKeepsPausesInOneClip() async throws {
    try await withTemporaryDirectory { dir in
        let project = try await GoldenProjects.make("pausedTake", in: dir)
        let segments = try #require(project.take.track("display-1")?.segments)
        let start = segments[0].startHostTime
        let document = EditDocument.legacy(for: project)
        #expect(document.sequence == [Clip(id: "c-00000001", take: "take-001", start: start, end: start.adding(seconds: 3), speed: 1)])
        #expect(try #require(segments.last?.endHostTime) == start.adding(seconds: 3))
        #expect(TakeTimeline.recordedSpans(take: project.take, events: project.events) == [
            start..<start.adding(seconds: 1), start.adding(seconds: 2)..<start.adding(seconds: 3),
        ])
    }
}

@Test func legacyCameraComesFromTheTake() async throws {
    try await withTemporaryDirectory { dir in
        let project = try await GoldenProjects.make("cameraWithStyleChanges", in: dir)
        let start = try #require(project.take.track("display-1")?.segments.first?.startHostTime)
        let camera = EditDocument.legacy(for: project).camera
        #expect(camera.show)
        #expect(camera.initial == ["take-001": CameraStyle(shape: .landscape, size: 0.17, anchor: .topLeading)])
        #expect(camera.changes == [
            CameraChange(
                id: "k-00000001", take: "take-001", t: start.adding(seconds: 1),
                style: CameraStyle(shape: .portrait, size: 0.33, anchor: .top), origin: .recorded),
            CameraChange(
                id: "k-00000002", take: "take-001", t: start.adding(seconds: 1.1),
                style: CameraStyle(shape: .circle, size: 0.24, anchor: .bottomTrailing), origin: .recorded),
        ])
    }
}

@Test func legacyCameraChangesAreInTimeOrder() {
    let take = TakeRecord(id: "take-001", status: .complete, startedAt: Date(timeIntervalSince1970: 0), tracks: [])
    let late = CameraStyle(shape: .portrait, size: 0.33, anchor: .top)
    let early = CameraStyle(shape: .circle, size: 0.17, anchor: .leading)
    let events = [InputEvent(t: ns(2_000), kind: .cameraStyle(late)), InputEvent(t: ns(1_000), kind: .cameraStyle(early))]
    let camera = EditDocument.legacy(take: take, events: events).camera
    #expect(camera.initial == ["take-001": .default])
    #expect(camera.changes.map(\.id) == ["k-00000001", "k-00000002"])
    #expect(camera.changes.map(\.style) == [early, late])
}

@Test func legacyGradientConvertsToStyleV0Floats() throws {
    guard case let .gradient(start, end, angle) = Background.tomaClassic else {
        Issue.record("tomaClassic is not a gradient")
        return
    }
    let style = StyleV0()
    for (rgba, simd) in [(start, style.gradientStart), (end, style.gradientEnd)] {
        let floats = [Float(rgba.r), Float(rgba.g), Float(rgba.b), Float(rgba.a)]
        #expect(floats.map(\.bitPattern) == [simd.x, simd.y, simd.z, simd.w].map(\.bitPattern))
    }
    #expect(Float(angle).bitPattern == style.gradientAngleDegrees.bitPattern)
    #expect(start == RGBA(127.0 / 255, 90.0 / 255, 240.0 / 255, 1))
    #expect(end == RGBA(44.0 / 255, 177.0 / 255, 188.0 / 255, 1))
}

@Test func newerDocumentVersionIsRefused() throws {
    // Read before the rest: the rest of a newer document need not decode.
    #expect(throws: EditDocumentError.newerVersion(2)) {
        try EditDocument.decode(Data(#"{"documentVersion":2,"aspect":"4:3"}"#.utf8))
    }
    let newer = DesignExample.canonical.replacingOccurrences(of: "\"documentVersion\" : 1", with: "\"documentVersion\" : 2")
    #expect(throws: EditDocumentError.newerVersion(2)) { try EditDocument.decode(Data(newer.utf8)) }
    #expect(throws: DecodingError.self) { try EditDocument.decode(Data(#"{"documentVersion":1,"aspect":"4:3"}"#.utf8)) }
}

@Test func unknownValuesAreRefused() {
    for (from, to) in [
        (#""aspect" : "16:9""#, #""aspect" : "4:3""#),
        (#""type" : "wallpaper""#, #""type" : "video""#),
        (#""smoothing" : {"#, #""smoothing" : "on", "x" : {"#),
        (#""type" : "follow""#, #""type" : "center""#),
        (#""type" : "none""#, #""type" : "glass""#),
        (#""origin" : "auto""#, #""origin" : "planner""#),
    ] {
        let text = DesignExample.canonical.replacingOccurrences(of: from, with: to)
        #expect(text != DesignExample.canonical, "\(from)")
        #expect(throws: DecodingError.self, "\(from)") { try EditDocument.decode(Data(text.utf8)) }
    }
    var document = DesignExample.document
    document.style.background = .color(RGBA(0.1, 0.2, 0.3, 1))
    let threeComponents = (try? encoded(document))?.replacingOccurrences(of: "0.3,\n        1\n", with: "0.3\n") ?? ""
    #expect(throws: DecodingError.self) { try EditDocument.decode(Data(threeComponents.utf8)) }
}

@Test func tomaDefaultStyleHasTheDesignValues() {
    let toma = DefaultStyle.toma
    #expect(
        toma.style
            == StageStyle(
                background: .wallpaper("aurora-1"), backgroundBlur: 0, padding: 0.08, cornerRadius: 0.012, shadow: 0.6, frame: .none,
                screenSampling: .mipmapped, geometryTransition: .spring))
    #expect(
        toma.cursor
            == CursorStyle(
                show: true, style: .system, scale: 1.5, smoothing: .spring(SpringSpec(damping: 1, response: 0.16)), hideWhenIdle: true,
                idleDelay: 2, clickEffect: "ripple-1", clickSound: "none", clickSoundGain: 0.5, motionBlur: 0.5))
    #expect(toma.zoomShow)
    #expect(
        toma.zoomAuto
            == AutoZoomSettings(
                enabled: true, triggers: .clicks, holdWhileTyping: true, depth: 2.0, groupGap: 2.5, leadIn: 0.5, leadOut: 1.0, follow: true,
                planner: "autoZoom-1"))
    #expect(toma.zoomSpring == SpringSpec(damping: 1.0, response: 0.70))
    #expect(toma.zoomMotionBlur == 0.5)
    // The design example is a new project with this style.
    #expect(toma.style == DesignExample.document.style)
    #expect(toma.cursor == DesignExample.document.cursor)
    #expect(toma.zoomAuto == DesignExample.document.zoom.auto)
}

@Test func valuesOfTheSmallTypes() throws {
    #expect(Aspect.landscape.ratio == 16.0 / 9)
    #expect(Aspect.portrait.ratio == 9.0 / 16)
    #expect(Aspect.square.ratio == 1)
    #expect([Aspect.landscape, .portrait, .square].map(\.rawValue) == ["16:9", "9:16", "1:1"])
    #expect(AudioPlan.key(take: "take-001", track: "mic") == "take-001/mic")
    #expect(ZoomTriggers.clicksAndPauses.rawValue == "clicksAndPauses")
    let defaultStyle = String(decoding: try ProjectJSON.encoder().encode(DefaultStyle.toma), as: UTF8.self)
    #expect(try ProjectJSON.decoder().decode(DefaultStyle.self, from: Data(defaultStyle.utf8)) == DefaultStyle.toma)
}

@Test func recordedSpansSplitAtPauses() {
    let display = TrackRecord(
        id: "display-1", kind: .display, source: TrackSource(name: "Display", displayID: 1),
        segments: [
            SegmentRecord(
                index: 1, file: "takes/take-001/display-1/seg-0001.mov", startHostTime: ns(0), endHostTime: ns(1_000_000_000),
                endReason: .paused, droppedFrames: 0, heartbeatFrames: 0),
            SegmentRecord(
                index: 2, file: "takes/take-001/display-1/seg-0002.mov", startHostTime: ns(2_000_000_000),
                endHostTime: ns(3_000_000_000), endReason: .stopped, droppedFrames: 0, heartbeatFrames: 0),
        ])
    let take = TakeRecord(id: "take-001", status: .complete, startedAt: Date(timeIntervalSince1970: 0), tracks: [display])
    let events = [
        InputEvent(t: ns(1_000_000_000), kind: .paused(reason: "user")), InputEvent(t: ns(2_000_000_000), kind: .resumed),
    ]
    #expect(TakeTimeline.bounds(take: take, events: events).start == ns(0))
    #expect(TakeTimeline.bounds(take: take, events: events).end == ns(3_000_000_000))
    #expect(TakeTimeline.bounds(take: take, events: events).screen?.id == "display-1")
    #expect(TakeTimeline.recordedSpans(take: take, events: events) == [ns(0)..<ns(1_000_000_000), ns(2_000_000_000)..<ns(3_000_000_000)])
    // Out of order in the file, a repeated pause, a resume without a pause and a pause never resumed.
    let messy = [
        InputEvent(t: ns(2_500_000_000), kind: .paused(reason: "screenLocked")), InputEvent(t: ns(500_000_000), kind: .resumed),
        InputEvent(t: ns(2_000_000_000), kind: .resumed), InputEvent(t: ns(1_000_000_000), kind: .paused(reason: "user")),
        InputEvent(t: ns(1_500_000_000), kind: .paused(reason: "user")),
    ]
    #expect(TakeTimeline.recordedSpans(take: take, events: messy) == [ns(0)..<ns(1_000_000_000), ns(2_000_000_000)..<ns(2_500_000_000)])
    #expect(TakeTimeline.recordedSpans(take: take, events: []) == [ns(0)..<ns(3_000_000_000)])
    // A pause at the start leaves no empty span.
    #expect(TakeTimeline.recordedSpans(take: take, events: [InputEvent(t: ns(0), kind: .paused(reason: "user"))]) == [])
}

@Test func takeWithoutScreenHasAnEmptyTimeline() {
    let mic = TrackRecord(
        id: "mic", kind: .microphone, source: TrackSource(name: "Mic"),
        segments: [
            SegmentRecord(
                index: 1, file: "takes/take-001/mic/seg-0001.m4a", startHostTime: ns(1_000), endHostTime: ns(9_000), droppedFrames: 0,
                heartbeatFrames: 0),
        ])
    let take = TakeRecord(id: "take-001", status: .complete, startedAt: Date(timeIntervalSince1970: 0), tracks: [mic])
    let bounds = TakeTimeline.bounds(take: take, events: [])
    #expect(bounds.screen == nil)
    #expect(bounds.start == ns(0))
    #expect(bounds.end == ns(0))
    #expect(TakeTimeline.recordedSpans(take: take, events: []) == [])
    let document = EditDocument.legacy(take: take, events: [])
    #expect(document.sequence == [Clip(id: "c-00000001", take: "take-001", start: ns(0), end: ns(0), speed: 1)])
    #expect(document.screens.initial.isEmpty)
    #expect(document.audio.tracks == ["take-001/mic": TrackGain(gain: 1, muted: false)])
}
