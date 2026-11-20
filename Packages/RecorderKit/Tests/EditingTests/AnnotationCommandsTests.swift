// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import Testing
// Not @testable: the app uses only the public API.
import Analysis
import Editing
import ProjectFormat

private enum AnnotationFixture {
    static let base = HostTime(nanoseconds: 5_000_000_000_000)
    static func at(_ s: Double) -> HostTime { base.adding(seconds: s) }
    static func output(_ s: Double) -> Int64 { TimeMap.outputNanoseconds(seconds: s) }

    static let take = TakeRecord(
        id: "take-001", status: .complete, startedAt: Date(timeIntervalSince1970: 1_800_000_000),
        tracks: [
            TrackRecord(
                id: "display-1", kind: .display,
                source: TrackSource(name: "Display", displayID: 1, globalFrame: Rect(x: 0, y: 0, width: 1440, height: 900), pixelScale: 2),
                segments: [
                    SegmentRecord(
                        index: 1, file: "takes/take-001/display-1/seg-0001.mov", startHostTime: base, endHostTime: at(30),
                        endReason: .stopped, droppedFrames: 0, heartbeatFrames: 0)
                ])
        ])

    /// take-001 [0, 8) s (output 0…8), a frozen frame of 2 s (8…10), take-001 [10, 20) s (10…20), where [12, 14) is cut out
    /// of nothing: a second cut would be [20, 25), so the last clip is [10, 20).
    static func document(_ items: [Annotation] = []) -> EditDocument {
        var d = EditDocument.legacy(take: take, events: [])
        d.sequence = [
            Clip(id: "c-00000001", take: "take-001", start: at(0), end: at(8), speed: 1),
            Clip(id: "c-00000002", take: "take-001", start: at(8), end: at(8), speed: 1, content: .freeze(duration: 2_000_000_000)),
            Clip(id: "c-00000003", take: "take-001", start: at(10), end: at(20), speed: 1),
        ]
        d.annotations = AnnotationPlan(items: items)
        return d
    }

    static let rect = NormalizedRect(x: 0.2, y: 0.2, width: 0.3, height: 0.1)

    static func text(_ id: String, _ anchor: AnnotationAnchor, layer: Int = 1, rect: NormalizedRect = rect) -> Annotation {
        Annotation(id: id, anchor: anchor, layer: layer, kind: .text(TextAnnotation(string: "x", preset: .plain)), rect: rect)
    }

    static func content(_ a: Double, _ b: Double) -> AnnotationAnchor { .content(take: "take-001", start: at(a), end: at(b)) }
    static func out(_ a: Double, _ b: Double) -> AnnotationAnchor { .output(start: output(a), end: output(b)) }

    static func counter() -> (String) -> String {
        var n = 0
        return { prefix in
            n += 1
            return prefix + String(format: "%08x", n + 15)
        }
    }

    static func applied(_ doc: EditDocument, _ step: EditStep?) throws -> EditDocument {
        let after = try doc.applying(try #require(step).changes)
        #expect(DocumentRules.problems(in: after).isEmpty)
        return after
    }

    static func layers(_ doc: EditDocument) -> [String: Int] {
        Dictionary(uniqueKeysWithValues: doc.annotations.items.map { ($0.id, $0.layer) })
    }
}

@Suite struct AnnotationCommandsTests {
    fileprivate typealias F = AnnotationFixture

    @Test func newAnnotationSticksToTheRecordingOnATakeRange() throws {
        let doc = F.document()
        let kind = AnnotationDefaults.kind(.text, text: "Text")
        let a = try F.applied(doc, AnnotationCommands.add(doc, kind, atOutput: F.output(2), rect: F.rect, makeID: F.counter()))
        #expect(a.annotations.items.first?.anchor == .content(take: "take-001", start: F.at(2), end: F.at(5)))
        // At 6 s the frozen frame (8 s) cuts it: 2 s only.
        let b = try F.applied(doc, AnnotationCommands.add(doc, kind, atOutput: F.output(6), rect: F.rect, makeID: F.counter()))
        #expect(b.annotations.items.first?.anchor == .content(take: "take-001", start: F.at(6), end: F.at(8)))
    }

