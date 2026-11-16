// SPDX-License-Identifier: GPL-3.0-or-later
import Analysis
import Foundation
import RecorderKitTestSupport
import Testing
// Not @testable: the app uses only the public API.
import Editing
import ProjectFormat

/// The fixture of the camera and screen commands' tests, namespaced so that no other file of EditingTests meets its
/// names: a take of two displays side by side, `display-1` (1440 × 900 pt at the origin) and `display-2` (1920 × 1080 pt
/// to its right), recorded for 60 s from `base`, and a document of one clip over all of it at 1×, so an output second is
/// a source second after `base`.
private enum TrackFixture {
    static let takeID = "take-001"
    static let base = HostTime(nanoseconds: 5_000_000_000_000)
    static let frame1 = Rect(x: 0, y: 0, width: 1440, height: 900)
    static let frame2 = Rect(x: 1440, y: 0, width: 1920, height: 1080)

    static func at(_ seconds: Double) -> HostTime { base.adding(seconds: seconds) }

    static func output(_ seconds: Double) -> Int64 { TimeMap.outputNanoseconds(seconds: seconds) }

    static func display(_ number: Int, frame: Rect) -> TrackRecord {
        let id = "display-\(number)"
        return TrackRecord(
            id: id, kind: .display,
            source: TrackSource(name: "Display \(number)", displayID: UInt32(number), globalFrame: frame, pixelScale: 2),
            segments: [
                SegmentRecord(
                    index: 1, file: "takes/\(takeID)/\(id)/seg-0001.mov", startHostTime: base, endHostTime: at(60),
                    endReason: .stopped, droppedFrames: 0, heartbeatFrames: 0)
            ])
    }

    static let take = TakeRecord(
        id: takeID, status: .complete, startedAt: Date(timeIntervalSince1970: 1_800_000_000),
        tracks: [display(1, frame: frame1), display(2, frame: frame2)])

    static let fullClip = [Clip(id: "c-00000001", take: takeID, start: base, end: at(60), speed: 1)]

    static func document(
        camera: [CameraChange] = [], screens: [ScreenChange] = [], sequence: [Clip] = fullClip
    ) -> EditDocument {
        var document = EditDocument.legacy(take: take, events: [])
        document.sequence = sequence
        document.camera = CameraPlan(show: true, initial: [takeID: .default], changes: camera)
        document.screens = ScreenPlan(initial: [takeID: "display-1"], changes: screens)
        return document
    }

    static func cameraChange(_ id: String, at seconds: Double, _ style: CameraStyle, origin: CameraOrigin = .recorded) -> CameraChange {
        CameraChange(id: id, take: takeID, t: at(seconds), style: style, origin: origin)
    }

    static func screenChange(_ id: String, at seconds: Double, _ track: String, origin: Origin = .auto) -> ScreenChange {
        ScreenChange(id: id, take: takeID, t: at(seconds), track: track, origin: origin)
    }

    static let small = CameraStyle(shape: .roundedSquare, size: CameraStyle.small, anchor: .topLeading)
    static let large = CameraStyle(shape: .portrait, size: CameraStyle.large, anchor: .bottom)

    /// `document` with `step` applied, checking on the way that its inverse gives `document` back.
    static func applying(_ step: EditStep, to document: EditDocument) throws -> EditDocument {
        let edited = try document.applying(step.changes)
        #expect(try edited.applying(step.changes.reversed().map(\.inverse)) == document)
        return edited
    }

    /// The screen shown from each change on, in time order: (seconds after `base`, track, origin).
    static func screens(_ document: EditDocument) -> [String] {
        document.screens.changes.sorted { $0.t < $1.t }.map { change in
            "\(Double(change.t.nanoseconds - base.nanoseconds) / 1e9) \(change.track) \(change.origin.rawValue)"
        }
    }

    /// What `TrackCommands.rulingCameraStyle` gives.
    struct Ruling: Equatable {
        var changeID: String?
        var style: CameraStyle
    }

    /// The style that rules at `seconds` of output.
    static func ruling(_ document: EditDocument, at seconds: Double, _ map: TimeMap) -> Ruling {
        let ruling = TrackCommands.rulingCameraStyle(document, atOutput: output(seconds), timeMap: map)
        return Ruling(changeID: ruling.changeID, style: ruling.style)
    }

    /// `p-00000010`, `p-00000011`… as it is asked.
    final class IDs {
        private var next = 0x10

        func make(_ prefix: String) -> String {
            defer { next += 1 }
            return prefix + String(format: "%08x", next)
        }
    }

