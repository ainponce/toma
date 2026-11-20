// SPDX-License-Identifier: GPL-3.0-or-later
import Analysis
import Foundation
import RecorderKitTestSupport
import Testing
// Not @testable: the app uses only the public API.
import Editing
import ProjectFormat

/// The fixture of the editing commands over several takes (phase 3 design §8.1, 3d plan decision 17), namespaced so that
/// no other file of EditingTests meets its names: two takes of two displays side by side, `display-1` (1440 × 900 pt at
/// the origin) and `display-2` (1920 × 1080 pt to its right), each recorded for 60 s, the second 100 s after the first,
/// with a camera; and a document of their first 20 s each, `[001 0–20, 002 0–20]`, of Toma's automatic zoom.
private enum TwoTakes {
    static let first = "take-001", second = "take-002"
    static let frame1 = Rect(x: 0, y: 0, width: 1440, height: 900)
    static let frame2 = Rect(x: 1440, y: 0, width: 1920, height: 1080)

    static func base(_ take: String) -> HostTime {
        HostTime(nanoseconds: take == first ? 5_000_000_000_000 : 5_100_000_000_000)
    }

    static func at(_ take: String, _ seconds: Double) -> HostTime { base(take).adding(seconds: seconds) }

    static func segment(_ take: String, _ track: String) -> SegmentRecord {
        SegmentRecord(
            index: 1, file: "takes/\(take)/\(track)/seg-0001.mov", startHostTime: base(take), endHostTime: at(take, 60),
            endReason: .stopped, droppedFrames: 0, heartbeatFrames: 0)
    }

    static func display(_ number: Int, of take: String) -> TrackRecord {
        TrackRecord(
            id: "display-\(number)", kind: .display,
            source: TrackSource(
                name: "Display \(number)", displayID: UInt32(number), globalFrame: number == 1 ? frame1 : frame2, pixelScale: 2),
            segments: [segment(take, "display-\(number)")])
    }

    static func camera(of take: String) -> TrackRecord {
        TrackRecord(
            id: "camera", kind: .camera, source: TrackSource(name: "Camera", deviceUniqueID: "camera"),
            segments: [segment(take, "camera")])
    }

    /// A take of a window of 1200 × 800 pt, `window-1`.
    static func window(of take: String) -> TrackRecord {
        TrackRecord(
            id: "window-1", kind: .window,
            source: TrackSource(name: "Window", globalFrame: Rect(x: 100, y: 80, width: 1200, height: 800), pixelScale: 2, windowID: 7),
            segments: [segment(take, "window-1")])
    }

    static func take(_ id: String, tracks: [TrackRecord]? = nil) -> TakeRecord {
        TakeRecord(
            id: id, status: .complete, startedAt: Date(timeIntervalSince1970: id == first ? 1_800_000_000 : 1_800_000_100),
            tracks: tracks ?? [display(1, of: id), display(2, of: id), camera(of: id)], cameraStyle: .default)
    }

    /// A click in the middle of `display-1` (or of the window) `seconds` after the take's start.
    static func click(_ take: String, _ seconds: Double, x: Double = 720, y: Double = 450) -> [InputEvent] {
        [
            InputEvent(t: at(take, seconds), kind: .mouseDown(.left, x: x, y: y)),
            InputEvent(t: at(take, seconds + 0.05), kind: .mouseUp(.left, x: x, y: y)),
        ]
    }

    /// The pointer in the middle of display `screen` (1 or 2) `seconds` after the take's start.
    static func pointer(_ take: String, _ seconds: Double, on screen: Int) -> InputEvent {
        let frame = screen == 1 ? frame1 : frame2
        return InputEvent(t: at(take, seconds), kind: .cursor(x: frame.x + frame.width / 2, y: frame.y + frame.height / 2))
    }

    /// A click at 5 s of the first take and at 10 s of the second, both on `display-1`; the pointer on `display-2` from
    /// 3 s of the first and from 8 s of the second until those clicks.
    static let events: [String: [InputEvent]] = [
        first: click(first, 5) + [pointer(first, 0, on: 1), pointer(first, 3, on: 2), pointer(first, 6, on: 1)],
        second: click(second, 10) + [pointer(second, 0, on: 1), pointer(second, 8, on: 2), pointer(second, 12, on: 1)],
    ]