    @Test func onContentItIsOutput() throws {
        let doc = F.document()
        let kind = AnnotationDefaults.kind(.step, text: "")
        let a = try F.applied(doc, AnnotationCommands.add(doc, kind, atOutput: F.output(8), rect: F.rect, makeID: F.counter()))
        #expect(a.annotations.items.first?.anchor == F.out(8, 11))
        let clip = AnnotationDefaults.clip(asset: "assets/" + String(repeating: "a", count: 32) + ".mov", fileDuration: F.output(4))
        let b = try F.applied(doc, AnnotationCommands.add(doc, clip, atOutput: F.output(2), rect: F.rect, makeID: F.counter()))
        #expect(b.annotations.items.first?.anchor == F.out(2, 6))
        // Never longer than its file, and cut at the end of the video.
        let c = try F.applied(doc, AnnotationCommands.add(doc, clip, atOutput: F.output(18), rect: F.rect, makeID: F.counter()))
        #expect(c.annotations.items.first?.anchor == F.out(18, 20))
    }

    @Test func defaultsPerKind() throws {
        let doc = F.document([F.text("a-00000001", F.content(0, 4), layer: 4), F.text("a-00000002", F.out(0, 4), layer: 7)])
        let step = try #require(
            AnnotationCommands.add(
                doc, AnnotationDefaults.kind(.arrow, text: ""), atOutput: F.output(1), rect: F.rect, makeID: F.counter()))
        let added = try #require(try doc.applying(step.changes).annotations.items.last)
        #expect(added.id == "a-00000010" && added.id.hasPrefix("a-") && added.layer == 5)
        #expect(added.enter == .fade && added.exit == .fade && added.opacity == 1 && added.rotation == 0)
        #expect(step.label == .annotationAdd && step.target == added.id)
        // A new one in the output group goes above 7.
        let out = try #require(
            AnnotationCommands.add(
                doc, AnnotationDefaults.kind(.shape, text: ""), atOutput: F.output(9), rect: F.rect, makeID: F.counter()))
        #expect(try doc.applying(out.changes).annotations.items.last?.layer == 8)
        // Nothing left to show 0.3 s of: 0.1 s before the end of the output.
        #expect(
            AnnotationCommands.add(
                doc, AnnotationDefaults.kind(.text, text: "x"), atOutput: F.output(19.9), rect: F.rect, makeID: F.counter()) == nil)
        #expect(
            AnnotationCommands.add(
                doc, AnnotationDefaults.kind(.text, text: "x"), atOutput: F.output(25), rect: F.rect, makeID: F.counter()) == nil)
        // Default rects (decision 8).
        let space = 16.0 / 9
        #expect(AnnotationDefaults.rect(for: AnnotationDefaults.kind(.shape, text: ""), aspect: nil, spaceAspect: space)
            == NormalizedRect(x: 0.35, y: 0.35, width: 0.3, height: 0.3))
        let stepRect = AnnotationDefaults.rect(for: .step(StepAnnotation()), aspect: nil, spaceAspect: space)
        #expect(stepRect.height == 0.07 && abs(stepRect.width * space - 0.07) < 1e-12 && stepRect.x == 0.46 && stepRect.y == 0.44)
        let image = AnnotationDefaults.rect(for: AnnotationDefaults.image(asset: "assets/x.png"), aspect: 2, spaceAspect: space)
        #expect(abs(image.width - 0.3) < 1e-12 && abs(image.width * space / image.height - 2) < 1e-9)
        #expect(abs(image.x + image.width / 2 - 0.5) < 1e-12 && abs(image.y + image.height / 2 - 0.5) < 1e-12)
        guard case let .callout(callout) = AnnotationDefaults.kind(.callout, text: "Hi") else { Issue.record(("not a callout")); return }
        #expect(callout.text.fill == RGBA(1, 1, 1, 1) && callout.text.color == RGBA(0, 0, 0, 1))
        #expect(callout.target == NormalizedPoint(x: 0.45, y: 0.45))
        let arrowKind = AnnotationDefaults.kind(.arrow, text: "")
        guard case let .arrow(arrow) = arrowKind else { Issue.record(("not an arrow")); return }
        #expect(arrow.from == NormalizedPoint(x: 0.35, y: 0.35) && arrow.to == NormalizedPoint(x: 0.55, y: 0.55))
    }

    @Test func moveAndTrimLikePrivacy() throws {
        let a = F.text("a-00000001", F.content(2, 4))
        let other = F.text("a-00000002", F.content(5, 7))
        let doc = F.document([a, other, F.text("a-00000003", F.out(1, 3)), F.text("a-00000004", .whole)])
        // Moves through the other one's place, and across the frozen frame by the source.
        let moved = try F.applied(doc, AnnotationCommands.move(doc, id: "a-00000001", toOutputStart: F.output(5.5)))
        #expect(moved.annotations.items[0].anchor == F.content(5.5, 7.5))
        let across = try F.applied(doc, AnnotationCommands.move(doc, id: "a-00000001", toOutputStart: F.output(11)))
        #expect(across.annotations.items[0].anchor == F.content(11 - 2, 13 - 2) || across.annotations.items[0].anchor == F.content(11, 13))
        #expect(AnnotationCommands.move(doc, id: "a-00000001", toOutputStart: F.output(2)) == nil)
        // The output one stays inside [0, D].
        let early = try F.applied(doc, AnnotationCommands.move(doc, id: "a-00000003", toOutputStart: F.output(-5)))
        #expect(early.annotations.items[2].anchor == F.out(0, 2))
        let late = try F.applied(doc, AnnotationCommands.move(doc, id: "a-00000003", toOutputStart: F.output(99)))
        #expect(late.annotations.items[2].anchor == F.out(18, 20))
        // The whole video neither moves nor trims.
        #expect(AnnotationCommands.move(doc, id: "a-00000004", toOutputStart: 5) == nil)
        #expect(AnnotationCommands.trim(doc, id: "a-00000004", edge: .end, toOutput: F.output(3)) == nil)
        // Trims keep at least 0.3 s and the other edge.
        let end = try F.applied(doc, AnnotationCommands.trim(doc, id: "a-00000001", edge: .end, toOutput: F.output(2.1)))
        #expect(end.annotations.items[0].anchor == F.content(2, 2.3))
        let start = try F.applied(doc, AnnotationCommands.trim(doc, id: "a-00000001", edge: .start, toOutput: F.output(1)))
        #expect(start.annotations.items[0].anchor == F.content(1, 4))
        let outEnd = try F.applied(doc, AnnotationCommands.trim(doc, id: "a-00000003", edge: .end, toOutput: F.output(1.1)))
        #expect(outEnd.annotations.items[2].anchor == F.out(1, 1.3))
        let step = try #require(AnnotationCommands.trim(doc, id: "a-00000003", edge: .start, toOutput: F.output(2)))
        #expect(step.label == .annotationTrim && step.target == "a-00000003")
    }

    @Test func clipTrimStopsAtItsFileLength() throws {
        let asset = "assets/" + String(repeating: "b", count: 32) + ".mov"
        let clip = Annotation(
            id: "a-0000000c", anchor: F.out(2, 4), layer: 1, kind: .clip(ClipAnnotation(asset: asset, start: F.output(1), end: F.output(6))),
            rect: F.rect)
        let doc = F.document([clip])
        // The file has 5 s from 1 s: the end stops at 2 + 5 = 7 s.
        let longer = try F.applied(doc, AnnotationCommands.trim(doc, id: clip.id, edge: .end, toOutput: F.output(15)))
        #expect(longer.annotations.items[0].anchor == F.out(2, 7))
        // Trimming the start moves the file's start with it, so each frame stays at its instant; it stops at the file's 0.
        let later = try F.applied(doc, AnnotationCommands.trim(doc, id: clip.id, edge: .start, toOutput: F.output(3)))
        guard case let .clip(c) = later.annotations.items[0].kind else { Issue.record(("not a clip")); return }
        #expect(c.start == F.output(2) && later.annotations.items[0].anchor == F.out(3, 4))
        let earlier = try F.applied(doc, AnnotationCommands.trim(doc, id: clip.id, edge: .start, toOutput: 0))
        guard case let .clip(e) = earlier.annotations.items[0].kind else { Issue.record(("not a clip")); return }
        #expect(e.start == 0 && earlier.annotations.items[0].anchor == F.out(1, 4))
        // A clip never goes to the recording; the whole video is not a problem for it.
        #expect(AnnotationCommands.setAnchor(doc, id: clip.id, to: .recording, rect: F.rect) == nil)
        _ = try F.applied(doc, AnnotationCommands.setAnchor(doc, id: clip.id, to: .whole, rect: F.rect))
        // A file path out of assets/ is refused.
        #expect(
            AnnotationCommands.add(
                doc, AnnotationDefaults.clip(asset: "../x.mov", fileDuration: 1_000_000_000), atOutput: 0, rect: F.rect,
                makeID: F.counter()) == nil)
    }

    @Test func layerOrderAmongThoseShownTogether() throws {
        // A, B, C show together (output 0–6, 1–5, 4–8); D (10–12) is apart; E is of the take (another group).
        let doc = F.document([
            F.text("a-0000000a", F.out(0, 6), layer: 1), F.text("a-0000000b", F.out(1, 5), layer: 2),
            F.text("a-0000000d", F.out(10, 12), layer: 3), F.text("a-0000000c", F.out(4, 8), layer: 4),
            F.text("a-0000000e", F.content(0, 6), layer: 9),
        ])
        // B forward goes past C, skipping D (which it never shows with); D does not move except by the order of the others.
        let forward = try F.applied(doc, AnnotationCommands.reorder(doc, id: "a-0000000b", .forward))
        let l = F.layers(forward)
        #expect(l["a-0000000b"]! > l["a-0000000c"]! && l["a-0000000c"]! > l["a-0000000a"]!)
        #expect(l["a-0000000e"] == 9)
        // A forward goes past B only.
        let a = try F.applied(doc, AnnotationCommands.reorder(doc, id: "a-0000000a", .forward))
        let la = F.layers(a)
        #expect(la["a-0000000a"]! > la["a-0000000b"]! && la["a-0000000a"]! < la["a-0000000c"]!)
        // C backward goes below B? No: below A, B and C are all it meets; the nearest is B.
        let back = try F.applied(doc, AnnotationCommands.reorder(doc, id: "a-0000000c", .backward))
        let lb = F.layers(back)
        #expect(lb["a-0000000c"]! < lb["a-0000000b"]! && lb["a-0000000c"]! > lb["a-0000000a"]!)
        // Front and back: above or below the whole group, one replace.
        let front = try #require(AnnotationCommands.reorder(doc, id: "a-0000000a", .front))
        #expect(front.changes.count == 1 && front.label == .annotationLayer && front.target == "a-0000000a")
        #expect(F.layers(try F.applied(doc, front))["a-0000000a"] == 5)
        let bottom = try F.applied(doc, AnnotationCommands.reorder(doc, id: "a-0000000c", .back))
        #expect(F.layers(bottom)["a-0000000c"] == 0)
        // Already there: nothing. The other group does not count.
        #expect(AnnotationCommands.reorder(doc, id: "a-0000000c", .front) == nil)
        #expect(AnnotationCommands.reorder(doc, id: "a-0000000a", .back) == nil)
        #expect(AnnotationCommands.reorder(doc, id: "a-0000000c", .forward) == nil)
        #expect(AnnotationCommands.reorder(doc, id: "a-0000000d", .forward) == nil)
        #expect(AnnotationCommands.reorder(doc, id: "a-0000000e", .front) == nil)
        #expect(AnnotationCommands.reorder(doc, id: "a-ffffffff", .front) == nil)
    }

    @Test func equalLayersStillSwap() throws {
        // Two on the same layer: the later in the document is on top; forward on the first puts it above.
        let doc = F.document([F.text("a-00000001", F.out(0, 5), layer: 1), F.text("a-00000002", F.out(1, 6), layer: 1)])
        let after = try F.applied(doc, AnnotationCommands.reorder(doc, id: "a-00000001", .forward))
        let l = F.layers(after)
        #expect(l["a-00000001"]! > l["a-00000002"]!)
        let shown = AnnotationCommands.shown(atOutput: F.output(2), in: after).map(\.id)
        #expect(shown == ["a-00000001", "a-00000002"])
    }

    @Test func duplicateOffsetsAndGoesOnTop() throws {
        let arrow = Annotation(
            id: "a-00000001", anchor: F.out(1, 4), layer: 3,
            kind: AnnotationDefaults.kind(.arrow, text: ""), rect: AnnotationDefaults.rect(for: AnnotationDefaults.kind(.arrow, text: ""), aspect: nil, spaceAspect: 1))
        let text = F.text("a-00000002", F.content(2, 5), layer: 2)
        let doc = F.document([arrow, text])
        let step = try #require(AnnotationCommands.duplicate(doc, ids: ["a-00000001", "a-00000002"], makeID: F.counter()))
        #expect(step.label == .annotationAdd && step.changes.count == 2)
        let after = try F.applied(doc, step)
        #expect(after.annotations.items.count == 4)
        let copies = Array(after.annotations.items[2...])
        let copyText = try #require(copies.first { $0.anchor == text.anchor })
        let copyArrow = try #require(copies.first { $0.anchor == arrow.anchor })
        #expect(copyText.rect.x == text.rect.x + 0.02 && copyText.rect.y == text.rect.y + 0.02)
        #expect(copyText.layer == 3 && copyArrow.layer == 4)
        #expect(copyText.id != text.id && copyArrow.id != arrow.id)
        guard case let .arrow(moved) = copyArrow.kind, case let .arrow(original) = arrow.kind else { Issue.record(("not arrows")); return }
        #expect(abs(moved.from.x - original.from.x - 0.02) < 1e-12 && abs(moved.to.y - original.to.y - 0.02) < 1e-12)
        #expect(step.target == copies.map(\.id).joined(separator: ",") || step.target.split(separator: ",").count == 2)
        #expect(AnnotationCommands.duplicate(doc, ids: ["a-nope"], makeID: F.counter()) == nil)
    }

    @Test func changeSanitizes() throws {
        let doc = F.document([F.text("a-00000001", F.content(1, 3))])
        func changed(_ edit: (inout Annotation) -> Void) throws -> Annotation {
            try #require(try F.applied(doc, AnnotationCommands.change(doc, id: "a-00000001", edit)).annotations.items.first)
        }
        let big = try changed {
            guard case var .text(t) = $0.kind else { return }
            t.size = 2
            $0.kind = .text(t)
            $0.opacity = 3
            $0.rotation = 400
            $0.enter = .draw
        }
        guard case let .text(t) = big.kind else { Issue.record(("not a text")); return }
        #expect(t.size == 0.5 && big.opacity == 1 && big.rotation == 180 && big.enter == .fade)
        let arrow = Annotation(
            id: "a-00000002", anchor: F.out(0, 3), layer: 1, kind: AnnotationDefaults.kind(.arrow, text: ""), rect: F.rect)
        let withArrow = F.document([arrow])
        let drawn = try F.applied(
            withArrow,
            AnnotationCommands.change(withArrow, id: arrow.id) {
                guard case var .arrow(a) = $0.kind else { return }
                a.curve = -5
                a.width = 0
                $0.kind = .arrow(a)
                $0.enter = .draw
            })
        guard case let .arrow(a) = drawn.annotations.items[0].kind else { Issue.record(("not an arrow")); return }
        #expect(a.curve == -1 && a.width == 0.001 && drawn.annotations.items[0].enter == .draw)
        // Not a number: nothing. An id or an anchor is not changed here. Nothing changed: nothing.
        #expect(AnnotationCommands.change(doc, id: "a-00000001") { $0.opacity = .nan } == nil)
        #expect(AnnotationCommands.change(doc, id: "a-00000001") { $0.rect.x = .infinity } == nil)
        #expect(AnnotationCommands.change(doc, id: "a-00000001") { ($0.id, $0.anchor) = ("a-zzzzzzzz", .whole) } == nil)
        #expect(AnnotationCommands.change(doc, id: "a-00000001") { _ in } == nil)
        #expect(AnnotationCommands.change(doc, id: "a-nope") { $0.opacity = 0.5 } == nil)
        // A bad asset path is not written.
        let image = Annotation(
            id: "a-00000003", anchor: F.out(0, 3), layer: 1, kind: AnnotationDefaults.image(asset: "assets/" + String(repeating: "c", count: 32) + ".png"),
            rect: F.rect)
        let withImage = F.document([image])
        #expect(
            AnnotationCommands.change(withImage, id: image.id) { $0.kind = .image(ImageAnnotation(asset: "x/../y.png", fit: .fit)) } == nil)
    }

    @Test func placeAndNudge() throws {
        let arrow = Annotation(
            id: "a-00000001", anchor: F.out(0, 5), layer: 1, kind: AnnotationDefaults.kind(.arrow, text: ""), rect: F.rect)
        let callout = Annotation(
            id: "a-00000002", anchor: F.content(1, 4), layer: 2, kind: AnnotationDefaults.kind(.callout, text: "Hi"), rect: F.rect)
        let doc = F.document([arrow, callout])
        // A handle of the arrow: its rect comes from the ends.
        let step = try #require(
            AnnotationCommands.place(
                doc, id: arrow.id, rect: F.rect, from: NormalizedPoint(x: 0.1, y: 0.1), to: NormalizedPoint(x: 0.6, y: 0.1),
                label: .annotationChange))
        #expect(step.label == .annotationChange)
        let placed = try F.applied(doc, step).annotations.items[0]
        guard case let .arrow(a) = placed.kind else { Issue.record(("not an arrow")); return }
        #expect(a.to == NormalizedPoint(x: 0.6, y: 0.1) && placed.rect == AnnotationGeometry.arrowRect(a))
        // The body moves it whole.
        let body = try #require(
            AnnotationCommands.place(
                doc, id: arrow.id, rect: NormalizedRect(x: F.rect.x + 0.1, y: F.rect.y, width: F.rect.width, height: F.rect.height),
                label: .annotationMove))
        #expect(body.label == .annotationMove)
        // The text size and the bubble's point.
        let sized = try F.applied(
            doc,
            AnnotationCommands.place(
                doc, id: callout.id, rect: F.rect, target: NormalizedPoint(x: 0.9, y: 0.9), size: 0.9, label: .annotationChange))
        guard case let .callout(c) = sized.annotations.items[1].kind else { Issue.record(("not a callout")); return }
        #expect(c.target == NormalizedPoint(x: 0.9, y: 0.9) && c.text.size == 0.5)
        #expect(AnnotationCommands.place(doc, id: callout.id, rect: NormalizedRect(x: .nan, y: 0, width: 1, height: 1), label: .annotationMove) == nil)
        #expect(AnnotationCommands.place(doc, id: callout.id, rect: callout.rect, label: .annotationMove) == nil)
        // Nudge: one step for all, the points go with them and the rect stays where its anchor lets it be.
        let nudge = try #require(AnnotationCommands.nudge(doc, by: [arrow.id: SIMD2(0.05, 0), callout.id: SIMD2(0, -9)]))
        #expect(nudge.label == .annotationMove && nudge.target == "a-00000001,a-00000002" && nudge.changes.count == 2)
        let nudged = try F.applied(doc, nudge)
        guard case let .arrow(na) = nudged.annotations.items[0].kind, case let .arrow(oa) = arrow.kind else { Issue.record(("arrows")); return }
        #expect(abs(na.from.x - oa.from.x - 0.05) < 1e-12)
        #expect(nudged.annotations.items[1].rect.y == -0.5)
        #expect(AnnotationCommands.nudge(doc, by: [arrow.id: SIMD2(.nan, 0)]) == nil)
        #expect(AnnotationCommands.nudge(doc, by: [:]) == nil)
    }

    @Test func setAnchorKeepsTheTimeAndTakesTheGivenGeometry() throws {
        let doc = F.document([
            F.text("a-00000001", F.content(2, 5)), F.text("a-00000002", F.out(1, 4)), F.text("a-00000003", .whole),
            F.text("a-00000004", F.out(7, 9)),
        ])
        let newRect = NormalizedRect(x: 0.6, y: 0.1, width: 0.2, height: 0.1)
        // Recording → output: the output range it has (here the same 2…5).
        let toOutput = try F.applied(doc, AnnotationCommands.setAnchor(doc, id: "a-00000001", to: .output, rect: newRect))
        #expect(toOutput.annotations.items[0].anchor == F.out(2, 5) && toOutput.annotations.items[0].rect == newRect)
        // Output → recording: its source, when it falls in one run of a take.
        let toRecording = try F.applied(doc, AnnotationCommands.setAnchor(doc, id: "a-00000002", to: .recording, rect: newRect))
        #expect(toRecording.annotations.items[1].anchor == F.content(1, 4))
        // Over the frozen frame (7–9 s of output) it cannot; the whole video neither (it has content in it).
        #expect(AnnotationCommands.setAnchor(doc, id: "a-00000004", to: .recording, rect: newRect) == nil)
        #expect(AnnotationCommands.setAnchor(doc, id: "a-00000003", to: .recording, rect: newRect) == nil)
        // Anything to the whole video: [0, D).
        let whole = try F.applied(doc, AnnotationCommands.setAnchor(doc, id: "a-00000002", to: .whole, rect: newRect))
        #expect(whole.annotations.items[1].anchor == .whole)
        let back = try F.applied(doc, AnnotationCommands.setAnchor(doc, id: "a-00000003", to: .output, rect: newRect))
        #expect(back.annotations.items[2].anchor == F.out(0, 20))
        // The geometry is held to the new anchor's space: an output one has its centre inside.
        let held = try F.applied(
            doc, AnnotationCommands.setAnchor(doc, id: "a-00000001", to: .output, rect: NormalizedRect(x: 3, y: 3, width: 0.2, height: 0.2)))
        #expect(held.annotations.items[0].rect.x + 0.1 == 1)
        #expect(AnnotationCommands.setAnchor(doc, id: "a-00000001", to: .output, rect: doc.annotations.items[0].rect) != nil)
    }

    @Test func everyChangeIsOneReplaceWithItsLabel() throws {
        let doc = F.document([F.text("a-00000001", F.content(1, 3)), F.text("a-00000002", F.out(1, 3)), F.text("a-00000003", .whole)])
        func check(_ step: EditStep?, _ label: EditLabel, _ target: String, count: Int = 1) throws {
            let step = try #require(step)
            #expect(step.label == label && step.target == target && step.changes.count == count)
            _ = try F.applied(doc, step)
        }
        try check(AnnotationCommands.add(doc, AnnotationDefaults.kind(.text, text: "t"), atOutput: F.output(12), rect: F.rect, makeID: F.counter()), .annotationAdd, "a-00000010")
        try check(AnnotationCommands.change(doc, id: "a-00000002") { $0.opacity = 0.5 }, .annotationChange, "a-00000002")
        try check(AnnotationCommands.move(doc, id: "a-00000001", toOutputStart: F.output(5)), .annotationMove, "a-00000001")
        try check(AnnotationCommands.trim(doc, id: "a-00000001", edge: .end, toOutput: F.output(2)), .annotationTrim, "a-00000001")
        try check(AnnotationCommands.reorder(doc, id: "a-00000002", .forward), .annotationLayer, "a-00000002")
        // Two deleted: one step with two removes, in the order of the document.
        try check(AnnotationCommands.delete(doc, ids: ["a-00000003", "a-00000001", "a-nope"]), .annotationDelete, "a-00000001,a-00000003", count: 2)
        #expect(AnnotationCommands.delete(doc, ids: ["a-nope"]) == nil)
        // Each is undone by its inverse.
        let step = try #require(AnnotationCommands.delete(doc, ids: ["a-00000003", "a-00000001"]))
        let gone = try F.applied(doc, step)
        #expect(gone.annotations.items.map(\.id) == ["a-00000002"])
        #expect(try gone.applying(step.changes.reversed().map(\.inverse)) == doc)
    }

    @Test func everyStepUndoesToTheSameDocument() throws {
        let doc = F.document([
            F.text("a-00000001", F.content(1, 3), layer: 1), F.text("a-00000002", F.out(1, 4), layer: 2),
            F.text("a-00000003", F.out(2, 6), layer: 2),
        ])
        let steps: [EditStep?] = [
            AnnotationCommands.add(doc, AnnotationDefaults.kind(.step, text: ""), atOutput: F.output(12), rect: F.rect, makeID: F.counter()),
            AnnotationCommands.duplicate(doc, ids: ["a-00000001", "a-00000002"], makeID: F.counter()),
            AnnotationCommands.move(doc, id: "a-00000001", toOutputStart: F.output(12)),
            AnnotationCommands.trim(doc, id: "a-00000002", edge: .start, toOutput: F.output(2)),
            AnnotationCommands.reorder(doc, id: "a-00000002", .forward),
            AnnotationCommands.nudge(doc, by: ["a-00000003": SIMD2(0.1, 0.1)]),
            AnnotationCommands.setAnchor(doc, id: "a-00000002", to: .whole, rect: F.rect),
            AnnotationCommands.change(doc, id: "a-00000003") { $0.rotation = 30 },
        ]
        for step in steps {
            let step = try #require(step)
            let after = try F.applied(doc, step)
            #expect(after != doc)
            #expect(try after.applying(step.changes.reversed().map(\.inverse)) == doc)
        }
    }

    @Test func shownIsTopFirst() throws {
        let doc = F.document([
            F.text("a-00000001", F.content(1, 5), layer: 5), F.text("a-00000002", F.out(0, 6), layer: 1),
            F.text("a-00000003", F.out(2, 3), layer: 2), F.text("a-00000004", .whole, layer: 1),
        ])
        // The ones of the output are over the ones of the take, higher layer first, and the later of equal layers first.
        #expect(AnnotationCommands.shown(atOutput: F.output(2.5), in: doc).map(\.id) == ["a-00000003", "a-00000004", "a-00000002", "a-00000001"])
        #expect(AnnotationCommands.shown(atOutput: F.output(7), in: doc).map(\.id) == ["a-00000004"])
        #expect(AnnotationCommands.shown(atOutput: F.output(25), in: doc).isEmpty)
    }

    @Test func notNumbersNeverReachTheDocument() {
        let doc = F.document()
        var rect = F.rect
        rect.width = .nan
        #expect(
            AnnotationCommands.add(doc, AnnotationDefaults.kind(.text, text: "t"), atOutput: 0, rect: rect, makeID: F.counter()) == nil)
        let arrow = ArrowAnnotation(from: NormalizedPoint(x: .nan, y: 0), to: NormalizedPoint(x: 1, y: 1), head: .filled)
        #expect(AnnotationCommands.add(doc, .arrow(arrow), atOutput: 0, rect: F.rect, makeID: F.counter()) == nil)
    }
}
