// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import RecorderKitTestSupport
import Synchronization
import Testing
// Not @testable: the app uses only the public API.
import Analysis
import Editing
import ProjectFormat

/// The commands of the clips with content (phase 3a plan, Task A3, decision 11; design §5.2–§5.4, §9): a frozen frame,
/// a title card or an imported clip goes in at the playhead (splitting the clip there), at a clip's edge, or at the start
/// or the end, as a point of a take that keeps every take in order; their changes are each one step.
@Suite struct ContentClipCommandsTests {
    private typealias F = TwoClips

    /// An imported clip's path, as `AssetImport` names one.
    private static let asset = "assets/0123456789abcdef0123456789abcdef.mov"

    private static func seconds(_ s: Double) -> Int64 { F.output(s) }

    /// A clip with content `content` of `take` at the source second `point`.
    private static func point(_ id: String, at point: Double, _ content: ClipContent, take: String = F.takeID) -> Clip {
        Clip(id: id, take: take, start: F.at(point), end: F.at(point), speed: 1, content: content)
    }

    private static let freeze = ClipContent.freeze(duration: ClipContent.freezeDuration)
    private static let card = ClipContent.card(
        TitleCard(title: "Toma", subtitle: "", style: .centered, background: .stage, textColor: RGBA(1, 1, 1, 1)),
        duration: ClipContent.cardDuration)

    // MARK: - Freeze

    @Test func freezeSplitsAndInsertsTwoSeconds() throws {
        let doc = F.document([F.clip(1, from: 0, to: 20)])
        let ids = F.CountingIDs()
        let step = try #require(ContentClipCommands.freeze(doc, atOutput: Self.seconds(5), makeID: ids.make))
        #expect(step.label == .clipFreeze)
        #expect(step.target == "c-00000010")
        #expect(ids.made == ["c-00000010", "c-00000011"])
        let head = F.clip(1, from: 0, to: 5)
        let frozen = Self.point("c-00000010", at: 5, Self.freeze)
        let tail = F.clip("c-00000011", from: 5, to: 20)
        // One step: the clip ends where the point is, the point, and the rest of the clip after it.
        #expect(
            step.changes == [
                try #require(doc.replaceChange(.sequence, id: "c-00000001", with: head)),
                doc.insertChange(.sequence, at: 1, frozen), doc.insertChange(.sequence, at: 2, tail),
            ])
        let edited = try F.applying(step, to: doc)
        #expect(edited.sequence == [head, frozen, tail])
        #expect(F.duration(edited) == F.duration(doc) + ClipContent.freezeDuration)
        #expect(DocumentRules.problems(in: edited) == [])
        // The frozen frame is shown from 5 s to 7 s, and the take goes on from its point after it.
        let map = TimeMap(sequence: edited.sequence)
        #expect(map.clipOutputStarts == [0, Self.seconds(5), Self.seconds(7)])
        #expect(map.source(atOutput: Self.seconds(6))?.source == F.at(5))
        #expect(map.source(atOutput: Self.seconds(7))?.source == F.at(5))

        // At 2×, output 2 s shows the source 4 s into the clip: the point is there, and both pieces keep the speed.
        let fast = F.document([F.clip(1, from: 0, to: 20, speed: 2)])
        let atFast = try F.applying(try #require(ContentClipCommands.freeze(fast, atOutput: Self.seconds(2), makeID: F.newIDs)), to: fast)
        #expect(atFast.sequence.map(\.start) == [F.at(0), F.at(4), F.at(4)])
        #expect(atFast.sequence.map(\.speed) == [2, 1, 2])
        #expect(F.duration(atFast) == Self.seconds(12))
    }

