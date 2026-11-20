// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import RecorderKitTestSupport
import Synchronization
import Testing
// Not @testable: the app uses only the public API.
import Analysis
import Editing
import ProjectFormat

/// The takes (3d plan, Task T3; phase 3 design §8.1, §8.2 and §9): the list of the Takes menu, "Use from Here", "Add to
/// End" and the step of "Re-record from Here", each one step that keeps every take in order and leaves what is before the
/// playhead as it was. `MultiTakeFixtures.twoTakes`: `take-001` of 4 s and `take-002` of 3 s.
@Suite struct TakeCommandsTests {
    /// Ids from 1 for each prefix: `c-00000101`, `c-00000102`… as they are asked.
    private final class IDs: Sendable {
        private let counts = Mutex<[String: Int]>([:])

        func make(_ prefix: String) -> String {
            counts.withLock { counts in
                let count = counts[prefix, default: 0x100] + 1
                counts[prefix] = count
                return prefix + String(format: "%08x", count)
            }
        }
    }

    /// A clip of the sequence as the tests read it: its take and its source from and to, in ms from the start of the
    /// take's editable timeline; a clip with content, its point.
    private struct Piece: Equatable, CustomStringConvertible {
        var take: String
        var from: Int
        var to: Int
        var content = false

        var description: String { "\(take) \(from)–\(to)\(content ? " (content)" : "")" }
    }

    private static func piece(_ take: String, _ from: Double, _ to: Double, content: Bool = false) -> Piece {
        Piece(take: take, from: Int((from * 1000).rounded()), to: Int((to * 1000).rounded()), content: content)
    }

    /// The pieces of `document`'s sequence.
    private static func pieces(_ document: EditDocument, _ project: LoadedProject) -> [Piece] {
        document.sequence.map { clip in
            let start = TakeTimeline.editableBounds(
                take: project.focused(on: clip.take)?.take ?? project.take, events: project.events(ofTake: clip.take)
            ).start.nanoseconds
            func ms(_ t: HostTime) -> Int { Int((Double(Int64(t.nanoseconds) - Int64(start)) / 1e6).rounded()) }
            let end = clip.content == nil ? clip.end : clip.start
            return Piece(take: clip.take, from: ms(clip.start), to: ms(end), content: clip.content != nil)
        }
    }

    /// `seconds` of output, in ns.
    private static func output(_ seconds: Double) -> Int64 { TimeMap.outputNanoseconds(seconds: seconds) }

    /// `seconds` after the start of the editable timeline of `take`.
    private static func at(_ seconds: Double, of take: String, in project: LoadedProject) -> HostTime {
        let record = project.focused(on: take)?.take ?? project.take
        return TakeTimeline.editableBounds(take: record, events: project.events(ofTake: take)).start.adding(seconds: seconds)
    }

    private static func focused(_ project: LoadedProject, _ take: String) throws -> LoadedProject {
        try #require(project.focused(on: take))
    }

    /// `twoTakes` focused on `take-001`, as the editor has it before the second take is used: the documents of
    /// `MultiTakeFixtures.sequence(of:_:)` are the first take's, so `take-002` is new in them until a piece shows it.
    private static func firstTake(in dir: URL) async throws -> LoadedProject {
        try focused(try await MultiTakeFixtures.twoTakes(in: dir), "take-001")
    }

    /// `document` with `step` applied, checking on the way that its inverse gives `document` back.
    private static func applying(_ step: EditStep, to document: EditDocument) throws -> EditDocument {
        let edited = try document.applying(step.changes)
        #expect(try edited.applying(step.changes.reversed().map(\.inverse)) == document)
        return edited
    }

    private static let card = TitleCard(title: "Toma", style: .centered, background: .stage)

    /// A title card of `seconds` at the source second `point` of `take`.
    private static func card(_ id: String, at point: Double, of take: String, in project: LoadedProject, seconds: Double = 3) -> Clip {
        let t = at(point, of: take, in: project)
        return Clip(id: id, take: take, start: t, end: t, speed: 1, content: .card(card, duration: output(seconds)))
    }

    // MARK: - The list