    static func clip(_ id: Int, _ take: String, _ from: Double, _ to: Double) -> Clip {
        Clip(id: "c-0000000\(id)", take: take, start: at(take, from), end: at(take, to), speed: 1)
    }

    /// The document of `takes` over `sequence` (`[001 0–20, 002 0–20]` by default): the legacy one of the first, with the
    /// screen and the camera of each, of Toma's automatic zoom and without blocks.
    static func document(_ takes: [TakeRecord], sequence: [Clip]? = nil) -> EditDocument {
        var document = EditDocument.legacy(take: takes[0], events: [])
        document.sequence = sequence ?? [clip(1, first, 0, 20), clip(2, second, 0, 20)]
        let screens = takes.map { take in (take.id, take.tracks.first { $0.kind.isScreen }?.id ?? "display-1") }
        document.screens = ScreenPlan(initial: Dictionary(uniqueKeysWithValues: screens), changes: [])
        document.camera = CameraPlan(show: true, initial: Dictionary(uniqueKeysWithValues: takes.map { ($0.id, .default) }), changes: [])
        document.zoom.auto = DefaultStyle.toma.zoomAuto
        document.zoom.regions = []
        return document
    }

    /// A package in `directory` with `takes`, each segment file a byte (so the planners and the caches count them), and
    /// the project focused on each, with its events.
    static func projects(in directory: URL, _ takes: [TakeRecord], events: [String: [InputEvent]]) throws -> [LoadedProject] {
        let package = ProjectPackage(url: directory.appending(path: "Takes.toma", directoryHint: .isDirectory))
        for take in takes {
            for track in take.tracks {
                for segment in track.segments {
                    let url = package.fileURL(segment.file)
                    try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
                    try Data([0x2A]).write(to: url)
                }
            }
        }
        let manifest = Manifest(
            formatVersion: 5, app: AppInfo(name: "Toma", version: "0.3.0"), createdAt: Date(timeIntervalSince1970: 1_800_000_000),
            takes: takes)
        return takes.map { LoadedProject(package: package, manifest: manifest, take: $0, events: events[$0.id] ?? []) }
    }

    /// `document` with `step` applied, checking on the way that its inverse gives `document` back.
    static func applying(_ step: EditStep, to document: EditDocument) throws -> EditDocument {
        let edited = try document.applying(step.changes)
        #expect(try edited.applying(step.changes.reversed().map(\.inverse)) == document)
        return edited
    }

    /// The automatic blocks of `document` of `take`, as source seconds of that take.
    static func autos(_ document: EditDocument, of take: String) -> [ClosedRange<Double>] {
        document.zoom.regions.filter { $0.take == take && $0.origin == .auto }.map { region in
            region.start.seconds(since: base(take))...region.end.seconds(since: base(take))
        }
    }
}