    /// The pointer in the middle of display `screen` (1 or 2) `seconds` after `base`.
    static func pointer(_ seconds: Double, on screen: Int) -> InputEvent {
        let frame = screen == 1 ? frame1 : frame2
        return InputEvent(t: at(seconds), kind: .cursor(x: frame.x + frame.width / 2, y: frame.y + frame.height / 2))
    }

    /// The take in a package of `directory` where each segment file is written, a byte each: so the planner counts them.
    static func project(in directory: URL, events: [InputEvent]) throws -> LoadedProject {
        let package = ProjectPackage(url: directory.appending(path: "Follow.toma", directoryHint: .isDirectory))
        for track in take.tracks {
            for segment in track.segments {
                let url = package.fileURL(segment.file)
                try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
                try Data([0x2A]).write(to: url)
            }
        }
        let manifest = Manifest(
            formatVersion: 3, app: AppInfo(name: "Toma", version: "0.2.0"), createdAt: Date(timeIntervalSince1970: 1_800_000_000),
            takes: [take])
        return LoadedProject(package: package, manifest: manifest, take: take, events: events)
    }
}

// MARK: - The camera

@Test func cameraEditAtThePlayheadEditsTheRulingStyle() throws {
    let change = TrackFixture.cameraChange("k-00000001", at: 5, TrackFixture.small)
    let document = TrackFixture.document(camera: [change])
    let map = TimeMap(sequence: document.sequence)
    #expect(TrackFixture.ruling(document, at: 3, map) == TrackFixture.Ruling(changeID: nil, style: .default))
    #expect(TrackFixture.ruling(document, at: 5, map) == TrackFixture.Ruling(changeID: "k-00000001", style: TrackFixture.small))

    // Before the first change: the initial style.
    let before = try #require(
        TrackCommands.setCameraStyle(document, atOutput: TrackFixture.output(3), timeMap: map, TrackFixture.large))
    #expect(before.label == .camera)
    #expect(before.changes == [try #require(document.setChange("/camera/initial/take-001", TrackFixture.large))])
    #expect(try TrackFixture.applying(before, to: document).camera.initial == [TrackFixture.takeID: TrackFixture.large])

    // After it: that change, which is the user's now.
    let after = try #require(
        TrackCommands.setCameraStyle(document, atOutput: TrackFixture.output(6), timeMap: map, TrackFixture.large))
    #expect(after.target == "k-00000001")
    var touched = change
    touched.style = TrackFixture.large
    touched.origin = .user
    #expect(after.changes == [try #require(document.replaceChange(.cameraChanges, id: change.id, with: touched))])
    #expect(try TrackFixture.applying(after, to: document).camera.changes == [touched])

    // The style it has already is no step; a size is kept from 0.10 to 0.45 of the output's height.
    #expect(TrackCommands.setCameraStyle(document, atOutput: TrackFixture.output(6), timeMap: map, TrackFixture.small) == nil)
    var huge = TrackFixture.large
    huge.size = 2
    let clamped = try #require(TrackCommands.setCameraStyle(document, atOutput: TrackFixture.output(1), timeMap: map, huge))
    #expect(try TrackFixture.applying(clamped, to: document).camera.initial[TrackFixture.takeID]?.size == 0.45)
}

@Test func deletingACameraChangeLetsThePreviousRule() throws {
    let first = TrackFixture.cameraChange("k-00000001", at: 2, TrackFixture.small)
    let second = TrackFixture.cameraChange("k-00000002", at: 5, TrackFixture.large)
    let document = TrackFixture.document(camera: [first, second])
    let map = TimeMap(sequence: document.sequence)
    #expect(TrackFixture.ruling(document, at: 6, map) == TrackFixture.Ruling(changeID: "k-00000002", style: TrackFixture.large))
    let step = try #require(TrackCommands.deleteCameraChange(document, id: "k-00000002"))
    #expect(step.label == .camera)
    #expect(step.changes == [try #require(document.removeChange(.cameraChanges, at: 1))])
    let edited = try TrackFixture.applying(step, to: document)
    #expect(TrackFixture.ruling(edited, at: 6, map) == TrackFixture.Ruling(changeID: "k-00000001", style: TrackFixture.small))
    #expect(TrackCommands.deleteCameraChange(edited, id: "k-00000002") == nil)
}