    @Test func freezeNearABorderDoesNotSplit() throws {
        // [0 s, 8 s) and [10 s, 20 s) of the source: the output [0, 8) and [8, 18).
        let doc = F.document([F.clip(1, from: 0, to: 8), F.clip(2, from: 10, to: 20)])
        let half = F.frame / 2
        func frozen(at output: Int64, in doc: EditDocument = doc) throws -> [Clip] {
            let step = try #require(ContentClipCommands.freeze(doc, atOutput: output, makeID: { _ in "c-0000000f" }))
            let edited = try F.applying(step, to: doc)
            #expect(edited.sequence.count == doc.sequence.count + 1, "no split at \(output)")
            // A stretch ended at the playhead loses less than a frame.
            let longer = F.duration(edited) - F.duration(doc)
            #expect(longer > ClipContent.freezeDuration - F.frame && longer <= ClipContent.freezeDuration, "\(output)")
            #expect(SequenceRules.firstOutOfOrder(in: edited.sequence) == nil)
            // Its point is an instant the output shows, never the end of a stretch.
            let point = try #require(edited.sequence.first { $0.id == step.target })
            #expect(TimeMap(sequence: doc.sequence).output(atSource: point.start, take: point.take) != nil, "\(output)")
            return edited.sequence
        }
        let (first, second) = (doc.sequence[0], doc.sequence[1])
        let still = { (at: HostTime) in Clip(id: "c-0000000f", take: F.takeID, start: at, end: at, speed: 1, content: Self.freeze) }
        func ended(_ clip: Clip, at end: HostTime) -> Clip {
            var clip = clip
            clip.end = end
            return clip
        }
        // Half a frame before 8 s, in the first clip: it ends at the instant shown there, and that is the frame.
        let shown = F.at(8, plus: -half)
        #expect(try frozen(at: Self.seconds(8) - half) == [ended(first, at: shown), still(shown), second])
        // At 8 s and half a frame after, in the second: its start.
        #expect(try frozen(at: Self.seconds(8)) == [first, still(F.at(10)), second])
        #expect(try frozen(at: Self.seconds(8) + half) == [first, still(F.at(10)), second])
        // At the start and the end of the output, and past them: the output's first and last instants.
        #expect(try frozen(at: half) == [still(F.at(0)), first, second])
        #expect(try frozen(at: -Self.seconds(1)) == [still(F.at(0)), first, second])
        #expect(try frozen(at: Self.seconds(18) - half) == [first, ended(second, at: F.at(20, plus: -half)), still(F.at(20, plus: -half))])
        #expect(try frozen(at: Self.seconds(30)) == [first, ended(second, at: F.at(20, plus: -1)), still(F.at(20, plus: -1))])
        // A frame from the edge splits.
        let split = try #require(ContentClipCommands.freeze(doc, atOutput: Self.seconds(8) + F.frame, makeID: F.newIDs))
        #expect(try F.applying(split, to: doc).sequence.count == 4)
        // A stretch of a frame is never left shorter: the frame goes before it, at its first instant.
        let oneFrame = Clip(id: "c-00000001", take: F.takeID, start: F.at(0), end: F.at(0, plus: F.frame), speed: 1)
        let short = F.document([oneFrame, second])
        #expect(try frozen(at: F.frame - 1, in: short) == [still(F.at(0)), oneFrame, second])

        // Inside a title card, nothing; within a frame of its edges, at the edge, next to the clip of the take there.
        let withCard = F.document([F.clip(1, from: 0, to: 8), Self.point("c-0000000a", at: 8, Self.card), F.clip(2, from: 10, to: 20)])
        for seconds in [8.5, 9.5, 10.9] {
            #expect(ContentClipCommands.freeze(withCard, atOutput: Self.seconds(seconds), makeID: F.newIDs) == nil, "\(seconds)")
        }
        let card = withCard.sequence[1]
        // On the card's first frame: the last instant the first clip shows, which ends there.
        let atCardStart = try frozen(at: Self.seconds(8) + half, in: withCard)
        #expect(atCardStart == [ended(first, at: F.at(8, plus: -1)), still(F.at(8, plus: -1)), card, second])
        #expect(try frozen(at: Self.seconds(11) - half, in: withCard) == [first, card, still(F.at(10)), second])
        // Between two clips with content, or at an end next to one, there is no instant of a take to freeze.
        let twoContents = F.document([
            F.clip(1, from: 0, to: 8), Self.point("c-0000000a", at: 8, Self.card), Self.point("c-0000000e", at: 8, Self.freeze),
            F.clip(2, from: 10, to: 20),
        ])
        #expect(ContentClipCommands.freeze(twoContents, atOutput: Self.seconds(11), makeID: F.newIDs) == nil)
        #expect(ContentClipCommands.freeze(twoContents, atOutput: Self.seconds(11) - half, makeID: F.newIDs) == nil)
        let cardFirst = F.document([Self.point("c-0000000a", at: 0, Self.card), F.clip(1, from: 0, to: 8)])
        #expect(ContentClipCommands.freeze(cardFirst, atOutput: half, makeID: F.newIDs) == nil)
        #expect(ContentClipCommands.freeze(F.document([F.clip(1, from: 0, to: 8), card]), atOutput: Self.seconds(30), makeID: F.newIDs) == nil)
        // Inside a frozen frame or an imported clip, nothing either.
        let withMedia = F.document([
            F.clip(1, from: 0, to: 8), Self.point("c-0000000b", at: 8, .media(MediaClip(asset: Self.asset, start: 0, end: 3_000_000_000))),
        ])
        #expect(ContentClipCommands.freeze(withMedia, atOutput: Self.seconds(9), makeID: F.newIDs) == nil)
        #expect(ContentClipCommands.freeze(F.document(atCardStart), atOutput: Self.seconds(9), makeID: F.newIDs) == nil)
        // A sequence that shows nothing has no instant to freeze.
        #expect(ContentClipCommands.freeze(F.document([]), atOutput: 0, makeID: F.newIDs) == nil)
    }