/// "Regenerate Zooms" plans the automatic blocks of every take the sequence shows: the step of today, of one take, would
/// leave the other take's blocks as they were planned before (with other settings, or with the automatic zoom off).
@Test func regenerateKeepsEveryTakesBlocks() throws {
    let takes = [TwoTakes.take(TwoTakes.first), TwoTakes.take(TwoTakes.second)]
    let both = takes.map { ($0, TwoTakes.events[$0.id] ?? []) }
    let document = TwoTakes.document(takes)
    var settings = document.zoom.auto

    let planned = try TwoTakes.applying(ZoomCommands.regenerate(document, takes: both, settings: settings), to: document)
    #expect(TwoTakes.autos(planned, of: TwoTakes.first) == [4.5...6])
    #expect(TwoTakes.autos(planned, of: TwoTakes.second) == [9.5...11])
    // Each as its take alone plans it.
    for (take, events) in both {
        #expect(planned.zoom.regions.filter { $0.take == take.id } == AutoZoomPlanner.plan(take: take, events: events, document: document))
    }
    // A block of the user's in the second take stays.
    var edited = planned
    let user = ZoomRegion(
        id: "z-0000000c", take: TwoTakes.second, start: TwoTakes.at(TwoTakes.second, 15), end: TwoTakes.at(TwoTakes.second, 17),
        origin: .user, depth: 1.6, focus: .follow, instant: false)
    edited.zoom.regions.append(user)

    // A second earlier: both takes' blocks move; one take's step would leave the other's where they were.
    settings.leadIn = 1.0
    let again = try TwoTakes.applying(ZoomCommands.regenerate(edited, takes: both, settings: settings), to: edited)
    #expect(TwoTakes.autos(again, of: TwoTakes.first) == [4...6])
    #expect(TwoTakes.autos(again, of: TwoTakes.second) == [9...11])
    #expect(again.zoom.regions.contains(user))
    let oneTake = try edited.applying(ZoomCommands.regenerate(edited, take: takes[0], events: both[0].1, settings: settings).changes)
    #expect(TwoTakes.autos(oneTake, of: TwoTakes.second) == [9.5...11])
    // Nothing changed, nothing to change.
    #expect(ZoomCommands.regenerate(again, takes: both, settings: settings).changes.isEmpty)

    // Off: every take's automatic blocks go, the user's stays.
    settings.enabled = false
    let off = try TwoTakes.applying(ZoomCommands.regenerate(again, takes: both, settings: settings), to: again)
    #expect(off.zoom.regions == [user])
    #expect(!(try again.applying(ZoomCommands.regenerate(again, take: takes[0], events: both[0].1, settings: settings).changes))
        .zoom.regions.filter { $0.origin == .auto }.isEmpty)
}

/// "Follow the Cursor" plans the screens of every take the sequence shows, each from its own pointer, around the user's
/// changes of each.
@Test func followCursorPlansEveryTake() throws {
    try withTemporaryDirectory { directory in
        let takes = [TwoTakes.take(TwoTakes.first), TwoTakes.take(TwoTakes.second)]
        let projects = try TwoTakes.projects(in: directory, takes, events: TwoTakes.events)
        var document = TwoTakes.document(takes)
        // A stale automatic change of the first take, and the user's display-2 from 15 s of the second.
        let stale = ScreenChange(id: "p-00000001", take: TwoTakes.first, t: TwoTakes.at(TwoTakes.first, 10), track: "display-2", origin: .auto)
        let user = ScreenChange(id: "p-00000002", take: TwoTakes.second, t: TwoTakes.at(TwoTakes.second, 15), track: "display-2", origin: .user)
        document.screens.changes = [stale, user]

        let step = TrackCommands.followCursor(document, projects: projects)
        #expect(step.label == .screen)
        #expect(step.target == "/screens")
        let edited = try TwoTakes.applying(step, to: document)
        #expect(edited.screens.initial == [TwoTakes.first: "display-1", TwoTakes.second: "display-1"])
        #expect(edited.screens.planner == ScreenFollowPlanner.id)
        func changes(of take: String) -> [String] {
            edited.screens.changes.filter { $0.take == take }.sorted { $0.t < $1.t }.map {
                "\($0.t.seconds(since: TwoTakes.base(take))) \($0.track) \($0.origin.rawValue)"
            }
        }
        // Back on display-1 at each take's click, there.
        #expect(changes(of: TwoTakes.first) == ["3.0 display-2 auto", "5.0 display-1 auto"])
        #expect(changes(of: TwoTakes.second) == ["8.0 display-2 auto", "10.0 display-1 auto", "15.0 display-2 user"])
        // Each take as its own step plans it, one after the other.
        let firstAlone = try document.applying(TrackCommands.followCursor(document, project: projects[0]).changes)
        let thenSecond = try firstAlone.applying(TrackCommands.followCursor(firstAlone, project: projects[1]).changes)
        #expect(thenSecond.screens == edited.screens)
        // One take's step leaves the other's screens as they were.
        #expect(firstAlone.screens.changes.filter { $0.take == TwoTakes.second } == [user])
        // Again, nothing changes.
        #expect(TrackCommands.followCursor(edited, projects: projects).changes.isEmpty)
    }
}