@Test func cameraChangesAreAddedAndMovedAtThePlayhead() throws {
    let first = TrackFixture.cameraChange("k-00000001", at: 2, TrackFixture.small)
    let second = TrackFixture.cameraChange("k-00000002", at: 5, TrackFixture.large)
    let document = TrackFixture.document(camera: [first, second])
    let map = TimeMap(sequence: document.sequence)
    // Added at 3 s with the style that rules there, between the two in time order.
    let add = try #require(
        TrackCommands.addCameraChange(document, atOutput: TrackFixture.output(3), timeMap: map, makeID: TrackFixture.IDs().make))
    let added = CameraChange(
        id: "k-00000010", take: TrackFixture.takeID, t: TrackFixture.at(3), style: TrackFixture.small, origin: .user)
    #expect(add.target == added.id)
    #expect(add.changes == [document.insertChange(.cameraChanges, at: 1, added)])
    let edited = try TrackFixture.applying(add, to: document)
    #expect(TrackFixture.ruling(edited, at: 4, map) == TrackFixture.Ruling(changeID: "k-00000010", style: TrackFixture.small))
    // One is there already.
    #expect(TrackCommands.addCameraChange(document, atOutput: TrackFixture.output(5), timeMap: map, makeID: TrackFixture.IDs().make) == nil)

    // Dragged in time, it is the user's.
    let move = try #require(TrackCommands.moveCameraChange(document, id: first.id, toOutput: TrackFixture.output(7), timeMap: map))
    var moved = first
    moved.t = TrackFixture.at(7)
    moved.origin = .user
    #expect(move.changes == [try #require(document.replaceChange(.cameraChanges, id: first.id, with: moved))])
    let later = try TrackFixture.applying(move, to: document)
    #expect(TrackFixture.ruling(later, at: 6, map) == TrackFixture.Ruling(changeID: "k-00000002", style: TrackFixture.large))
    #expect(TrackFixture.ruling(later, at: 8, map) == TrackFixture.Ruling(changeID: "k-00000001", style: TrackFixture.small))
    #expect(TrackCommands.moveCameraChange(document, id: first.id, toOutput: TrackFixture.output(2), timeMap: map) == nil)
    #expect(TrackCommands.moveCameraChange(document, id: first.id, toOutput: TrackFixture.output(5), timeMap: map) == nil)

    let hide = try #require(TrackCommands.setCameraShow(document, false))
    #expect(hide.changes == [try #require(document.setChange("/camera/show", false))])
    #expect(TrackCommands.setCameraShow(document, true) == nil)
}

@Test func theRulingCameraStyleIsTheSourceInstantsInACutSequence() throws {
    // The source from 10 s to 20 s is cut, and a change at 15 s rules from output 10 s, the start of the second clip.
    let sequence = [
        Clip(id: "c-00000001", take: TrackFixture.takeID, start: TrackFixture.base, end: TrackFixture.at(10), speed: 1),
        Clip(id: "c-00000002", take: TrackFixture.takeID, start: TrackFixture.at(20), end: TrackFixture.at(60), speed: 1),
    ]
    let document = TrackFixture.document(camera: [TrackFixture.cameraChange("k-00000001", at: 15, TrackFixture.small)], sequence: sequence)
    let map = TimeMap(sequence: sequence)
    #expect(TrackFixture.ruling(document, at: 9.9, map) == TrackFixture.Ruling(changeID: nil, style: .default))
    #expect(TrackFixture.ruling(document, at: 10, map) == TrackFixture.Ruling(changeID: "k-00000001", style: TrackFixture.small))
}

// MARK: - The screens

@Test func screenBoundaryMoveMakesItUser() throws {
    let change = TrackFixture.screenChange("p-00000001", at: 3, "display-2")
    let document = TrackFixture.document(screens: [change, TrackFixture.screenChange("p-00000002", at: 6, "display-1")])
    let map = TimeMap(sequence: document.sequence)
    let step = try #require(TrackCommands.moveScreenBoundary(document, changeID: change.id, toOutput: TrackFixture.output(4), timeMap: map))
    #expect(step.label == .screen)
    #expect(step.target == change.id)
    var moved = change
    moved.t = TrackFixture.at(4)
    moved.origin = .user
    #expect(step.changes == [try #require(document.replaceChange(.screenChanges, id: change.id, with: moved))])
    _ = try TrackFixture.applying(step, to: document)
    // It stops before the next boundary and after the one before; where it is, nothing.
    let far = try #require(TrackCommands.moveScreenBoundary(document, changeID: change.id, toOutput: TrackFixture.output(9), timeMap: map))
    #expect(try TrackFixture.applying(far, to: document).screens.changes.first?.t == HostTime(nanoseconds: TrackFixture.at(6).nanoseconds - 1))
    let back = try #require(
        TrackCommands.moveScreenBoundary(document, changeID: "p-00000002", toOutput: TrackFixture.output(1), timeMap: map))
    #expect(try TrackFixture.applying(back, to: document).screens.changes.last?.t == HostTime(nanoseconds: TrackFixture.at(3).nanoseconds + 1))
    #expect(TrackCommands.moveScreenBoundary(document, changeID: change.id, toOutput: TrackFixture.output(3), timeMap: map) == nil)
    #expect(TrackCommands.moveScreenBoundary(document, changeID: "p-ffffffff", toOutput: 0, timeMap: map) == nil)
}