    @Test func takesListNumberDateDurationAndUse() async throws {
        try await withTemporaryDirectory { dir in
            let project = try await Self.firstTake(in: dir)
            let document = MultiTakeFixtures.sequence(of: project, [("take-001", 0, 4)])
            let takes = TakeCommands.takes(of: project, document: document)
            #expect(takes.map(\.id) == ["take-001", "take-002"])
            #expect(takes.map(\.number) == [1, 2])
            #expect(takes.map(\.startedAt) == project.takes.map(\.startedAt))
            #expect(takes.map(\.duration) == [4_000_000_000, 3_000_000_000])
            #expect(takes.map(\.inUse) == [true, false])
            #expect(takes.map(\.isEmpty) == [false, false])

            // Both in use; a take of no span is empty.
            let later = Date(timeIntervalSince1970: 1_800_000_060)
            var manifest = project.manifest
            manifest.takes.append(TakeRecord(id: "take-003", status: .complete, startedAt: later, tracks: []))
            let three = LoadedProject(package: project.package, manifest: manifest, take: project.take, events: project.events)
            let both = MultiTakeFixtures.sequence(of: project, [("take-001", 0, 1), ("take-002", 0, 3)])
            let listed = TakeCommands.takes(of: three, document: both)
            #expect(listed.map(\.id) == ["take-001", "take-002", "take-003"])
            #expect(listed.map(\.number) == [1, 2, 3])
            #expect(listed.map(\.inUse) == [true, true, false])
            #expect(listed.map(\.isEmpty) == [false, false, true])
            #expect(listed[2] == TakeInfo(id: "take-003", number: 3, startedAt: later, duration: 0, inUse: false, isEmpty: true))

            // A pause is left out of the duration.
            var second = try Self.focused(project, "take-002")
            second.events += [
                InputEvent(t: Self.at(1, of: "take-002", in: project), kind: .paused(reason: "user")),
                InputEvent(t: Self.at(1.5, of: "take-002", in: project), kind: .resumed),
            ]
            #expect(TakeCommands.takes(of: second, document: document).map(\.duration) == [4_000_000_000, 2_500_000_000])
        }
    }

    // MARK: - The cut and what is added

    @Test func rerecordCutsAtThePlayheadAndAppendsTheWholeTake() async throws {
        try await withTemporaryDirectory { dir in
            let project = try await Self.firstTake(in: dir)
            let document = MultiTakeFixtures.sequence(of: project, [("take-001", 0, 4)])
            let step = try #require(TakeCommands.rerecord(
                document, take: try Self.focused(project, "take-002"), atOutput: Self.output(2.5), makeID: IDs().make))
            #expect(step.label == .takeRerecord)
            // Aimed at the clips it adds, so it never joins the step before it in an undo group.
            #expect(step.target == "c-00000101")
            let edited = try Self.applying(step, to: document)
            #expect(Self.pieces(edited, project) == [Self.piece("take-001", 0, 2.5), Self.piece("take-002", 0, 3)])
            // The clip split keeps its id; the new one has a new id, at 1×, its sound with its picture.
            #expect(edited.sequence[0].id == document.sequence[0].id)
            #expect(edited.sequence[1].id == "c-00000101")
            #expect(edited.sequence[1].speed == 1)
            #expect(edited.sequence[1].audioShift == 0)
            #expect(TimeMap(sequence: edited.sequence).duration == Self.output(5.5))