    /// A frozen frame at the end of a run of its take shows what the output showed there with every layer of that instant:
    /// a privacy block and an annotation of the take made up to the run's end are over it (the review of A3: at the
    /// stretch's end instant, which the output never shows, they stopped short of it).
    @Test func freezeAtARunsEndKeepsItsLayers() throws {
        // A run of `take-001`, [0 s, 8 s), and then another take.
        var doc = F.document([
            F.clip(1, from: 0, to: 8), Clip(id: "c-00000002", take: "take-002", start: F.at(40), end: F.at(45), speed: 1),
        ])
        // A privacy block from 6 s to the run's end, as the Privacy track makes it, and an annotation of the take to it.
        doc = try F.applying(try #require(PrivacyCommands.add(doc, atOutput: Self.seconds(6), makeID: { _ in "p-00000001" })), to: doc)
        let block = try #require(doc.privacy.blocks.first)
        #expect((block.take, block.start, block.end) == (F.takeID, F.at(6), F.at(8)))
        let note = Annotation(
            id: "a-00000001", anchor: .content(take: F.takeID, start: F.at(5), end: F.at(8)), layer: 0,
            kind: .text(TextAnnotation(string: "Aquí", preset: .plain)), rect: NormalizedRect(x: 0.3, y: 0.4, width: 0.4, height: 0.1),
            exit: .none)
        doc.annotations.items = [note]

        // The run's end before another take's clip, half a frame or a nanosecond from it, and the output's end.
        var alone = doc
        alone.sequence.removeLast()
        for (doc, playhead) in [(doc, Self.seconds(8) - F.frame / 2), (doc, Self.seconds(8) - 1), (alone, Self.seconds(30))] {
            let step = try #require(ContentClipCommands.freeze(doc, atOutput: playhead, makeID: { _ in "c-0000000f" }), "\(playhead)")
            let edited = try F.applying(step, to: doc)
            let k = try #require(edited.sequence.firstIndex { $0.id == "c-0000000f" })
            let point = edited.sequence[k].start
            // The frame is of the take, before the end of the run: the block covers it as the render reads it
            // (`PrivacyScene.regions(atSource:)`: `start <= t < end`), and so does the annotation.
            #expect(edited.sequence[k].take == F.takeID)
            #expect(block.start <= point && point < block.end, "\(playhead)")
            let map = TimeMap(sequence: edited.sequence)
            let middle = map.clipOutputStarts[k] + ClipContent.freezeDuration / 2
            #expect(map.contentOffset(atOutput: middle)?.clip == k)
            #expect(AnnotationTiming.state(of: note, atOutput: middle, document: edited, timeMap: map)?.opacity == 1, "\(playhead)")
            // On the playhead's own instant the take showed it too.
            let before = TimeMap(sequence: doc.sequence)
            #expect(AnnotationTiming.state(of: note, atOutput: min(playhead, Self.seconds(8) - 1), document: doc, timeMap: before)?.opacity == 1)
        }
    }

    // MARK: - Title cards and imported clips

    @Test func cardAtTheCursorTheStartAndTheEnd() throws {
        let doc = F.document()
        func added(_ place: ContentClipCommands.Place, to doc: EditDocument) throws -> (EditStep, EditDocument) {
            let step = try #require(ContentClipCommands.addCard(doc, at: place, title: "Intro", makeID: { _ in "c-0000000c" }))
            return (step, try F.applying(step, to: doc))
        }
        let expected = ClipContent.card(
            TitleCard(title: "Intro", subtitle: "", style: .centered, background: .stage, textColor: RGBA(1, 1, 1, 1)),
            duration: ClipContent.cardDuration)
        let card = { (at: Double) in Self.point("c-0000000c", at: at, expected) }

        let (step, atStart) = try added(.start, to: doc)
        #expect(step.label == .clipCard)
        #expect(step.target == "c-0000000c")
        #expect(step.changes == [doc.insertChange(.sequence, at: 0, card(1))])
        #expect(atStart.sequence == [card(1)] + doc.sequence)
        #expect(F.duration(atStart) == F.duration(doc) + Self.seconds(3))
        #expect(try added(.end, to: doc).1.sequence == doc.sequence + [card(14)])
        // At the playhead, 1 s into the first clip: split there, as a frozen frame is.
        let atCursor = try added(.output(Self.seconds(1)), to: doc).1
        #expect(atCursor.sequence.map(\.start) == [F.at(1), F.at(2), F.at(2), F.at(10)])
        #expect(atCursor.sequence[1] == card(2))
        // Inside a card: at its nearer edge, never in it. At the start of one that is first, before it at its point.
        let nearItsStart = try added(.output(Self.seconds(1)), to: atStart).1.sequence
        #expect(nearItsStart.map(\.id) == ["c-00000003", "c-0000000c", "c-00000001", "c-00000002"])
        #expect(nearItsStart.prefix(2).map(\.start) == [F.at(1), F.at(1)])
        let nearItsEnd = try added(.output(Self.seconds(2.5)), to: atStart).1.sequence
        #expect(nearItsEnd.map(\.id) == ["c-0000000c", "c-00000003", "c-00000001", "c-00000002"])
        #expect(nearItsEnd[1].start == F.at(1))
        #expect(try added(.start, to: atStart).1.sequence.prefix(2).map(\.start) == [F.at(1), F.at(1)])

        // Two takes: the start is the first clip's take and its start; the end, the end of the last clip's take.
        let other = "take-002"
        let twoTakes = F.document([F.clip(1, from: 1, to: 5), Clip(id: "c-00000002", take: other, start: F.at(-50), end: F.at(-47), speed: 1)])
        let first = try added(.start, to: twoTakes).1.sequence[0]
        #expect((first.take, first.start) == (F.takeID, F.at(1)))
        let last = try added(.end, to: twoTakes).1.sequence[2]
        #expect((last.take, last.start) == (other, F.at(-47)))
        // An empty sequence has no take to put it in.
        #expect(ContentClipCommands.addCard(F.document([]), at: .start, title: "", makeID: F.newIDs) == nil)
    }

    @Test func mediaAtACursorOrAnEdge() throws {
        let doc = F.document([F.clip(1, from: 0, to: 8), F.clip(2, from: 10, to: 14)])
        let length: Int64 = 4_500_000_000
        let step = try #require(
            ContentClipCommands.addMedia(doc, asset: Self.asset, fileDuration: length, at: .output(Self.seconds(2)), makeID: F.newIDs))
        #expect(step.label == .clipMedia)
        let edited = try F.applying(step, to: doc)
        #expect(step.target == edited.sequence[1].id)
        #expect(edited.sequence[1].content == .media(MediaClip(asset: Self.asset, start: 0, end: length, speed: 1, volume: 0)))
        #expect(edited.sequence[1].start == F.at(2))
        #expect(F.duration(edited) == F.duration(doc) + length)
        #expect(DocumentRules.problems(in: edited) == [])

        // Dropped on the Video track: the nearer edge of the clip under the pointer, never a split.
        #expect(ContentClipCommands.insertionPoint(doc, nearOutput: Self.seconds(3.1)) == .output(0))
        #expect(ContentClipCommands.insertionPoint(doc, nearOutput: Self.seconds(5)) == .output(Self.seconds(8)))
        #expect(ContentClipCommands.insertionPoint(doc, nearOutput: Self.seconds(9)) == .output(Self.seconds(8)))
        #expect(ContentClipCommands.insertionPoint(doc, nearOutput: Self.seconds(10.5)) == .output(Self.seconds(12)))
        #expect(ContentClipCommands.insertionPoint(doc, nearOutput: -Self.seconds(1)) == .output(0))
        #expect(ContentClipCommands.insertionPoint(doc, nearOutput: Self.seconds(40)) == .output(Self.seconds(12)))
        #expect(ContentClipCommands.insertionPoint(F.document([]), nearOutput: Self.seconds(1)) == .output(0))
        let dropped = try F.applying(
            try #require(ContentClipCommands.addMedia(
                doc, asset: Self.asset, fileDuration: length, at: ContentClipCommands.insertionPoint(doc, nearOutput: Self.seconds(5)),
                makeID: F.newIDs)),
            to: doc)
        #expect(dropped.sequence.count == 3)
        #expect(dropped.sequence[1].start == F.at(10))

        // With the playhead on a frozen frame: at its nearer edge, as a file dropped there.
        let withFreeze = F.document([F.clip(1, from: 0, to: 8), Self.point("c-0000000a", at: 8, Self.freeze), F.clip(2, from: 10, to: 14)])
        func media(at seconds: Double) throws -> [Clip] {
            let step = try #require(ContentClipCommands.addMedia(
                withFreeze, asset: Self.asset, fileDuration: length, at: .output(Self.seconds(seconds)), makeID: { _ in "c-0000000d" }))
            return try F.applying(step, to: withFreeze).sequence
        }
        #expect(try media(at: 8.5).map(\.id) == ["c-00000001", "c-0000000d", "c-0000000a", "c-00000002"])
        #expect(try media(at: 8.5)[1].start == F.at(8))
        #expect(try media(at: 9.6).map(\.id) == ["c-00000001", "c-0000000a", "c-0000000d", "c-00000002"])
        #expect(try media(at: 9.6)[2].start == F.at(10))

        // A clip that would last less than a frame, or a file that is not a clip of `assets/`, is refused.
        for (asset, duration) in [(Self.asset, Int64(0)), (Self.asset, F.frame - 1), ("assets/0123.mov", length), ("/tmp/clip.mov", length),
                                  ("assets/0123456789abcdef0123456789abcdef.png", length)] {
            #expect(ContentClipCommands.addMedia(doc, asset: asset, fileDuration: duration, at: .end, makeID: F.newIDs) == nil, "\(asset)")
        }
        #expect(ContentClipCommands.addMedia(doc, asset: Self.asset, fileDuration: F.frame, at: .end, makeID: F.newIDs) != nil)
    }

    /// A generator of fixed seed (SplitMix64), so every run makes the same insertions.
    private struct SeededGenerator: RandomNumberGenerator {
        var state: UInt64

        mutating func next() -> UInt64 {
            state &+= 0x9E37_79B9_7F4A_7C15
            var z = state
            z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
            z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
            return z ^ (z >> 31)
        }
    }

    @Test func everyInsertKeepsTheInvariant() throws {
        var random = SeededGenerator(state: 0x70A4)
        let other = "take-002"
        // Two takes, interleaved, one of them at 2× and a cut of the sound moved at each edge between two takes.
        var doc = F.document([
            F.clip(1, from: 0, to: 4), Clip(id: "c-00000002", take: other, start: F.at(40), end: F.at(43), speed: 2, audioShift: 200_000_000),
            F.clip(3, from: 6, to: 9), Clip(id: "c-00000004", take: other, start: F.at(45), end: F.at(50), speed: 1, audioShift: -300_000_000),
            F.clip(5, from: 9.5, to: 12),
        ])
        #expect(DocumentRules.problems(in: doc) == [])
        let ids = F.CountingIDs()
        // 200 insertions; a place inside a clip with content puts nothing, and is tried again elsewhere.
        var (applied, splits, refused, ended) = (0, 0, 0, 0)
        while applied < 200, refused < 2_000 {
            let n = applied
            let duration = F.duration(doc)
            // Anywhere; in a stretch of a take, which a split cuts; or within a frame of a clip's edge, where nothing is.
            let map = TimeMap(sequence: doc.sequence)
            let edges = map.clipOutputStarts + [duration]
            let stretches = doc.sequence.indices.filter { doc.sequence[$0].content == nil && edges[$0] < edges[$0 + 1] }
            let τ: Int64 = switch Int.random(in: 0..<3, using: &random) {
            case 0: Int64.random(in: -F.frame...(duration + F.frame), using: &random)
            case 1:
                stretches.randomElement(using: &random).map { k in
                    Int64.random(in: map.clipOutputStarts[k]..<(edges[k + 1]), using: &random)
                } ?? 0
            default: edges.randomElement(using: &random)! + Int64.random(in: -F.frame...F.frame, using: &random)
            }
            let place: ContentClipCommands.Place = switch Int.random(in: 0..<6, using: &random) {
            case 0: .start
            case 1: .end
            case 2: ContentClipCommands.insertionPoint(doc, nearOutput: τ)
            default: .output(τ)
            }
            let step: EditStep?
            let added: Int64
            let kind = Int.random(in: 0..<3, using: &random)
            let isFreeze = kind == 0
            switch kind {
            case 0:
                step = ContentClipCommands.freeze(doc, atOutput: τ, makeID: ids.make)
                added = ClipContent.freezeDuration
            case 1:
                step = ContentClipCommands.addCard(doc, at: place, title: "\(n)", makeID: ids.make)
                added = ClipContent.cardDuration
            default:
                let length = Int64.random(in: F.frame...5_000_000_000, using: &random)
                step = ContentClipCommands.addMedia(doc, asset: Self.asset, fileDuration: length, at: place, makeID: ids.make)
                added = length
            }
            // Only a frozen frame can go nowhere: inside a clip with content, or at an edge with no stretch of a take.
            guard let step else {
                #expect(isFreeze, "\(n)")
                let shown = try #require(TimeMap(sequence: doc.sequence).source(atOutput: τ), "\(n)")
                #expect(doc.sequence[shown.clip].content != nil, "\(n)")
                refused += 1
                continue
            }
            let edited = try doc.applying(step.changes)
            #expect(try edited.applying(step.changes.reversed().map(\.inverse)) == doc, "\(n)")
            #expect(SequenceRules.firstOutOfOrder(in: edited.sequence) == nil, "\(n)")
            #expect(DocumentRules.problems(in: edited) == [], "\(n)")
            if isFreeze {
                // At an instant the output showed; a stretch ended at the playhead loses less than a frame.
                let point = try #require(edited.sequence.first { $0.id == step.target })
                #expect(TimeMap(sequence: doc.sequence).output(atSource: point.start, take: point.take) != nil, "\(n)")
                #expect(F.duration(edited) - duration > added - F.frame && F.duration(edited) - duration <= added, "\(n)")
            } else {
                #expect(F.duration(edited) == duration + added, "\(n)")
            }
            #expect(edited.sequence.allSatisfy { TimeMap.outputDuration(of: $0) >= F.frame }, "\(n)")
            #expect(Set(edited.sequence.map(\.id)).count == edited.sequence.count, "\(n)")
            applied += 1
            if edited.sequence.count == doc.sequence.count + 2 { splits += 1 }
            if isFreeze, edited.sequence.count == doc.sequence.count + 1, step.changes.count > 1 { ended += 1 }
            doc = edited
        }
        #expect(applied == 200)
        #expect(splits > 20)
        #expect(refused > 0)
        #expect(ended > 0)
    }

    // MARK: - Changes

    @Test func durationIsHeldBetweenATenthAndAMinute() throws {
        let media = Self.point("c-0000000b", at: 8, .media(MediaClip(asset: Self.asset, start: 0, end: 3_000_000_000)))
        let doc = F.document([
            F.clip(1, from: 0, to: 8), Self.point("c-0000000a", at: 8, Self.freeze), Self.point("c-0000000c", at: 8, Self.card), media,
        ])
        func duration(_ id: String, _ seconds: Double) throws -> ClipContent? {
            let step = try #require(ContentClipCommands.setDuration(doc, clipID: id, Self.seconds(seconds)))
            #expect(step.label == .clipContent)
            #expect(step.target == id)
            #expect(step.changes.count == 1)
            return try F.applying(step, to: doc).sequence.first { $0.id == id }?.content
        }
        #expect(try duration("c-0000000a", 0.05) == .freeze(duration: 100_000_000))
        #expect(try duration("c-0000000a", 90) == .freeze(duration: 60_000_000_000))
        #expect(try duration("c-0000000a", 5) == .freeze(duration: 5_000_000_000))
        guard case let .card(card, _) = Self.card else { return }
        #expect(try duration("c-0000000c", 0.05) == .card(card, duration: 100_000_000))
        #expect(try duration("c-0000000c", 61) == .card(card, duration: 60_000_000_000))
        // The same length, an imported clip (its length is its file's), a stretch of the take or no such clip: nothing.
        #expect(ContentClipCommands.setDuration(doc, clipID: "c-0000000a", ClipContent.freezeDuration) == nil)
        #expect(ContentClipCommands.setDuration(doc, clipID: media.id, Self.seconds(1)) == nil)
        #expect(ContentClipCommands.setDuration(doc, clipID: "c-00000001", Self.seconds(1)) == nil)
        #expect(ContentClipCommands.setDuration(doc, clipID: "c-0000ffff", Self.seconds(1)) == nil)
    }

    @Test func mediaTrimSpeedAndVolume() throws {
        // [0 s, 4 s) of the take, 3 s of a file of 5 s from its start at 1×, and [10 s, 14 s): the clip is the output [4, 7).
        let file: Int64 = 5_000_000_000
        func doc(_ media: MediaClip) -> EditDocument {
            F.document([F.clip(1, from: 0, to: 4), Self.point("c-0000000b", at: 4, .media(media)), F.clip(2, from: 10, to: 14)])
        }
        let threeSeconds = MediaClip(asset: Self.asset, start: 0, end: 3_000_000_000)
        func trimmed(
            _ edge: ClipEdge, to seconds: Double, file: Int64 = file, from media: MediaClip = threeSeconds
        ) throws -> MediaClip? {
            let before = doc(media)
            guard let step = ContentClipCommands.trimMedia(before, clipID: "c-0000000b", edge: edge, toOutput: Self.seconds(seconds), fileDuration: file)
            else { return nil }
            #expect(step.label == .clipContent)
            #expect(step.target == "c-0000000b")
            #expect(step.changes.count == 1)
            let edited = try F.applying(step, to: before)
            #expect(DocumentRules.problems(in: edited) == [])
            guard case let .media(media)? = edited.sequence[1].content else { return nil }
            return media
        }
        // The end, 1 s later and past the file's end: as far as the file goes.
        #expect(try trimmed(.end, to: 8)?.end == 4_000_000_000)
        #expect(try trimmed(.end, to: 20)?.end == file)
        #expect(try trimmed(.end, to: 7) == nil)
        // A file shorter than the clip says holds it to the file's end.
        #expect(try trimmed(.end, to: 7, file: 2_000_000_000)?.end == 2_000_000_000)
        // Back to its start, or past it: one frame of output is left.
        #expect(try trimmed(.end, to: 4)?.end == F.frame)
        #expect(try trimmed(.end, to: 1)?.end == F.frame)
        // The start, 1 s in; back before the file's start, held at 0; past the end, a frame before it.
        #expect(try trimmed(.start, to: 5)?.start == 1_000_000_000)
        #expect(try trimmed(.start, to: 3) == nil)
        let late = MediaClip(asset: Self.asset, start: 2_000_000_000, end: 4_000_000_000)
        #expect(try trimmed(.start, to: 3, from: late) == MediaClip(asset: Self.asset, start: 1_000_000_000, end: 4_000_000_000))
        #expect(try trimmed(.start, to: 0, from: late)?.start == 0)
        #expect(try trimmed(.start, to: 9)?.start == 3_000_000_000 - F.frame)
        // At 2×, a second of output is two of the file.
        let fast = MediaClip(asset: Self.asset, start: 0, end: 2_000_000_000, speed: 2)
        #expect(try trimmed(.end, to: 6, from: fast)?.end == 4_000_000_000)
        #expect(try trimmed(.end, to: 4, from: fast)?.end == 2 * F.frame - 1)
        // A stretch of the take, or a file without a frame of output: nothing.
        #expect(ContentClipCommands.trimMedia(doc(threeSeconds), clipID: "c-00000001", edge: .end, toOutput: 0, fileDuration: file) == nil)
        #expect(ContentClipCommands.trimMedia(doc(threeSeconds), clipID: "c-0000000b", edge: .end, toOutput: 0, fileDuration: F.frame - 1) == nil)

        // The speed in `ClipSpeed.range`, the volume from −60 to +12 dB.
        func set(_ media: MediaClip = threeSeconds, speed: Double? = nil, volume: Double? = nil) throws -> MediaClip? {
            let before = doc(media)
            guard let step = ContentClipCommands.setMedia(before, clipID: "c-0000000b", speed: speed, volume: volume) else { return nil }
            #expect(step.label == .clipContent)
            #expect(step.changes.count == 1)
            guard case let .media(media)? = try F.applying(step, to: before).sequence[1].content else { return nil }
            return media
        }
        #expect(try set(speed: 20)?.speed == 16)
        #expect(try set(speed: 0.1)?.speed == 0.25)
        #expect(try set(speed: 2)?.speed == 2)
        #expect(try set(volume: -80)?.volume == -60)
        #expect(try set(volume: 20)?.volume == 12)
        #expect(try set(speed: 1.5, volume: -6) == MediaClip(asset: Self.asset, start: 0, end: 3_000_000_000, speed: 1.5, volume: -6))
        #expect(try set(volume: .nan) == nil)
        #expect(try set(speed: 1, volume: 0) == nil)
        #expect(try set() == nil)
        // A speed that would leave less than a frame of output is refused whole.
        #expect(try set(MediaClip(asset: Self.asset, start: 0, end: 100_000_000), speed: 16, volume: -3) == nil)
        #expect(ContentClipCommands.setMedia(doc(threeSeconds), clipID: "c-00000001", volume: -6) == nil)
    }

    @Test func cardChangeIsOneReplace() throws {
        let doc = F.document([F.clip(1, from: 0, to: 8), Self.point("c-0000000c", at: 8, Self.card), Self.point("c-0000000a", at: 8, Self.freeze)])
        let step = try #require(ContentClipCommands.changeCard(doc, clipID: "c-0000000c") { card in
            card.title = "Hola"
            card.subtitle = "Segunda parte"
            card.style = .large
            card.background = .color(RGBA(0.1, 0.2, 0.3, 1))
        })
        #expect(step.label == .clipContent)
        #expect(step.target == "c-0000000c")
        let changed = Self.point(
            "c-0000000c", at: 8,
            .card(TitleCard(title: "Hola", subtitle: "Segunda parte", style: .large, background: .color(RGBA(0.1, 0.2, 0.3, 1))),
                  duration: ClipContent.cardDuration))
        #expect(step.changes == [try #require(doc.replaceChange(.sequence, id: "c-0000000c", with: changed))])
        #expect(try F.applying(step, to: doc).sequence[1] == changed)
        // No change, a frozen frame or a stretch of the take: nothing.
        #expect(ContentClipCommands.changeCard(doc, clipID: "c-0000000c") { _ in } == nil)
        #expect(ContentClipCommands.changeCard(doc, clipID: "c-0000000c") { $0.title = "Toma" } == nil)
        #expect(ContentClipCommands.changeCard(doc, clipID: "c-0000000a") { $0.title = "Hola" } == nil)
        #expect(ContentClipCommands.changeCard(doc, clipID: "c-00000001") { $0.title = "Hola" } == nil)
    }

    // MARK: - In the editor

    private static let base = HostTime(nanoseconds: 5_000_000_000_000)

    /// `c-00000001`, `c-00000002`… from 1 for each new instance.
    private final class IDs: Sendable {
        private let count = Mutex(0)

        func make(_ prefix: String) -> String {
            count.withLock { count in
                count += 1
                return prefix + String(format: "%08x", count)
            }
        }
    }

    private static func context(caches: URL) -> EditContext {
        let ids = IDs()
        let clock = Mutex(Date(timeIntervalSince1970: 1_794_773_523))
        return EditContext(
            app: AppInfo(name: "Toma", version: "0.6.0"), cachesRoot: caches, defaultStyle: .toma,
            now: { clock.withLock { date in defer { date += 2 }; return date } }, makeID: { ids.make($0) })
    }

    /// A take of 2 s of one display, in a new package, written off the main actor.
    @concurrent private static func package(in dir: URL) async throws -> LoadedProject {
        let builder = try TakeBuilder(in: dir, name: "Content")
        let frame = Rect(x: 0, y: 0, width: 640, height: 360)
        try await builder.addVideoTrack(
            id: "display-1", source: TrackSource(name: "Synthetic Display", displayID: 1, globalFrame: frame, pixelScale: 1),
            segments: [VideoSegmentSpec(start: base, seconds: 2, framesPerSecond: 10)])
        try builder.addEvents([InputEvent(t: base.adding(seconds: -0.01), kind: .displayGeometry(displayID: 1, frame: frame, scale: 1))])
        return try builder.write()
    }

    @MainActor @Test func undoRestoresTheSplit() async throws {
        try await withTemporaryDirectory { dir in
            let project = try await Self.package(in: dir)
            // A clip of the user's own, copied into the package before the session opens.
            let clip = try MediaFixtures.clip(in: dir, seconds: 1, size: SIMD2(320, 180), pattern: 3)
            let asset = try await MediaFixtures.imported(clip, into: project, as: .video)
            let context = Self.context(caches: dir.appending(path: "Caches"))
            let session = try await EditSession.open(project.package.url, take: nil, context: context)
            #expect(session.access == .editable)
            let before = try ProjectJSON.encoder().encode(session.document.sequence)
            let document = session.document

            // A frozen frame in the middle of the take's clip: three clips, and one undo gives the one back.
            let freeze = try #require(ContentClipCommands.freeze(session.document, atOutput: 1_000_000_000, makeID: context.makeID))
            #expect(session.perform(freeze) == .applied)
            #expect(session.document.sequence.count == 3)
            #expect(TimeMap(sequence: session.document.sequence).duration == 4_000_000_000)
            #expect(session.undo() == .applied)
            #expect(try ProjectJSON.encoder().encode(session.document.sequence) == before)
            var restored = session.document
            restored.logSequence = document.logSequence
            #expect(restored == document)

            // The imported clip at the playhead, and a change of its volume: each a step, each undone whole.
            let media = try #require(ContentClipCommands.addMedia(
                session.document, asset: asset, fileDuration: 1_000_000_000, at: .output(500_000_000), makeID: context.makeID))
            #expect(session.perform(media) == .applied)
            #expect(session.document.sequence.count == 3)
            let volume = try #require(ContentClipCommands.setMedia(session.document, clipID: media.target, volume: -6))
            #expect(session.perform(volume) == .applied)
            #expect(session.undo() == .applied)
            #expect(session.undo() == .applied)
            #expect(try ProjectJSON.encoder().encode(session.document.sequence) == before)
            await session.close()
        }
    }
}