@Test func showingAScreenForAStretchKeepsWhatComesAfter() throws {
    let document = TrackFixture.document(screens: [TrackFixture.screenChange("p-00000001", at: 10, "display-2")])
    let map = TimeMap(sequence: document.sequence)
    func shown(_ track: String, _ from: Double, _ to: Double) throws -> [String]? {
        let range = TrackFixture.output(from)..<TrackFixture.output(to)
        guard let step = TrackCommands.showScreen(document, track: track, forOutput: range, timeMap: map, makeID: TrackFixture.IDs().make)
        else { return nil }
        #expect(step.label == .screen)
        return TrackFixture.screens(try TrackFixture.applying(step, to: document))
    }
    // Inside the first stretch: display-2 from 3 s, display-1 again from 6 s.
    #expect(try shown("display-2", 3, 6) == ["3.0 display-2 user", "6.0 display-1 user", "10.0 display-2 auto"])
    // Up to the change: it moves to the stretch's start, and the user's.
    #expect(try shown("display-2", 4, 10) == ["4.0 display-2 user"])
    // The whole last stretch shows what the one before it shows: the change goes.
    #expect(try shown("display-1", 10, 60) == [])
    // Inside the last stretch.
    #expect(try shown("display-1", 12, 20) == ["10.0 display-2 auto", "12.0 display-1 user", "20.0 display-2 user"])
    // From the start: a change at the take's first instant, so the initial screen stays the planner's.
    #expect(try shown("display-2", 0, 2) == ["0.0 display-2 user", "2.0 display-1 user", "10.0 display-2 auto"])
    // What is shown there already.
    #expect(try shown("display-1", 3, 6) == nil)
    #expect(try shown("display-2", 10, 60) == nil)
}

@Test func followCursorRegeneratesTheAutomaticChangesAroundTheUsers() throws {
    try withTemporaryDirectory { directory in
        // The pointer on display-2 from 3 s to 5 s, from 20 s to 30 s and from 40 s on.
        let events = [
            TrackFixture.pointer(0, on: 1), TrackFixture.pointer(3, on: 2), TrackFixture.pointer(5, on: 1),
            TrackFixture.pointer(20, on: 2), TrackFixture.pointer(30, on: 1), TrackFixture.pointer(40, on: 2),
        ]
        let project = try TrackFixture.project(in: directory, events: events)
        // The source from 2.9 s to 5.1 s is cut: the stay on display-2 there is not in the output.
        let sequence = [
            Clip(id: "c-00000001", take: TrackFixture.takeID, start: TrackFixture.base, end: TrackFixture.at(2.9), speed: 1),
            Clip(id: "c-00000002", take: TrackFixture.takeID, start: TrackFixture.at(5.1), end: TrackFixture.at(60), speed: 1),
        ]
        // A stale automatic change at 10 s, and the user's display-1 from 25 s and display-2 from 45 s.
        var document = TrackFixture.document(
            screens: [
                TrackFixture.screenChange("p-00000001", at: 10, "display-2"),
                TrackFixture.screenChange("p-00000002", at: 25, "display-1", origin: .user),
                TrackFixture.screenChange("p-00000003", at: 45, "display-2", origin: .user),
            ], sequence: sequence)
        document.screens.initial = [TrackFixture.takeID: "display-2"]
        #expect(document.screens.planner == nil)

        let planned = ScreenFollowPlanner.plan(
            take: project.take, events: events, package: project.package, timeMap: TimeMap(sequence: sequence))
        #expect(planned.changes.map(\.t) == [TrackFixture.at(20), TrackFixture.at(30), TrackFixture.at(40)])

        let step = TrackCommands.followCursor(document, project: project)
        #expect(step.label == .screen)
        let edited = try TrackFixture.applying(step, to: document)
        // The planner's first screen; its change at 20 s; the user's at 25 s; at 30 s display-1 is shown already, so its
        // change goes; its change at 40 s, and the user's at 45 s, where display-2 is shown already, stays.
        #expect(edited.screens.initial == [TrackFixture.takeID: "display-1"])
        #expect(edited.screens.planner == ScreenFollowPlanner.id)
        #expect(TrackFixture.screens(edited) == ["20.0 display-2 auto", "25.0 display-1 user", "40.0 display-2 auto", "45.0 display-2 user"])
        #expect(edited.screens.changes.filter { $0.origin == .auto } == [planned.changes[0], planned.changes[2]])
        // Again, nothing changes.
        #expect(TrackCommands.followCursor(edited, project: project).changes.isEmpty)
    }
}