            // "Use from Here" is the same step, with its own label.
            let use = try #require(TakeCommands.useFromHere(
                document, take: try Self.focused(project, "take-002"), atOutput: Self.output(2.5), makeID: IDs().make))
            #expect(use.label == .takeUse)
            #expect(use.target == "c-00000101")
            #expect(use.changes == step.changes)
        }
    }

    @Test func aContentClipAtThePlayheadGoes() async throws {
        try await withTemporaryDirectory { dir in
            let project = try await Self.firstTake(in: dir)
            var document = MultiTakeFixtures.sequence(of: project, [("take-001", 0, 2), ("take-001", 2, 4)])
            // The card is the output [2 s, 5 s).
            document.sequence.insert(Self.card("c-0000000a", at: 2, of: "take-001", in: project), at: 1)
            let second = try Self.focused(project, "take-002")
            for seconds in [2.0, 3.5, 4.99] {
                let step = try #require(TakeCommands.rerecord(document, take: second, atOutput: Self.output(seconds), makeID: IDs().make))
                let edited = try Self.applying(step, to: document)
                #expect(Self.pieces(edited, project) == [Self.piece("take-001", 0, 2), Self.piece("take-002", 0, 3)], "\(seconds)")
            }
            // At its end, it stays: the clip after it goes.
            let step = try #require(TakeCommands.rerecord(document, take: second, atOutput: Self.output(5), makeID: IDs().make))
            let edited = try Self.applying(step, to: document)
            #expect(Self.pieces(edited, project) == [
                Self.piece("take-001", 0, 2), Self.piece("take-001", 2, 2, content: true), Self.piece("take-002", 0, 3),
            ])
            #expect(edited.sequence[1] == document.sequence[1])
        }
    }

    @Test func aCutWithinAFrameOfAnEdgeLeavesNoSliver() async throws {
        try await withTemporaryDirectory { dir in
            let project = try await Self.firstTake(in: dir)
            // The clips are the output [0, 2 s) and [2 s, 3.5 s); a frame at 60 fps is 16.7 ms.
            let document = MultiTakeFixtures.sequence(of: project, [("take-001", 0, 2), ("take-001", 2.5, 4)])
            let second = try Self.focused(project, "take-002")
            let hair = 10_000_000 as Int64
            let cases: [(τ: Int64, pieces: [Piece])] = [
                // Less than a frame before the playhead: the clip goes.
                (Self.output(2) + hair, [Self.piece("take-001", 0, 2), Self.piece("take-002", 0, 3)]),
                (hair, [Self.piece("take-002", 0, 3)]),
                // Less than a frame after it: the clip stays whole.
                (Self.output(2) - hair, [Self.piece("take-001", 0, 2), Self.piece("take-002", 0, 3)]),
                (Self.output(3.5) - hair, [Self.piece("take-001", 0, 2), Self.piece("take-001", 2.5, 4), Self.piece("take-002", 0, 3)]),
            ]
            for (τ, pieces) in cases {
                let step = try #require(TakeCommands.rerecord(document, take: second, atOutput: τ, makeID: IDs().make))
                let edited = try Self.applying(step, to: document)
                #expect(Self.pieces(edited, project) == pieces, "\(τ)")
                #expect(edited.sequence.prefix(pieces.count - 1) == document.sequence.prefix(pieces.count - 1), "\(τ)")
            }
        }
    }

    @Test func atZeroTheWholeSequenceIsReplaced() async throws {
        try await withTemporaryDirectory { dir in
            let project = try await Self.firstTake(in: dir)
            let document = MultiTakeFixtures.sequence(of: project, [("take-001", 0, 2), ("take-001", 2.5, 4)])
            let second = try Self.focused(project, "take-002")
            for τ in [0, -Self.output(1)] {
                let step = try #require(TakeCommands.useFromHere(document, take: second, atOutput: τ, makeID: IDs().make))
                #expect(Self.pieces(try Self.applying(step, to: document), project) == [Self.piece("take-002", 0, 3)])
            }
            // At the end, or past it, the step of "Add to End".
            let append = try #require(TakeCommands.appendToEnd(document, take: second, makeID: IDs().make))
            #expect(append.label == .takeUse)
            #expect(append.target == "c-00000101")
            #expect(Self.pieces(try Self.applying(append, to: document), project) == [
                Self.piece("take-001", 0, 2), Self.piece("take-001", 2.5, 4), Self.piece("take-002", 0, 3),
            ])
            let duration = TimeMap(sequence: document.sequence).duration
            for τ in [duration, duration + Self.output(1)] {
                #expect(TakeCommands.useFromHere(document, take: second, atOutput: τ, makeID: IDs().make) == append)
                let rerecord = try #require(TakeCommands.rerecord(document, take: second, atOutput: τ, makeID: IDs().make))
                #expect(rerecord.changes == append.changes)
            }
        }
    }

    @Test func useFromHereContinuesATakeAlreadyUsed() async throws {
        try await withTemporaryDirectory { dir in
            let project = try await Self.firstTake(in: dir)
            let document = MultiTakeFixtures.sequence(of: project, [("take-001", 0, 1), ("take-002", 0, 3)])
            let first = try Self.focused(project, "take-001"), second = try Self.focused(project, "take-002")
            // At 4 s, the end: take-001 from where it was left, at 1 s, to its end.
            let atEnd = try #require(TakeCommands.useFromHere(document, take: first, atOutput: Self.output(4), makeID: IDs().make))
            #expect(Self.pieces(try Self.applying(atEnd, to: document), project) == [
                Self.piece("take-001", 0, 1), Self.piece("take-002", 0, 3), Self.piece("take-001", 1, 4),
            ])
            // At 2 s, inside take-002's clip.
            let inside = try #require(TakeCommands.useFromHere(document, take: first, atOutput: Self.output(2), makeID: IDs().make))
            #expect(Self.pieces(try Self.applying(inside, to: document), project) == [
                Self.piece("take-001", 0, 1), Self.piece("take-002", 0, 1), Self.piece("take-001", 1, 4),
            ])
            // The take of the clip at the playhead goes on from the playhead.
            let same = try #require(TakeCommands.useFromHere(document, take: second, atOutput: Self.output(2), makeID: IDs().make))
            #expect(Self.pieces(try Self.applying(same, to: document), project) == [
                Self.piece("take-001", 0, 1), Self.piece("take-002", 0, 1), Self.piece("take-002", 1, 3),
            ])
            // At 0.5 s, nothing of take-002 is left before the playhead: all of it.
            let early = try #require(TakeCommands.useFromHere(document, take: second, atOutput: Self.output(0.5), makeID: IDs().make))
            #expect(Self.pieces(try Self.applying(early, to: document), project) == [
                Self.piece("take-001", 0, 0.5), Self.piece("take-002", 0, 3),
            ])
            // A frozen frame of the take before the playhead holds it: the take goes on from its point.
            var frozen = MultiTakeFixtures.sequence(of: project, [("take-001", 0, 2)])
            let point = Self.at(3, of: "take-001", in: project)
            frozen.sequence.append(
                Clip(id: "c-0000000f", take: "take-001", start: point, end: point, speed: 1, content: .freeze(duration: 2_000_000_000)))
            let afterFreeze = try #require(TakeCommands.appendToEnd(frozen, take: first, makeID: IDs().make))
            #expect(Self.pieces(try Self.applying(afterFreeze, to: frozen), project) == [
                Self.piece("take-001", 0, 2), Self.piece("take-001", 3, 3, content: true), Self.piece("take-001", 3, 4),
            ])
        }
    }

    @Test func appendToEndOfAnUsedTakeAddsWhatIsLeft() async throws {
        try await withTemporaryDirectory { dir in
            let project = try await Self.firstTake(in: dir)
            let first = try Self.focused(project, "take-001")
            let whole = MultiTakeFixtures.sequence(of: project, [("take-001", 0, 4)])
            #expect(TakeCommands.appendToEnd(whole, take: first, makeID: IDs().make) == nil)
            #expect(TakeCommands.useFromHere(whole, take: first, atOutput: Self.output(4), makeID: IDs().make) == nil)
            let half = MultiTakeFixtures.sequence(of: project, [("take-001", 0, 2)])
            let step = try #require(TakeCommands.appendToEnd(half, take: first, makeID: IDs().make))
            let edited = try Self.applying(step, to: half)
            #expect(Self.pieces(edited, project) == [Self.piece("take-001", 0, 2), Self.piece("take-001", 2, 4)])
            // Only the sequence changes: the take is in the document already.
            #expect(step.changes.allSatisfy { change in
                if case let .insert(collection, _, _) = change { collection == EditCollection.sequence.pointer } else { false }
            })
            // Less than a frame left is nothing to add.
            let almost = MultiTakeFixtures.sequence(of: project, [("take-001", 0, 3.99)])
            #expect(TakeCommands.appendToEnd(almost, take: first, makeID: IDs().make) == nil)
        }
    }

    // MARK: - A take new in the document

    @Test func theNewTakeGetsItsScreenCameraAndAutoZoom() async throws {
        try await withTemporaryDirectory { dir in
            let project = try await Self.firstTake(in: dir)
            var second = try Self.focused(project, "take-002")
            let large = CameraStyle(shape: .roundedSquare, size: CameraStyle.large, anchor: .topLeading)
            let small = CameraStyle(shape: .circle, size: CameraStyle.small, anchor: .bottomLeading)
            func t(_ seconds: Double) -> HostTime { Self.at(seconds, of: "take-002", in: project) }
            second.events += [
                InputEvent(t: t(1.0), kind: .mouseDown(.left, x: 300, y: 180)),
                InputEvent(t: t(1.08), kind: .mouseUp(.left, x: 300, y: 180)),
                InputEvent(t: t(2.5), kind: .cameraStyle(small)),
                InputEvent(t: t(1.5), kind: .cameraStyle(large)),
            ]
            var document = MultiTakeFixtures.sequence(of: project, [("take-001", 0, 4)])
            document.zoom.auto.enabled = true
            let step = try #require(TakeCommands.useFromHere(document, take: second, atOutput: Self.output(2), makeID: IDs().make))
            let edited = try Self.applying(step, to: document)
            #expect(Self.pieces(edited, project) == [Self.piece("take-001", 0, 2), Self.piece("take-002", 0, 3)])

            // Its screen, one: no changes and no planner.
            #expect(edited.screens.initial == ["take-001": "display-1", "take-002": "display-1"])
            #expect(edited.screens.changes == [])
            #expect(edited.screens.planner == nil)
            // Its camera as it recorded it: the bubble it starts with and its changes, in time order, with new ids.
            #expect(edited.camera.initial["take-001"] == document.camera.initial["take-001"])
            #expect(edited.camera.initial["take-002"] == .default)
            #expect(edited.camera.changes == document.camera.changes + [
                CameraChange(id: "k-00000101", take: "take-002", t: t(1.5), style: large, origin: .recorded),
                CameraChange(id: "k-00000102", take: "take-002", t: t(2.5), style: small, origin: .recorded),
            ])
            // Its automatic zooms, planned in the document it leaves: one around its click.
            let regions = edited.zoom.regions
            #expect(!regions.isEmpty)
            #expect(regions.allSatisfy { $0.take == "take-002" && $0.origin == .auto })
            #expect(regions.contains { $0.start <= t(1.0) && t(1.0) < $0.end })
            var unplanned = edited
            unplanned.zoom.regions = []
            #expect(regions == AutoZoomPlanner.plan(take: second.take, events: second.events, document: unplanned))
            // No key of the volume: the mix finds the track by its id.
            #expect(edited.audio == document.audio)
            #expect(edited.style == document.style)

            // The take's own camera style, when it recorded one.
            var manifest = project.manifest
            manifest.takes[1].cameraStyle = large
            let styled = LoadedProject(package: project.package, manifest: manifest, take: manifest.takes[1], events: second.events)
            let withStyle = try Self.applying(
                try #require(TakeCommands.appendToEnd(document, take: styled, makeID: IDs().make)), to: document)
            #expect(withStyle.camera.initial["take-002"] == large)

            // With the automatic zoom off, none.
            var off = document
            off.zoom.auto.enabled = false
            let withoutZoom = try Self.applying(try #require(TakeCommands.appendToEnd(off, take: second, makeID: IDs().make)), to: off)
            #expect(withoutZoom.zoom.regions == [])

            // A take the document knows already (its clips deleted since) gets its clips alone.
            var known = MultiTakeFixtures.sequence(of: project, [("take-001", 0, 1), ("take-002", 0, 3)])
            known.zoom.auto.enabled = true
            known.sequence.removeLast()
            let again = try #require(TakeCommands.appendToEnd(known, take: second, makeID: IDs().make))
            let edit = try Self.applying(again, to: known)
            #expect(Self.pieces(edit, project) == [Self.piece("take-001", 0, 1), Self.piece("take-002", 0, 3)])
            var sequenceOnly = edit
            sequenceOnly.sequence = known.sequence
            #expect(sequenceOnly == known)
        }
    }

    @Test func aNewWindowTakeGetsCornersThatCoverIt() async throws {
        try await withTemporaryDirectory { dir in
            let two = try await MultiTakeFixtures.twoTakes(in: dir)
            let builder = try TakeBuilder(appendingTo: two.package, take: "take-003")
            let start = Self.at(0, of: "take-002", in: two).adding(seconds: 60)
            try await builder.addVideoTrack(
                id: "window-1", kind: .window,
                source: TrackSource(
                    name: "Synthetic Window", globalFrame: Rect(x: 100, y: 80, width: 800, height: 600), pixelScale: 2, windowID: 7),
                segments: [VideoSegmentSpec(start: start, seconds: 2, framesPerSecond: 10)])
            let window = try builder.write()
            let project = try LoadedProject.load(two.package.url, take: "take-001")
            let document = MultiTakeFixtures.sequence(of: project, [("take-001", 0, 4)])
            let step = try #require(TakeCommands.appendToEnd(document, take: window, makeID: IDs().make))
            let edited = try Self.applying(step, to: document)
            #expect(edited.screens.initial["take-003"] == "window-1")
            // The window, 4:3, inside the padding of a 16:9 output: the corners that cover 26 of its 800 pt.
            let size = SIMD2<Double>(1920, 1080)
            let rect = StageLayout.screenRect(contentAspect: 800.0 / 600, padding: document.style.padding, outputSize: size)
            let cover = WindowCornerCover.cornerRadius(windowWidthPoints: 800, screenRectWidth: rect.width, outputWidth: size.x)
            #expect(cover > document.style.cornerRadius)
            #expect(abs(edited.style.cornerRadius - cover) <= 1e-12)
            var corners = edited.style
            corners.cornerRadius = document.style.cornerRadius
            #expect(corners == document.style)
        }
    }

    @Test func zeroLengthTakeIsNoStep() async throws {
        try await withTemporaryDirectory { dir in
            let project = try await Self.firstTake(in: dir)
            var manifest = project.manifest
            let empty = TakeRecord(id: "take-003", status: .complete, startedAt: Date(timeIntervalSince1970: 1_800_000_060), tracks: [])
            manifest.takes.append(empty)
            let take = LoadedProject(package: project.package, manifest: manifest, take: empty, events: [])
            let document = MultiTakeFixtures.sequence(of: project, [("take-001", 0, 4)])
            for τ in [0, Self.output(2), Self.output(4)] {
                #expect(TakeCommands.useFromHere(document, take: take, atOutput: τ, makeID: IDs().make) == nil)
                #expect(TakeCommands.rerecord(document, take: take, atOutput: τ, makeID: IDs().make) == nil)
            }
            #expect(TakeCommands.appendToEnd(document, take: take, makeID: IDs().make) == nil)
        }
    }

    // MARK: - Undo and the invariant

    @Test func undoGivesTheSequenceBack() async throws {
        try await withTemporaryDirectory { dir in
            let project = try await Self.firstTake(in: dir)
            var second = try Self.focused(project, "take-002")
            second.events += [
                InputEvent(t: Self.at(0.5, of: "take-002", in: project), kind: .mouseDown(.left, x: 300, y: 180)),
                InputEvent(t: Self.at(0.55, of: "take-002", in: project), kind: .mouseUp(.left, x: 300, y: 180)),
                InputEvent(t: Self.at(1, of: "take-002", in: project), kind: .cameraStyle(.default)),
            ]
            // The card after the clips is the output [3.5 s, 6.5 s); the second clip's sound starts 0.6 s late.
            var document = MultiTakeFixtures.sequence(of: project, [("take-001", 0, 1.5), ("take-001", 2, 4)])
            document.sequence.append(Self.card("c-0000000a", at: 4, of: "take-001", in: project))
            document.sequence[1].audioShift = 600_000_000
            document.zoom.auto.enabled = true
            try #require(DocumentRules.problems(in: document) == [])
            // At 2.2 s the second clip is left 0.7 s long: its cut of the sound is held to half of it in the same step.
            let step = try #require(TakeCommands.rerecord(document, take: second, atOutput: Self.output(2.2), makeID: IDs().make))
            #expect(step.changes.contains { if case .insert(EditCollection.zoomRegions.pointer, _, _) = $0 { true } else { false } })
            let edited = try document.applying(step.changes)
            #expect(Self.pieces(edited, project) == [
                Self.piece("take-001", 0, 1.5), Self.piece("take-001", 2, 2.7), Self.piece("take-002", 0, 3),
            ])
            #expect(edited.sequence[1].audioShift == 350_000_000)
            #expect(DocumentRules.problems(in: edited) == [])
            // The editor's way of applying it, from the document's JSON, gives the same document.
            #expect(try document.applying(step.changes, json: document.heldJSON()).document == edited)
            let undone = try edited.applying(step.changes.reversed().map(\.inverse))
            #expect(try ProjectJSON.encoder().encode(undone) == ProjectJSON.encoder().encode(document))
            // Redone, the same document again.
            #expect(try undone.applying(step.changes) == edited)
        }
    }

    @MainActor @Test func twoTakeStepsNeverUndoTogether() async throws {
        try await withTemporaryDirectory { dir in
            let project = try await Self.firstTake(in: dir)
            let original = MultiTakeFixtures.sequence(of: project, [("take-001", 0, 2)])
            try DurableFile.writeAtomically(try ProjectJSON.encoder().encode(original), to: project.package.editURL)
            // A clock the test moves: the session groups a burst of steps by the exact moment.
            let clock = Mutex(Date(timeIntervalSince1970: 1_794_773_523.25))
            let ids = IDs()
            let context = EditContext(
                app: AppInfo(name: "Toma", version: "0.3.0"), cachesRoot: dir.appending(path: "Caches"), defaultStyle: .toma,
                now: { clock.withLock { $0 } }, makeID: { ids.make($0) })
            let session = try await EditSession.open(project.package.url, take: nil, context: context)
            #expect(session.access == .editable)
            let opened = session.document
            let second = try Self.focused(session.project, "take-002")
            let first = try Self.focused(session.project, "take-001")

            // "Use from Here" twice, 0.1 s apart, the same label and both on the sequence; then "Add to End" and
            // "Re-record from Here" the same way.
            let use = try #require(TakeCommands.appendToEnd(session.document, take: second, makeID: ids.make))
            #expect(session.perform(use) == .applied)
            let afterOne = session.document
            clock.withLock { $0 += 0.1 }
            let again = try #require(TakeCommands.appendToEnd(session.document, take: first, makeID: ids.make))
            #expect(again.label == use.label)
            #expect(session.perform(again) == .applied)
            let afterTwo = session.document
            clock.withLock { $0 += 0.1 }
            let rerecord = try #require(TakeCommands.rerecord(session.document, take: second, atOutput: Self.output(1), makeID: ids.make))
            #expect(session.perform(rerecord) == .applied)
            clock.withLock { $0 += 0.1 }
            let rerecordAgain = try #require(
                TakeCommands.rerecord(session.document, take: first, atOutput: Self.output(0.5), makeID: ids.make))
            #expect(session.perform(rerecordAgain) == .applied)

            // Each undoes alone (the session moves `logSequence` with each line of the log).
            func same(_ a: EditDocument, _ b: EditDocument) -> Bool {
                var (a, b) = (a, b)
                (a.logSequence, b.logSequence) = (0, 0)
                return a == b
            }
            #expect(session.undoLabel == .takeRerecord)
            #expect(session.undo() == .applied)
            #expect(session.undoLabel == .takeRerecord)
            #expect(session.undo() == .applied)
            #expect(same(session.document, afterTwo))
            #expect(session.undo() == .applied)
            #expect(same(session.document, afterOne))
            #expect(session.undoLabel == .takeUse)
            #expect(session.undo() == .applied)
            #expect(same(session.document, opened))
            await session.close()
        }
    }

    @Test func invariantHoldsAfterEveryTakeCommand() async throws {
        try await withTemporaryDirectory { dir in
            let project = try await Self.firstTake(in: dir)
            let takes = [try Self.focused(project, "take-001"), try Self.focused(project, "take-002")]
            var random = SplitMix64(seed: 0x70_3A_7E_5E)
            let frame = TimeMap.frameTime(1, frameRate: 60)
            var steps = 0
            for index in 0..<200 {
                let document = Self.randomDocument(project, &random)
                try #require(DocumentRules.problems(in: document) == [], "document \(index)")
                let map = TimeMap(sequence: document.sequence)
                // The playhead anywhere, on an edge, a hair from one, at 0 and at the end.
                let edge = map.clipOutputStarts.randomElement(using: &random) ?? 0
                let τ: Int64 = switch random.next() % 5 {
                case 0: 0
                case 1: map.duration
                case 2: edge
                case 3: edge + Int64(random.next() % 40_000_000) - 20_000_000
                default: Int64(random.next() % UInt64(max(map.duration, 1)))
                }
                for (kind, take) in [(0, takes[0]), (1, takes[1]), (2, takes.randomElement(using: &random)!)] {
                    let ids = IDs()
                    let step = switch kind {
                    case 0: TakeCommands.useFromHere(document, take: take, atOutput: τ, makeID: ids.make)
                    case 1: TakeCommands.rerecord(document, take: take, atOutput: τ, makeID: ids.make)
                    default: TakeCommands.appendToEnd(document, take: take, makeID: ids.make)
                    }
                    guard let step else { continue }
                    steps += 1
                    let cut = kind == 2 ? map.duration : min(max(τ, 0), map.duration)
                    let edited = try Self.applying(step, to: document)
                    let context = "document \(index), command \(kind), \(take.take.id) at \(τ)"
                    #expect(SequenceRules.firstOutOfOrder(in: edited.sequence) == nil, "\(context)")
                    #expect(DocumentRules.problems(in: edited) == [], "\(context)")
                    #expect(Set(edited.sequence.map(\.id)).count == edited.sequence.count, "\(context)")
                    // Every clip that ends before the playhead is as it was; nothing before it is lost but a frame.
                    let whole = document.sequence.indices.filter { k in
                        k + 1 < map.clipOutputStarts.count ? map.clipOutputStarts[k + 1] <= cut : map.duration <= cut
                    }.count
                    #expect(Array(edited.sequence.prefix(whole)) == Array(document.sequence.prefix(whole)), "\(context)")
                    // A clip with content at the playhead goes whole.
                    let content = cut < map.duration ? map.contentOffset(atOutput: cut) : nil
                    let floor = content.map { map.clipOutputStarts[$0.clip] } ?? cut - frame + 1
                    #expect(TimeMap(sequence: edited.sequence).duration >= floor, "\(context)")
                    #expect(TimeMap(sequence: edited.sequence).duration > floor, "\(context)")
                    // What is added is the take's, at 1×, each clip at least a frame.
                    let added = edited.sequence.filter { clip in !document.sequence.contains { $0.id == clip.id } }
                    #expect(!added.isEmpty, "\(context)")
                    #expect(step.target == added.map(\.id).joined(separator: ","), "\(context)")
                    #expect(added.allSatisfy { $0.take == take.take.id && $0.speed == 1 && $0.content == nil }, "\(context)")
                    #expect(added.allSatisfy { TimeMap.outputDuration(of: $0) >= frame }, "\(context)")
                }
            }
            #expect(steps > 300, "\(steps) steps")
        }
    }

    @Test func rerecordNeverTouchesWhatIsBeforeThePlayhead() async throws {
        try await withTemporaryDirectory { dir in
            let project = try await Self.firstTake(in: dir)
            let second = try Self.focused(project, "take-002")
            var document = MultiTakeFixtures.sequence(of: project, [("take-001", 0, 1), ("take-001", 1.5, 4)])
            document.zoom.auto.enabled = true
            func t(_ seconds: Double) -> HostTime { Self.at(seconds, of: "take-001", in: project) }
            document.zoom.regions = [
                ZoomRegion(
                    id: "z-00000001", take: "take-001", start: t(0.5), end: t(3.5), origin: .user, depth: 2, focus: .follow,
                    instant: false),
            ]
            document.privacy.blocks = [
                PrivacyBlock(
                    id: "p-00000001", take: "take-001", start: t(1.6), end: t(3.8), effect: .blur,
                    rect: NormalizedRect(x: 0.1, y: 0.1, width: 0.2, height: 0.2)),
            ]
            document.annotations.items = [
                Annotation(
                    id: "a-00000001", anchor: .content(take: "take-001", start: t(2), end: t(3.5)), layer: 0,
                    kind: .shape(ShapeAnnotation(shape: .rect)), rect: NormalizedRect(x: 0.2, y: 0.2, width: 0.3, height: 0.3)),
                Annotation(
                    id: "a-00000002", anchor: .output(start: Self.output(1), end: Self.output(3)), layer: 1,
                    kind: .shape(ShapeAnnotation(shape: .ellipse)), rect: NormalizedRect(x: 0.5, y: 0.5, width: 0.2, height: 0.2)),
            ]
            document.markers.items = [
                Marker(id: "m-00000001", take: "take-001", t: t(3), name: "After", origin: .added),
                Marker(id: "m-00000002", take: "take-001", t: t(0.5), name: "Before", origin: .added),
            ]
            let step = try #require(TakeCommands.rerecord(document, take: second, atOutput: Self.output(2.5), makeID: IDs().make))
            let edited = try Self.applying(step, to: document)
            #expect(Self.pieces(edited, project) == [
                Self.piece("take-001", 0, 1), Self.piece("take-001", 1.5, 3), Self.piece("take-002", 0, 3),
            ])
            // The clips before the cut, as they were but the one split, which keeps its id, start, speed and sound.
            #expect(edited.sequence[0] == document.sequence[0])
            var split = document.sequence[1]
            split.end = t(3)
            #expect(edited.sequence[1] == split)
            // Nothing of take-001 changes: its zooms, its blocks, the annotations and the markers.
            #expect(edited.zoom.regions.filter { $0.take == "take-001" } == document.zoom.regions)
            #expect(edited.zoom.suppressed == document.zoom.suppressed)
            #expect(edited.privacy == document.privacy)
            #expect(edited.annotations == document.annotations)
            #expect(edited.markers == document.markers)
            #expect(edited.audio == document.audio)
            #expect(edited.transcript == document.transcript)
            #expect(edited.camera.changes.filter { $0.take == "take-001" } == document.camera.changes)
            #expect(edited.camera.initial["take-001"] == document.camera.initial["take-001"])
            #expect(edited.screens.initial["take-001"] == document.screens.initial["take-001"])
            // Every change is of the sequence or of take-002's parts.
            let places = Set(step.changes.map { change -> String in
                switch change {
                case let .set(path, _, _): path.string
                case let .insert(collection, _, _), let .remove(collection, _, _), let .replace(collection, _, _, _): collection.string
                }
            })
            #expect(places.isSubset(of: [
                "/sequence", "/screens/initial/take-002", "/camera/initial/take-002", "/camera/changes", "/zoom/regions",
            ]))
        }
    }

    // MARK: - Random documents

    /// A document of `project` with a random sequence of its takes in order (phase 3 design §9): clips of each take
    /// at 0.5×, 1× or 2×, cuts between them, frozen frames and title cards at points of each take, the two takes'
    /// clips interleaved (in a third of them, `take-002` not used, so new in the document), some cuts of the sound
    /// moved; the automatic zoom on or off.
    private static func randomDocument(_ project: LoadedProject, _ random: inout SplitMix64) -> EditDocument {
        var lists: [[Clip]] = []
        var count = 0
        for (take, seconds) in [("take-001", 4.0), ("take-002", 3.0)] {
            let start = at(0, of: take, in: project)
            let length = UInt64(seconds * 1e9)
            let cuts = (0..<Int(random.next() % 7)).map { _ in random.next() % (length + 1) }.sorted()
            var clips: [Clip] = []
            var previous: UInt64 = 0
            for cut in cuts + [length] {
                defer { previous = cut }
                count += 1
                let id = "c-" + String(format: "%08x", 0x1000 + count)
                let (a, b) = (HostTime(nanoseconds: start.nanoseconds + previous), HostTime(nanoseconds: start.nanoseconds + cut))
                switch random.next() % 6 {
                case 0:
                    continue
                case 1:
                    let duration = 100_000_000 + Int64(random.next() % 1_900_000_000)
                    clips.append(Clip(id: id, take: take, start: a, end: a, speed: 1, content: .freeze(duration: duration)))
                case 2:
                    clips.append(Clip(id: id, take: take, start: a, end: a, speed: 1, content: .card(Self.card, duration: 3_000_000_000)))
                default:
                    let speed = [0.5, 1, 2][Int(random.next() % 3)]
                    let clip = Clip(id: id, take: take, start: a, end: b, speed: speed)
                    if TimeMap.outputDuration(of: clip) >= TimeMap.frameTime(1, frameRate: 60) { clips.append(clip) }
                }
            }
            lists.append(clips)
        }
        if random.next() % 3 == 0 { lists[1] = [] }
        // Interleaved, each take in its order.
        var sequence: [Clip] = []
        var (i, j) = (0, 0)
        while i < lists[0].count || j < lists[1].count {
            if j == lists[1].count || (i < lists[0].count && random.next() % 2 == 0) {
                sequence.append(lists[0][i])
                i += 1
            } else {
                sequence.append(lists[1][j])
                j += 1
            }
        }
        if sequence.allSatisfy({ $0.content != nil }) {
            let (start, end) = (at(3.9, of: "take-001", in: project), at(4, of: "take-001", in: project))
            sequence.append(Clip(id: "c-00000fff", take: "take-001", start: start, end: end, speed: 1))
            if SequenceRules.firstOutOfOrder(in: sequence) != nil { sequence = [sequence.removeLast()] }
        }
        for k in sequence.indices where random.next() % 3 == 0 {
            let range = SequenceRules.audioShiftRange(of: sequence, at: k)
            guard range.lowerBound < range.upperBound else { continue }
            let span = UInt64(range.upperBound - range.lowerBound)
            sequence[k].audioShift = range.lowerBound + Int64(random.next() % (span + 1))
        }
        let used = ["take-001"] + (sequence.contains { $0.take == "take-002" } ? ["take-002"] : [])
        var document = MultiTakeFixtures.sequence(of: project, used.map { ($0, 0, 1) })
        document.zoom.auto.enabled = random.next() % 2 == 0
        document.sequence = sequence
        return document
    }
}

/// A random number generator of a fixed seed (SplitMix64), so the random documents are the same in every run.
private struct SplitMix64: RandomNumberGenerator {
    private var state: UInt64

    init(seed: UInt64) {
        state = seed
    }

    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}