/// "Apply" a style over two takes, the second of a window that recorded its cursor's images: the style's values (its
/// corners too: "Apply" copies them, 1c design §8, and never grows them to cover a window, as with one take), the cursor
/// drawn from the recorded images, and the automatic blocks of both takes planned again for the document so styled.
@Test func applyingAStyleCoversEveryTake() throws {
    let window = TwoTakes.take(TwoTakes.second, tracks: [TwoTakes.window(of: TwoTakes.second)])
    let takes = [TwoTakes.take(TwoTakes.first), window]
    let image = InputEvent(
        t: TwoTakes.at(TwoTakes.second, 1),
        kind: .cursorImage(hash: String(repeating: "a", count: 32), hotspot: SIMD2(0.1, 0.1), size: SIMD2(16, 16), kind: nil))
    let events = [
        TwoTakes.first: TwoTakes.click(TwoTakes.first, 5),
        TwoTakes.second: TwoTakes.click(TwoTakes.second, 10, x: 700, y: 480) + [image],
    ]
    let both = takes.map { ($0, events[$0.id] ?? []) }
    var document = TwoTakes.document(takes)
    document.style.cornerRadius = 0.04
    var style = DefaultStyle.toma
    style.style.cornerRadius = 0.005

    let step = try #require(StyleCommands.applyDefaultStyle(document, style, takes: both))
    #expect(step.label == .applyDefaultStyle)
    #expect(step.target == "/style")
    let edited = try TwoTakes.applying(step, to: document)
    #expect(edited.cursor.style == .system)
    #expect(edited.style.cornerRadius == 0.005)
    #expect(TwoTakes.autos(edited, of: TwoTakes.first) == [4.5...6])
    #expect(TwoTakes.autos(edited, of: TwoTakes.second).count == 1)
    var unplanned = edited
    unplanned.zoom.regions = []
    #expect(edited.zoom.regions.filter { $0.take == TwoTakes.second }
        == AutoZoomPlanner.plan(take: window, events: both[1].1, document: unplanned))
    // One take's step plans that take's alone, and draws Toma's arrow: the first take recorded no images.
    let oneTake = try document.applying(try #require(
        StyleCommands.applyDefaultStyle(document, style, take: takes[0], events: both[0].1)).changes)
    #expect(oneTake.cursor.style == .toma)
    #expect(TwoTakes.autos(oneTake, of: TwoTakes.second).isEmpty)

    // A named style: its camera's look too, and the same blocks.
    let named = NamedStyle(id: "s-00000001", name: "Mine", look: style, camera: .newProjects)
    let applied = try TwoTakes.applying(try #require(StyleCommands.applyStyle(document, named, takes: both)), to: document)
    #expect(applied.zoom.regions == edited.zoom.regions)
    #expect(applied.cursor == edited.cursor)
    #expect(applied.camera.shadow == CameraLook.newProjects.shadow)
    #expect(StyleCommands.applyStyle(applied, named, takes: both) == nil)
}

/// With one take, each command over every take is the step of today, change for change: in 16:9 and in "Like the
/// Recording", over all of the take and over two clips of it, with blocks of the user's and screens changed.
@Test func oneTakeIsThePhase2Step() throws {
    try withTemporaryDirectory { directory in
        let take = TwoTakes.take(TwoTakes.first)
        let events = TwoTakes.events[TwoTakes.first] ?? []
        let one = [(take, events)]
        let project = try #require(try TwoTakes.projects(in: directory, [take], events: TwoTakes.events).first)
        let images = events + [InputEvent(
            t: TwoTakes.at(TwoTakes.first, 1),
            kind: .cursorImage(hash: String(repeating: "b", count: 32), hotspot: SIMD2(0.1, 0.1), size: SIMD2(16, 16), kind: nil))]
        let named = NamedStyle(id: "s-00000002", name: "Mine", look: .toma, camera: .newProjects)

        for aspect in [Aspect.landscape, .auto] {
            for sequence in [[TwoTakes.clip(1, TwoTakes.first, 0, 60)], [TwoTakes.clip(1, TwoTakes.first, 0, 8), TwoTakes.clip(2, TwoTakes.first, 9, 30)]] {
                var document = TwoTakes.document([take], sequence: sequence)
                document.aspect = aspect
                document.screens.changes = [
                    ScreenChange(id: "p-00000001", take: TwoTakes.first, t: TwoTakes.at(TwoTakes.first, 20), track: "display-2", origin: .user)
                ]
                document.zoom.regions = [ZoomRegion(
                    id: "z-0000000c", take: TwoTakes.first, start: TwoTakes.at(TwoTakes.first, 12),
                    end: TwoTakes.at(TwoTakes.first, 14), origin: .user, depth: 1.6, focus: .follow, instant: false)]
                var settings = document.zoom.auto
                for leadIn in [settings.leadIn, 1.0] {
                    settings.leadIn = leadIn
                    #expect(ZoomCommands.regenerate(document, takes: one, settings: settings)
                        == ZoomCommands.regenerate(document, take: take, events: events, settings: settings))
                }
                #expect(TrackCommands.followCursor(document, projects: [project]) == TrackCommands.followCursor(document, project: project))
                for withImages in [events, images] {
                    #expect(StyleCommands.applyDefaultStyle(document, .toma, takes: [(take, withImages)])
                        == StyleCommands.applyDefaultStyle(document, .toma, take: take, events: withImages))
                    #expect(StyleCommands.applyStyle(document, named, takes: [(take, withImages)])
                        == StyleCommands.applyStyle(document, named, take: take, events: withImages))
                }
            }
        }
    }
}

/// The camera's analysis of every take the sequence shows: the masks and the faces of each in the caches, each under
/// its own take, none emptying another's; with one take, what that take's gives.
@Test func cameraAnalysisOfEveryTake() throws {
    try withTemporaryDirectory { directory in
        let takes = [TwoTakes.take(TwoTakes.first), TwoTakes.take(TwoTakes.second)]
        let projects = try TwoTakes.projects(in: directory, takes, events: TwoTakes.events)
        let package = projects[0].package
        let caches = ProjectCaches(root: directory.appending(path: "Caches", directoryHint: .isDirectory), projectID: "p")
        var document = TwoTakes.document(takes)
        document.camera.background = .blurred
        var masks: [CameraSegment: URL] = [:]
        for take in takes {
            let segment = try #require(take.track("camera")?.segments.first)
            let identity = try #require(SegmentIdentity.of(segment, in: package))
            let url = try #require(CameraAnalysisCaches.maskFile(take: take.id, track: "camera", identity: identity, caches: caches))
            #expect(ProjectCaches.writeAnalysis(Data("mask".utf8), to: url))
            masks[CameraSegment(take: take.id, track: "camera", segment: segment.index)] = url
        }

        var inputs = AnalysisInputs()
        CameraAnalysisCaches.fill(&inputs, document: document, takes: takes + [takes[0]], package: package, caches: caches)
        #expect(inputs.personMasks == masks)
        #expect(inputs.faceTracks.isEmpty)
        // One take's own fill keeps only its masks.
        var first = AnalysisInputs(), alone = AnalysisInputs()
        CameraAnalysisCaches.fill(&first, document: document, take: takes[0], package: package, caches: caches)
        #expect(first.personMasks.keys.map(\.take) == [TwoTakes.first])
        CameraAnalysisCaches.fill(&alone, document: document, takes: [takes[0]], package: package, caches: caches)
        #expect(alone == first)
        // Original reads no mask, of either take.
        document.camera.background = .original
        CameraAnalysisCaches.fill(&inputs, document: document, takes: takes, package: package, caches: caches)
        #expect(inputs.personMasks.isEmpty)
    }
}

// MARK: - The output's stage

/// Takes of screens of other proportions in "Like the Recording" (phase 3 design §9): what is planned for a take that is
/// not the first clip's is planned on the output's stage, the first clip's take's, where it is drawn.
private enum Proportions {
    /// A take of one display (or one window) of `width` × 900 pt from the take's start, as `TwoTakes` records them.
    static func take(_ id: String, width: Double, window: Bool = false) -> TakeRecord {
        let track = window ? "window-1" : "display-1"
        return TwoTakes.take(id, tracks: [TrackRecord(
            id: track, kind: window ? .window : .display,
            source: window
                ? TrackSource(name: "Window", globalFrame: Rect(x: 100, y: 80, width: width, height: 900), pixelScale: 2, windowID: 7)
                : TrackSource(name: "Display", displayID: 1, globalFrame: Rect(x: 0, y: 0, width: width, height: 900), pixelScale: 2),
            segments: [TwoTakes.segment(id, track)])])
    }

    /// Two clicks 800 pt apart across the screen, 0.6 s apart, from `seconds` of the take: a wide box, whose zoom fits
    /// the stage it is planned on.
    static func clicks(_ take: String, _ seconds: Double, left: Double, y: Double) -> [InputEvent] {
        TwoTakes.click(take, seconds, x: left, y: y) + TwoTakes.click(take, seconds + 0.6, x: left + 800, y: y)
    }

    /// The document of `take` alone over `[0–20]`, in `aspect`.
    static func alone(_ take: TakeRecord, aspect: Aspect) -> EditDocument {
        var document = TwoTakes.document([take], sequence: [TwoTakes.clip(1, take.id, 0, 20)])
        document.aspect = aspect
        return document
    }

    /// `c-00000010`, `c-00000011`… as it is asked.
    final class IDs {
        private var next = 0x10

        func make(_ prefix: String) -> String {
            defer { next += 1 }
            return prefix + String(format: "%08x", next)
        }
    }
}

/// "Regenerate Zooms" over a 16:9 take and a 4:3 one, in both orders: the blocks of the take that is not the first are
/// those of that take alone in a document of the first's shape, never those of its own shape; the first's are its own.
@Test func autoZoomOfEveryTakeFitsTheOutputsStage() throws {
    let wide = Proportions.take(TwoTakes.first, width: 1600), narrow = Proportions.take(TwoTakes.second, width: 1200)
    let events = [
        TwoTakes.first: Proportions.clicks(TwoTakes.first, 5, left: 400, y: 450),
        TwoTakes.second: Proportions.clicks(TwoTakes.second, 10, left: 200, y: 450),
    ]
    let shapes: [String: Aspect] = [TwoTakes.first: .landscape, TwoTakes.second: .fourByThree]
    for (first, second) in [(wide, narrow), (narrow, wide)] {
        var document = TwoTakes.document(
            [first, second], sequence: [TwoTakes.clip(1, first.id, 0, 20), TwoTakes.clip(2, second.id, 0, 20)])
        document.aspect = .auto
        let takes = [first, second].map { ($0, events[$0.id] ?? []) }
        let edited = try TwoTakes.applying(ZoomCommands.regenerate(document, takes: takes, settings: document.zoom.auto), to: document)

        let output = try #require(shapes[first.id]), own = try #require(shapes[second.id])
        let reference = AutoZoomPlanner.plan(take: second, events: takes[1].1, document: Proportions.alone(second, aspect: output))
        #expect(!reference.isEmpty)
        #expect(edited.zoom.regions.filter { $0.take == second.id } == reference, "\(first.id) first")
        // On its own shape, the blocks would be others: the depth that fits the box is not the same.
        #expect(AutoZoomPlanner.plan(take: second, events: takes[1].1, document: Proportions.alone(second, aspect: own)) != reference)
        // The first take's, on its own stage.
        #expect(edited.zoom.regions.filter { $0.take == first.id }
            == AutoZoomPlanner.plan(take: first, events: takes[0].1, document: Proportions.alone(first, aspect: output)))
        // Applying a style plans them the same way.
        let styled = try TwoTakes.applying(try #require(StyleCommands.applyDefaultStyle(document, .toma, takes: takes)), to: document)
        var unplanned = styled
        unplanned.zoom.regions = []
        unplanned.sequence = [TwoTakes.clip(2, second.id, 0, 20)]
        unplanned.aspect = output
        #expect(styled.zoom.regions.filter { $0.take == second.id }
            == AutoZoomPlanner.plan(take: second, events: takes[1].1, document: unplanned), "\(first.id) first")
    }
}

/// A 4:3 window take added to the end of a 16:9 one in "Like the Recording" (`TakeCommands`): its automatic blocks are
/// planned on the 16:9 stage, and its corners cover 26 pt of the window as the 16:9 output draws it, not as a 4:3 one
/// would.
@Test func aNewTakeIsPlannedOnTheOutputsStage() throws {
    try withTemporaryDirectory { directory in
        let wide = Proportions.take(TwoTakes.first, width: 1600)
        let window = Proportions.take(TwoTakes.second, width: 1200, window: true)
        let events = [
            TwoTakes.first: TwoTakes.click(TwoTakes.first, 5, x: 800, y: 450),
            TwoTakes.second: Proportions.clicks(TwoTakes.second, 10, left: 300, y: 500),
        ]
        let projects = try TwoTakes.projects(in: directory, [wide, window], events: events)
        var document = TwoTakes.document([wide], sequence: [TwoTakes.clip(1, TwoTakes.first, 0, 20)])
        document.aspect = .auto
        document.style.cornerRadius = 0.001

        let step = try #require(TakeCommands.appendToEnd(document, take: projects[1], makeID: Proportions.IDs().make))
        let edited = try TwoTakes.applying(step, to: document)
        #expect(edited.sequence.map(\.take) == [TwoTakes.first, TwoTakes.second])
        // Alone in a 16:9 document of its clips.
        var alone = edited
        alone.sequence = edited.sequence.filter { $0.take == TwoTakes.second }
        alone.aspect = .landscape
        alone.zoom.regions = []
        let reference = AutoZoomPlanner.plan(take: window, events: events[TwoTakes.second] ?? [], document: alone)
        #expect(!reference.isEmpty)
        #expect(edited.zoom.regions.filter { $0.take == TwoTakes.second } == reference)
        var square = alone
        square.aspect = .fourByThree
        #expect(AutoZoomPlanner.plan(take: window, events: events[TwoTakes.second] ?? [], document: square) != reference)

        // The corners: 26 of the window's 1200 pt, in the rect the 16:9 stage gives it.
        let start = TwoTakes.at(TwoTakes.second, 0)
        func cover(_ document: EditDocument) throws -> Double {
            let stage = StagePoints(take: window, events: [], document: document)
            let rect = try #require(stage.screenRect(at: start))
            return WindowCornerCover.cornerRadius(
                windowWidthPoints: 1200, screenRectWidth: rect.width, outputWidth: stage.stageSize.x)
        }
        #expect(abs(edited.style.cornerRadius - (try cover(alone))) <= 1e-12)
        #expect(try cover(square) > (try cover(alone)) + 1e-4)
    }
}

/// Clicks less than the lead from the cut between the two takes (T10's finding): "Regenerate Zooms" keeps a block of each
/// take, cut at the border, and never deletes the ones there; "Add to End" brings the new take's.
@Test func blocksAtTheBorderBetweenTakesStay() throws {
    try withTemporaryDirectory { directory in
        let takes = [TwoTakes.take(TwoTakes.first), TwoTakes.take(TwoTakes.second)]
        let events = [TwoTakes.first: TwoTakes.click(TwoTakes.first, 19.6), TwoTakes.second: TwoTakes.click(TwoTakes.second, 0.3)]
        let both = takes.map { ($0, events[$0.id] ?? []) }
        let document = TwoTakes.document(takes)
        let edited = try TwoTakes.applying(ZoomCommands.regenerate(document, takes: both, settings: document.zoom.auto), to: document)
        #expect(TwoTakes.autos(edited, of: TwoTakes.first) == [19.1...20])
        #expect(TwoTakes.autos(edited, of: TwoTakes.second) == [0...1.3])
        // Again: nothing goes.
        #expect(ZoomCommands.regenerate(edited, takes: both, settings: edited.zoom.auto).changes.isEmpty)

        // The second take added after the first: its block at its start.
        let projects = try TwoTakes.projects(in: directory, takes, events: events)
        var first = TwoTakes.document([takes[0]], sequence: [TwoTakes.clip(1, TwoTakes.first, 0, 20)])
        first.zoom.regions = AutoZoomPlanner.plan(take: takes[0], events: both[0].1, document: first)
        let step = try #require(TakeCommands.appendToEnd(first, take: projects[1], makeID: Proportions.IDs().make))
        let appended = try TwoTakes.applying(step, to: first)
        #expect(TwoTakes.autos(appended, of: TwoTakes.second) == [0...1.3])
        #expect(TwoTakes.autos(appended, of: TwoTakes.first) == [19.1...20])
    }
}
