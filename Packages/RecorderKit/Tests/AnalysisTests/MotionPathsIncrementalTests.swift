// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import ProjectFormat
import Testing
@testable import Analysis

// Rebuilding the motion paths after an edit (1b design §7.9 and §8.6, 1c design §15): `MotionPaths(take:events:document:
// after:)` keeps the checkpoints of the paths before the edit up to the first instant it can change and simulates only
// from there, with the bits of building them from nothing. Over the take of `ZoomFixtures`, with a camera.

/// The pointer: all over the display and a bit beyond it, never still for long.
private func wander(_ t: Double) -> SIMD2<Double> {
    SIMD2(720 + 790 * cos(0.37 * t) * sin(0.11 * t + 0.4), 450 + 480 * sin(0.53 * t) * cos(0.07 * t))
}

/// A whole number of seconds of output, in steps.
private func steps(_ seconds: Double) -> Int { Int(seconds * Double(StepGrid.rate)) }

/// What an edit does to the document, at random (`ZoomFixtures.edited`).
private enum PathEdit: CaseIterable {
    case addZoom, moveZoom, trimZoom, deleteZoom, zoomDepth, autoDepth, leadIn, zoomSpring, zoomShow
    case cursorSpring, cursorOff, cursorSize, idle
    case cutClip, trimClip, speedClip
    case addSplit, removeSplit
    case bubbleChange, padding, frameTitle
    /// Back to the document before the last edit.
    case undo
}

extension ZoomFixtures {
    /// The events of a take of `seconds`: the pointer `wander`ing, a position every `1 / rate` s but for 3 s still every
    /// 40 s (the idle cursor), a click every 3.7 s and a drag of 0.6 s every 23 s.
    fileprivate static func wanderingEvents(seconds: Double, rate: Double = 60) -> [InputEvent] {
        var events: [InputEvent] = []
        for i in 0...Int(seconds * rate) {
            let t = Double(i) / rate
            guard t.truncatingRemainder(dividingBy: 40) < 30 || t.truncatingRemainder(dividingBy: 40) >= 33 else { continue }
            events.append(pointer(t, wander(t)))
        }
        for k in 1..<Int(seconds / 3.7) {
            let t = 3.7 * Double(k), point = wander(t)
            events.append(InputEvent(t: source(t), kind: .mouseDown(.left, x: point.x, y: point.y)))
            events.append(InputEvent(t: source(t + 0.08), kind: .mouseUp(.left, x: point.x, y: point.y)))
        }
        for k in 1..<Int(seconds / 23) {
            let t = 23 * Double(k) + 1.3, from = wander(t), to = wander(t + 0.6)
            events.append(InputEvent(t: source(t), kind: .mouseDown(.right, x: from.x, y: from.y)))
            events.append(InputEvent(t: source(t + 0.6), kind: .mouseUp(.right, x: to.x, y: to.y)))
        }
        return events.sortedByTime()
    }

    /// A document of a take of `seconds`: two clips with a cut of 4 s, the second at 1.25×; a zoom block every 9 s of
    /// source, following, fixed, instant or of the automatic depth; the smoothed cursor hidden when still; the camera's
    /// bubble, which changes twice; a split from 30 % to 40 % of the take; a padding.
    fileprivate static func editedTakeDocument(seconds: Double) -> EditDocument {
        let middle = (seconds * 0.55).rounded()
        let regions = (0..<Int(seconds / 9)).map { k in
            let start = 9 * Double(k) + 1.5
            return switch k % 4 {
            case 0: block(k, from: start, to: start + 4)
            case 1: block(k, from: start, to: start + 3, depth: 3, focus: .fixed(x: 0.8, y: 0.25))
            case 2: block(k, from: start, to: start + 2.5, depth: 1.6, instant: true)
            default: block(k, from: start, to: start + 5, depth: nil)
            }
        }
        var document = zoomDocument(
            padding: 0.05, sequence: [zoomClip(1, from: 0, to: middle), zoomClip(2, from: middle + 4, to: seconds, speed: 1.25)],
            regions: regions, smoothing: smoothed, bubble: .default, layout: .bubble,
            layouts: [splitBlock(1, from: seconds * 0.3, to: seconds * 0.4)])
        document.cursor.hideWhenIdle = true
        document.camera.changes = [(seconds / 3, CameraAnchor.topLeading), (2 * seconds / 3, .bottomLeading)].enumerated().map {
            CameraChange(
                id: "k-0000000\($0.offset)", take: zoomTakeID, t: source($0.element.0),
                style: CameraStyle(shape: .roundedSquare, size: CameraStyle.large, anchor: $0.element.1), origin: .user)
        }
        return document
    }

    fileprivate static func splitBlock(_ number: Int, from: Double, to: Double) -> LayoutBlock {
        LayoutBlock(
            id: "l-\(String(format: "%08x", number))", take: zoomTakeID, start: source(from), end: source(to), kind: .split,
            instant: false, split: SplitLayout())
    }

    /// `document` after `edit` at random, over a take of `seconds`; `history`, the documents before it, for `undo`.
    fileprivate static func edited(
        _ document: EditDocument, by edit: PathEdit, seconds: Double, history: [EditDocument], random: inout ZoomRandom
    ) -> EditDocument {
        var document = document
        var ids = document.zoom.regions.count + document.sequence.count + document.camera.layouts.count + 100
        func id(_ prefix: String) -> String {
            ids += Int.random(in: 1...1_000, using: &random)
            return prefix + String(format: "%08x", ids)
        }
        func time(_ range: ClosedRange<Double>) -> Double { Double.random(in: range, using: &random) }
        func randomBlock() -> ZoomRegion {
            let start = time(0...(seconds - 1))
            return ZoomRegion(
                id: id("z-"), take: zoomTakeID, start: source(start), end: source(min(start + time(0.4...6), seconds)),
                origin: .user, depth: Bool.random(using: &random) ? time(1.2...5) : nil,
                focus: Bool.random(using: &random) ? .follow : .fixed(x: time(0...1), y: time(0...1)),
                instant: Int.random(in: 0..<5, using: &random) == 0)
        }
        let regions = document.zoom.regions.indices
        switch edit {
        case .addZoom:
            document.zoom.regions.insert(randomBlock(), at: Int.random(in: 0...document.zoom.regions.count, using: &random))
        case .moveZoom where !regions.isEmpty:
            let k = Int.random(in: regions, using: &random), by = time(-3...3)
            document.zoom.regions[k].start = document.zoom.regions[k].start.adding(seconds: by)
            document.zoom.regions[k].end = document.zoom.regions[k].end.adding(seconds: by)
        case .trimZoom where !regions.isEmpty:
            let k = Int.random(in: regions, using: &random), by = time(-1.5...1.5)
            if Bool.random(using: &random) {
                document.zoom.regions[k].start = document.zoom.regions[k].start.adding(seconds: by)
            } else {
                document.zoom.regions[k].end = document.zoom.regions[k].end.adding(seconds: by)
            }
        case .deleteZoom where !regions.isEmpty:
            document.zoom.regions.remove(at: Int.random(in: regions, using: &random))
        case .zoomDepth where !regions.isEmpty:
            document.zoom.regions[Int.random(in: regions, using: &random)].depth = Bool.random(using: &random) ? time(1...6) : nil
        case .autoDepth:
            document.zoom.auto.depth = time(1.25...4)
        case .leadIn:
            document.zoom.auto.leadIn = time(0...1.5)
        case .zoomSpring:
            document.zoom.spring = SpringSpec(damping: time(0.6...1.2), response: time(0.3...1.2))
        case .zoomShow:
            document.zoom.show.toggle()
        case .cursorSpring:
            document.cursor.smoothing = .spring(SpringSpec(damping: time(0.6...1.2), response: time(0.08...0.4)))
        case .cursorOff:
            document.cursor.smoothing = document.cursor.smoothing == .off ? smoothed : .off
        case .cursorSize:
            document.cursor.scale = time(0.5...3)
        case .idle:
            if Bool.random(using: &random) { document.cursor.hideWhenIdle.toggle() } else { document.cursor.idleDelay = time(0.5...3) }
        case .cutClip:
            // Out of a clip of at least 3 s of source, a piece of 0.2 to 2 s.
            let long = document.sequence.indices.filter { document.sequence[$0].end.seconds(since: document.sequence[$0].start) >= 3 }
            guard let k = long.randomElement(using: &random) else { break }
            let clip = document.sequence[k]
            let length = clip.end.seconds(since: clip.start), cut = time(0.2...2)
            let at = time(0.5...(length - cut - 0.5))
            var before = clip, after = clip
            before.end = clip.start.adding(seconds: at)
            after.start = clip.start.adding(seconds: at + cut)
            after.id = id("c-")
            document.sequence.replaceSubrange(k...k, with: [before, after])
        case .trimClip:
            // A clip's start or end, by up to 1.5 s, inside its neighbours and keeping 1 s of it.
            let k = Int.random(in: document.sequence.indices, using: &random)
            var clip = document.sequence[k]
            let low = k > 0 ? document.sequence[k - 1].end : source(0)
            let high = k + 1 < document.sequence.count ? document.sequence[k + 1].start : source(seconds)
            if Bool.random(using: &random) {
                clip.start = max(low, min(clip.start.adding(seconds: time(-1.5...1.5)), clip.end.adding(seconds: -1)))
            } else {
                clip.end = min(high, max(clip.end.adding(seconds: time(-1.5...1.5)), clip.start.adding(seconds: 1)))
            }
            document.sequence[k] = clip
        case .speedClip:
            document.sequence[Int.random(in: document.sequence.indices, using: &random)].speed = [0.5, 0.75, 1, 1.5, 2, 3]
                .randomElement(using: &random)!
        case .addSplit:
            let start = time(0...(seconds - 2))
            document.camera.layouts.append(splitBlock(ids + 1, from: start, to: min(start + time(1...20), seconds)))
            document.camera.layouts.sort { $0.start < $1.start }
        case .removeSplit where !document.camera.layouts.isEmpty:
            document.camera.layouts.remove(at: Int.random(in: document.camera.layouts.indices, using: &random))
        case .bubbleChange:
            let style = CameraStyle(
                shape: CameraShape.allCases.randomElement(using: &random)!, size: time(0.1...0.45),
                anchor: CameraAnchor.allCases.randomElement(using: &random)!)
            if !document.camera.changes.isEmpty, Bool.random(using: &random) {
                let k = Int.random(in: document.camera.changes.indices, using: &random)
                document.camera.changes[k].t = document.camera.changes[k].t.adding(seconds: time(-5...5))
                document.camera.changes[k].style = style
            } else {
                document.camera.changes.append(
                    CameraChange(id: id("k-"), take: zoomTakeID, t: source(time(0...seconds)), style: style, origin: .user))
            }
        case .padding:
            document.style.padding = time(0...0.12)
        case .frameTitle:
            document.style.frame = .macWindow(appearance: .dark, title: id("Title "), buttons: Bool.random(using: &random))
        case .undo where !history.isEmpty:
            document = history[history.count - 1]
        default:
            document.zoom.regions.append(randomBlock())
        }
        return document
    }

    /// Whether every query of `paths` gives the bits of `full`'s (of the same document, built from nothing): the
    /// checkpoints of every path (all a query reads of the simulations), the clicks and the releases; over one span of
    /// the whole output of each (the query at a point, over the steps kept), every frame at `frameRate` and, every
    /// `midEvery`-th frame, the instant half way to the next one; at a point (from the checkpoint before it), every
    /// `pointEvery`-th frame, half way to the next one and its step. Past the end too.
    fileprivate static func expectSameBits(
        _ paths: MotionPaths, _ full: MotionPaths, frameRate: Int = 60, midEvery: Int = 10, pointEvery: Int = 60,
        _ label: String, sourceLocation: SourceLocation = #_sourceLocation
    ) {
        func clicks(_ paths: MotionPaths) -> [[UInt64]] {
            paths.cursor.clicks.map { [UInt64(bitPattern: $0.output), $0.point.x.bitPattern, $0.point.y.bitPattern] }
        }
        #expect(paths.timeMap == full.timeMap, "\(label)", sourceLocation: sourceLocation)
        #expect(paths.cursor.checkpoints.map(bits) == full.cursor.checkpoints.map(bits), "\(label)", sourceLocation: sourceLocation)
        #expect(paths.zoom.checkpoints.map(bits) == full.zoom.checkpoints.map(bits), "\(label)", sourceLocation: sourceLocation)
        #expect((paths.cardZoom == nil) == (full.cardZoom == nil), "\(label)", sourceLocation: sourceLocation)
        #expect(
            paths.cardZoom?.checkpoints.map(bits) == full.cardZoom?.checkpoints.map(bits), "\(label)", sourceLocation: sourceLocation)
        #expect(paths.cursor.releases == full.cursor.releases, "\(label)", sourceLocation: sourceLocation)
        #expect(clicks(paths) == clicks(full), "\(label)", sourceLocation: sourceLocation)
        // Where the motion blur is held to one side (1b's final review B-M1).
        #expect(paths.cursor.jumps == full.cursor.jumps, "\(label)", sourceLocation: sourceLocation)
        #expect(paths.zoom.jumps == full.zoom.jumps, "\(label)", sourceLocation: sourceLocation)
        #expect(paths.cardZoom?.jumps == full.cardZoom?.jumps, "\(label)", sourceLocation: sourceLocation)

        let frames = full.timeMap.frameCount(frameRate: frameRate) + 1
        let end = TimeMap.frameTime(frames, frameRate: frameRate)
        let zoom = paths.zoom.span(from: 0, through: end), fullZoom = full.zoom.span(from: 0, through: end)
        let card = paths.cardZoom?.span(from: 0, through: end), fullCard = full.cardZoom?.span(from: 0, through: end)
        let cursor = paths.cursor.span(from: 0, through: end), fullCursor = full.cursor.span(from: 0, through: end)
        var differ: [String] = []
        for n in 0..<frames where differ.count < 3 {
            let τ = TimeMap.frameTime(n, frameRate: frameRate)
            let instants = n % midEvery == 0 ? [τ, (τ + TimeMap.frameTime(n + 1, frameRate: frameRate)) / 2] : [τ]
            for t in instants {
                let a = bits(fullZoom.state(atOutput: t)), b = fullCard.map { bits($0.state(atOutput: t)) }
                let c = bits(fullCursor.sample(atOutput: t))
                if bits(zoom.state(atOutput: t)) != a || card.map({ bits($0.state(atOutput: t)) }) != b
                    || bits(cursor.sample(atOutput: t)) != c
                {
                    differ.append("span at \(t)")
                }
                guard n % pointEvery == 0 else { continue }
                if bits(paths.zoom.state(atOutput: t)) != a || paths.cardZoom.map({ bits($0.state(atOutput: t)) }) != b
                    || bits(paths.cursor.sample(atOutput: t)) != c
                {
                    differ.append("at \(t)")
                }
            }
            guard n % pointEvery == 0 else { continue }
            let s = StepGrid.step(frame: n, frameRate: frameRate)
            if bits(paths.zoom.state(atStep: s)) != bits(fullZoom.state(atOutput: τ))
                || paths.cardZoom.map({ bits($0.state(atStep: s)) }) != fullCard.map({ bits($0.state(atOutput: τ)) })
                || bits(paths.cursor.sample(atStep: s)) != bits(fullCursor.sample(atOutput: τ))
            {
                differ.append("on step \(s)")
            }
        }
        #expect(differ.isEmpty, "\(label): \(differ)", sourceLocation: sourceLocation)
    }
}

extension ZoomFixtures {
    @Suite struct MotionPathsIncrementalTests {
        /// Chains of edits of every kind, in a random order, each rebuilt from the paths of the edit before it (rebuilt
        /// too), over a take of about 5 minutes of output. A toggle (the zoom shown, the cursor's smoothing off) comes
        /// back with the next edit, so the edits after it still move the cameras and the spring; most edits keep some
        /// checkpoints and simulate some, and some of zoom blocks alone take the old cameras' tail.
        @Test(arguments: [0x6564_6974_0001, 0x6564_6974_0002] as [UInt64])
        func incrementalEqualsFullForRandomEdits(seed: UInt64) {
            let seconds = 330.0
            let take = zoomTake(camera: true, seconds: seconds + 1)
            let events = wanderingEvents(seconds: seconds)
            var random = ZoomRandom(seed: seed)
            var document = editedTakeDocument(seconds: seconds)
            var paths = MotionPaths(take: take, events: events, document: document)
            var history: [EditDocument] = []
            var partial = 0, spliced = 0
            let edits = PathEdit.allCases.shuffled(using: &random).flatMap { [.zoomShow, .cursorOff].contains($0) ? [$0, $0] : [$0] }
            for edit in edits {
                let next = edited(document, by: edit, seconds: seconds, history: history, random: &random)
                history.append(document)
                document = next
                paths = MotionPaths(take: take, events: events, document: document, after: paths)
                let full = MotionPaths(take: take, events: events, document: document)
                expectSameBits(paths, full, "\(edit)")
                let simulated = [paths.cursor.simulatedSteps, paths.zoom.simulatedSteps, paths.cardZoom?.simulatedSteps ?? 0]
                if simulated.contains(where: { $0 > 0 && $0 < full.zoom.simulatedSteps }) { partial += 1 }
                if paths.zoom.splicedAt != nil || paths.cardZoom?.splicedAt != nil { spliced += 1 }
            }
            #expect(partial >= 6, "\(partial) of \(edits.count)")
            #expect(spliced >= 2, "\(spliced) of \(edits.count)")
        }

        /// An edit at 50 minutes of an hour simulates the last 10 minutes and the second before it, at most: of the
        /// cursor's spring, the stage's camera and the card's; none of a path it changes nothing of.
        @Test func editLateInTheTakeSimulatesOnlyTheTail() throws {
            let hour = 3_600.0
            let take = zoomTake(camera: true, seconds: hour + 1)
            let events = wanderingEvents(seconds: hour, rate: 10)
            var document = editedTakeDocument(seconds: hour)
            document.sequence = [zoomClip(1, from: 0, to: hour)]
            let paths = MotionPaths(take: take, events: events, document: document)
            #expect(paths.zoom.simulatedSteps == steps(hour) + 1 && paths.cardZoom?.simulatedSteps == steps(hour) + 1)
            #expect(paths.cursor.simulatedSteps == steps(hour) + 1)

            let late = 50 * 60.0, tail = steps(11 * 60)
            var moved = document, cut = document, bubble = document, split = document, size = document
            let k = moved.zoom.regions.firstIndex { $0.start >= source(late) }!
            moved.zoom.regions[k].start = moved.zoom.regions[k].start.adding(seconds: -0.7)
            cut.sequence = [zoomClip(1, from: 0, to: late), zoomClip(2, from: late + 1.5, to: hour)]
            bubble.camera.changes.append(CameraChange(
                id: "k-00000009", take: zoomTakeID, t: source(late), style: CameraStyle(shape: .portrait, size: 0.2, anchor: .top),
                origin: .user))
            split.camera.layouts.append(splitBlock(9, from: late, to: late + 20))
            size.cursor.scale = 2.5
            // (cursor, stage's camera, card's camera): the most steps each can simulate.
            let cases: [(String, EditDocument, (Int, Int, Int))] = [
                ("a zoom moved", moved, (0, tail, tail)), ("a cut", cut, (tail, tail, tail)),
                ("a change of the bubble", bubble, (0, tail, 0)), ("a split added", split, (0, 0, 0)),
                ("the cursor's size", size, (0, 0, 0)),
            ]
            for (name, edited, most) in cases {
                let rebuilt = MotionPaths(take: take, events: events, document: edited, after: paths)
                let card = try #require(rebuilt.cardZoom, "\(name)")
                let simulated = (rebuilt.cursor.simulatedSteps, rebuilt.zoom.simulatedSteps, card.simulatedSteps)
                #expect(simulated.0 <= most.0 && simulated.1 <= most.1 && simulated.2 <= most.2, "\(name): \(simulated)")
                #expect(simulated.1 > 0 || most.1 == 0, "\(name): \(simulated)")
            }
            // The cut, the most there is to simulate again, with the bits of the paths built from nothing.
            let rebuilt = MotionPaths(take: take, events: events, document: cut, after: paths)
            let full = MotionPaths(take: take, events: events, document: cut)
            #expect(rebuilt.cursor.checkpoints.map(bits) == full.cursor.checkpoints.map(bits))
            #expect(rebuilt.zoom.checkpoints.map(bits) == full.zoom.checkpoints.map(bits))
            #expect(rebuilt.cardZoom?.checkpoints.map(bits) == full.cardZoom?.checkpoints.map(bits))
        }

        /// An edit at the first second (a zoom, a trim of the first clip, the cursor's spring) simulates every path it
        /// changes from output 0: all of it, or, after an edit of zoom blocks alone, up to the checkpoint from which a
        /// camera takes the old one's tail; with the bits of the paths built from nothing.
        @Test func editAtTheStartRebuildsEverything() {
            let seconds = 330.0
            let take = zoomTake(camera: true, seconds: seconds + 1)
            let events = wanderingEvents(seconds: seconds)
            let document = editedTakeDocument(seconds: seconds)
            let paths = MotionPaths(take: take, events: events, document: document)
            var zoomed = document, trimmed = document, spring = document
            zoomed.zoom.regions.insert(block(99, from: 0.2, to: 1.2, depth: 2.5), at: 0)
            trimmed.sequence[0].start = source(0.5)
            spring.cursor.smoothing = .spring(SpringSpec(damping: 0.8, response: 0.25))
            for (name, edited, cursorToo) in [("a zoom", zoomed, false), ("a trim", trimmed, true), ("the cursor", spring, true)] {
                let rebuilt = MotionPaths(take: take, events: events, document: edited, after: paths)
                let all = StepGrid.firstStep(atOrAfter: rebuilt.timeMap.duration) + 1
                // From step -1, the run before output 0.
                #expect(rebuilt.zoom.simulatedSteps == rebuilt.zoom.splicedAt.map { $0 + 1 } ?? all, "\(name)")
                let card = rebuilt.cardZoom
                #expect(card?.simulatedSteps == card.map { $0.splicedAt.map { $0 + 1 } ?? all }, "\(name)")
                #expect(cursorToo || rebuilt.zoom.splicedAt != nil, "\(name)")
                #expect(rebuilt.cursor.simulatedSteps == (cursorToo ? all : 0), "\(name)")
                expectSameBits(rebuilt, MotionPaths(take: take, events: events, document: edited), name)
            }
        }

        /// An edit of zoom blocks alone in the middle of a take (a block added, one deleted, one moved): each camera takes
        /// the old one's tail as soon as it is bit for bit the old camera again on a checkpoint after the blocks the edit
        /// changed, the index of its block moved by the blocks added or deleted, so it simulates a few seconds; with the
        /// bits of the paths built from nothing.
        @Test func aZoomEditTakesTheOldTailOnceTheCameraIsBack() throws {
            let seconds = 330.0
            let take = zoomTake(camera: true, seconds: seconds + 1)
            let events = wanderingEvents(seconds: seconds)
            let document = editedTakeDocument(seconds: seconds)
            let paths = MotionPaths(take: take, events: events, document: document)
            var added = document, deleted = document, moved = document
            let k = document.zoom.regions.firstIndex { $0.start >= source(120) }!
            added.zoom.regions.insert(block(98, from: 118, to: 119.5, depth: 2.2, focus: .fixed(x: 0.3, y: 0.6)), at: k)
            deleted.zoom.regions.remove(at: k)
            moved.zoom.regions[k].start = moved.zoom.regions[k].start.adding(seconds: 0.6)
            moved.zoom.regions[k].end = moved.zoom.regions[k].end.adding(seconds: 0.6)
            for (name, edited) in [("added", added), ("deleted", deleted), ("moved", moved)] {
                let rebuilt = MotionPaths(take: take, events: events, document: edited, after: paths)
                let card = try #require(rebuilt.cardZoom, "\(name)")
                #expect(rebuilt.zoom.splicedAt != nil && card.splicedAt != nil, "\(name)")
                #expect(rebuilt.zoom.simulatedSteps <= steps(30) && card.simulatedSteps <= steps(30), "\(name)")
                #expect(rebuilt.cursor.simulatedSteps == 0, "\(name)")
                expectSameBits(rebuilt, MotionPaths(take: take, events: events, document: edited), name)
            }
        }

        /// A camera that is not the old one again on any checkpoint after the edit (a slow spring that keeps swinging to
        /// the end of the take) simulates the whole rest, as without the old tail.
        @Test func aCameraThatNeverComesBackSimulatesTheRest() {
            let seconds = 120.0
            let take = zoomTake(camera: true, seconds: seconds + 1)
            let events = wanderingEvents(seconds: seconds)
            var document = editedTakeDocument(seconds: seconds)
            // No instant block either, whose end puts the camera at rest exactly.
            document.zoom.spring = SpringSpec(damping: 0.2, response: 4)
            for k in document.zoom.regions.indices { document.zoom.regions[k].instant = false }
            let paths = MotionPaths(take: take, events: events, document: document)
            var moved = document
            let k = document.zoom.regions.lastIndex { $0.start <= source(100) }!
            moved.zoom.regions[k].depth = 4
            let rebuilt = MotionPaths(take: take, events: events, document: moved, after: paths)
            let full = MotionPaths(take: take, events: events, document: moved)
            #expect(rebuilt.zoom.splicedAt == nil && rebuilt.cardZoom?.splicedAt == nil)
            #expect(rebuilt.zoom.simulatedSteps > steps(15) && rebuilt.zoom.simulatedSteps < full.zoom.simulatedSteps)
            expectSameBits(rebuilt, full, "a block of the last part")
        }

        /// A split that comes (a block of the camera track), goes and comes back with a zoom edit: the card's camera is
        /// built from output 0 when it appears, dropped when it goes, and, with one before, rebuilt at once with the
        /// stage's (`MotionPaths.atOnce`); each time with the bits of the paths built from nothing.
        @Test func theCardsCameraComesAndGoes() throws {
            let seconds = 60.0
            let take = zoomTake(camera: true, seconds: seconds + 1)
            let events = wanderingEvents(seconds: seconds)
            var none = editedTakeDocument(seconds: seconds)
            none.camera.layouts = []
            var split = none
            split.camera.layouts = [splitBlock(1, from: 20, to: 30)]
            var zoomed = split
            zoomed.zoom.regions[2].start = zoomed.zoom.regions[2].start.adding(seconds: -1)
            var paths = MotionPaths(take: take, events: events, document: none)
            #expect(paths.cardZoom == nil)
            let all = StepGrid.firstStep(atOrAfter: paths.timeMap.duration) + 1
            for (name, document) in [("split", split), ("no split", none), ("split again", split), ("a zoom", zoomed)] {
                let had = paths.cardZoom != nil
                paths = MotionPaths(take: take, events: events, document: document, after: paths)
                let full = MotionPaths(take: take, events: events, document: document)
                expectSameBits(paths, full, name)
                switch name {
                case "no split":
                    #expect(paths.cardZoom == nil)
                case "a zoom":
                    let card = try #require(paths.cardZoom).simulatedSteps
                    #expect(had && (1..<all).contains(paths.zoom.simulatedSteps) && (1..<all).contains(card))
                default:
                    #expect(!had && paths.zoom.simulatedSteps == 0, "\(name)")
                    #expect(try #require(paths.cardZoom, "\(name)").simulatedSteps == all, "\(name)")
                }
            }
        }

        /// What reads ahead of an edit (the cursor landing on a click 0.5 s ahead, the zoom camera following that cursor)
        /// is simulated again: a cut of 0.1 s just before a click brings the click, and the landing on it, 0.1 s earlier,
        /// to before the checkpoint of the whole second the cut is in.
        @Test func aClickAheadOfAnEditIsLandedOnAgain() {
            let take = zoomTake(seconds: 21)
            // A position every whole second, so nothing but the click changes before the cut.
            var events = (0...20).map { pointer(Double($0), wander(Double($0))) }
            let click = wander(5.4)
            events += [
                InputEvent(t: source(5.4), kind: .mouseDown(.left, x: click.x, y: click.y)),
                InputEvent(t: source(5.48), kind: .mouseUp(.left, x: click.x, y: click.y)),
            ]
            events = events.sortedByTime()
            let document = zoomDocument(
                regions: [block(1, from: 3, to: 9)], smoothing: smoothed, layout: CameraLayout(kind: .split))
            var cut = document
            cut.sequence = [zoomClip(1, from: 0, to: 5.25), zoomClip(2, from: 5.35, to: 20)]
            let paths = MotionPaths(take: take, events: events, document: document)
            let rebuilt = MotionPaths(take: take, events: events, document: cut, after: paths)
            let full = MotionPaths(take: take, events: events, document: cut)
            // The landing on the click now starts at 4.8 s, before the checkpoint at 5 s, which is simulated again.
            #expect(full.cursor.state(atStep: steps(5)) != paths.cursor.state(atStep: steps(5)))
            #expect(rebuilt.cursor.simulatedSteps > steps(15) && rebuilt.zoom.simulatedSteps > steps(15))
            expectSameBits(rebuilt, full, pointEvery: 1, "a cut before a click")
        }

        /// The first instant at which the time map of an edited sequence can differ: the start of its first clip that
        /// differs, or the end of the shorter one when only its end does; none for a clip's ID.
        @Test func theTimeMapChangesFromItsFirstClipThatDiffers() {
            let clips = [zoomClip(1, from: 0, to: 10), zoomClip(2, from: 12, to: 20, speed: 2)]
            func first(_ edited: [Clip]) -> Int64? {
                MotionPaths.firstChangedOutput(clips, TimeMap(sequence: clips), edited, TimeMap(sequence: edited))
            }
            var renamed = clips, shorter = clips, longer = clips, later = clips, faster = clips, otherTake = clips
            renamed[0].id = "c-0000000a"
            shorter[0].end = source(6)
            longer[1].end = source(24)
            later[1].start = source(13)
            faster[1].speed = 4
            otherTake[0].take = "take-002"
            let cut = [zoomClip(1, from: 0, to: 4), zoomClip(3, from: 5, to: 10), clips[1]]
            let added = clips + [zoomClip(4, from: 21, to: 22)]
            #expect(first(clips) == nil && first(renamed) == nil)
            #expect(first(shorter) == output(6))
            #expect(first(cut) == output(4))
            // The second clip lasts 4 s of output; 6 s at its new end.
            #expect(first(longer) == output(14))
            #expect(first(later) == output(10) && first(faster) == output(10))
            #expect(first(otherTake) == 0)
            #expect(first(added) == output(14) && first(Array(clips.prefix(1))) == output(10))
        }

        /// The first instant at which the camera's bubble can differ: that of the first of the take's changes, placed in
        /// the output, that differs; 0 when it shows, starts or is measured otherwise; none when it is hidden in both.
        @Test func theBubbleChangesFromItsFirstChangeThatDiffers() {
            let clips = [zoomClip(1, from: 0, to: 20)]
            let styles = [CameraStyle(shape: .portrait, size: 0.2, anchor: .top), CameraStyle(shape: .landscape, size: 0.3, anchor: .leading)]
            let camera = CameraPlan(
                show: true, initial: [zoomTakeID: .default],
                changes: [
                    CameraChange(id: "k-00000001", take: zoomTakeID, t: source(5), style: styles[0], origin: .user),
                    CameraChange(id: "k-00000002", take: zoomTakeID, t: source(9), style: styles[1], origin: .user),
                ])
            func first(_ edited: CameraPlan, _ sequence: [Clip] = clips) -> Int64? {
                MotionPaths.firstChangedBubbleOutput(
                    camera, TimeMap(sequence: clips), edited, TimeMap(sequence: sequence), take: zoomTakeID)
            }
            var moved = camera, added = camera, restyled = camera, other = camera, initial = camera, hidden = camera
            var measured = camera
            moved.changes[1].t = source(11)
            added.changes.append(CameraChange(id: "k-00000003", take: zoomTakeID, t: source(7), style: styles[0], origin: .user))
            restyled.changes[0].style = styles[1]
            other.changes.append(CameraChange(id: "k-00000004", take: "take-002", t: source(1), style: styles[0], origin: .user))
            initial.initial[zoomTakeID] = styles[1]
            hidden.show = false
            measured.sizeReference = .shortSide
            #expect(first(camera) == nil && first(other) == nil)
            #expect(first(moved) == output(9) && first(added) == output(7) && first(restyled) == output(5))
            #expect(first(initial) == 0 && first(hidden) == 0 && first(measured) == 0)
            // Placed by the edited time map: a cut of 1 s before the second change brings it to 8 s.
            #expect(first(camera, [zoomClip(1, from: 0, to: 7), zoomClip(2, from: 8, to: 20)]) == output(8))
            var bothHidden = hidden
            bothHidden.changes = []
            #expect(MotionPaths.firstChangedBubbleOutput(
                hidden, TimeMap(sequence: clips), bothHidden, TimeMap(sequence: clips), take: zoomTakeID) == nil)
        }

        /// The rebuild after an edit of an hour of take (1b design §7.9: ≤ 20 ms on the owner's Mac; 1c design §15: ≤ 30 ms
        /// with the card's camera), Task 8's synthetic hour: a pointer that never stops, at 60 Hz, and a click every 5 s,
        /// the automatic zoom's blocks over them, the smoothed cursor, with a split from 10 to 20 minutes and without one.
        /// The edits: a zoom block moved by 0.5 s, and a cut of 1 s of source, in the middle of the hour and at its last
        /// minute. Run by an agent, with `TOMA_BENCH=1`, in release; printed and recorded in docs/performance.md. It asserts
        /// the goal for the zoom edits, which take the old cameras' tail wherever they are, and, for a cut, which shifts
        /// all that follows it, only that one at the end costs less than a quarter of building the paths from nothing (a
        /// cut there places every event again: about a twentieth).
        @Test(.enabled(if: ProcessInfo.processInfo.environment["TOMA_BENCH"] == "1"))
        func rebuildingAnHourAfterAnEdit() throws {
            let hour = 3_600.0
            let take = zoomTake(seconds: hour + 1)
            func at(_ t: Double) -> SIMD2<Double> { SIMD2(720 + 600 * cos(0.37 * t) * sin(0.11 * t), 450 + 380 * sin(0.53 * t)) }
            var events = trail(from: 0, to: hour, at)
            for k in 1..<Int(hour / 5) {
                let t = 5 * Double(k), point = at(t)
                events.append(InputEvent(t: source(t), kind: .mouseDown(.left, x: point.x, y: point.y)))
                events.append(InputEvent(t: source(t + 0.08), kind: .mouseUp(.left, x: point.x, y: point.y)))
            }
            events = events.sortedByTime()
            var split = zoomDocument(
                sequence: [zoomClip(1, from: 0, to: hour)], smoothing: smoothed, layout: .bubble,
                layouts: [splitBlock(1, from: 600, to: 1_200)])
            split.zoom.regions = AutoZoomPlanner.plan(take: take, events: events, document: split)
            var noSplit = split
            noSplit.camera.layouts = []

            func moved(_ document: EditDocument, at t: Double) -> EditDocument {
                var document = document
                let k = document.zoom.regions.firstIndex { $0.start >= source(t) }!
                document.zoom.regions[k].start = document.zoom.regions[k].start.adding(seconds: -0.5)
                document.zoom.regions[k].end = document.zoom.regions[k].end.adding(seconds: -0.5)
                return document
            }
            func cut(_ document: EditDocument, at t: Double) -> EditDocument {
                var document = document
                document.sequence = [zoomClip(1, from: 0, to: t), zoomClip(2, from: t + 1, to: hour)]
                return document
            }
            let clock = ContinuousClock()
            func ms(_ duration: Duration) -> String { String(format: "%.1f ms", duration / .milliseconds(1)) }
            /// The median of 5 after one to warm up.
            func median(_ work: () -> Void) -> Duration {
                work()
                return (0..<5).map { _ in clock.measure(work) }.sorted()[2]
            }
            var lines: [String] = []
            for (name, document) in [("with the split", split), ("without a split", noSplit)] {
                let paths = MotionPaths(take: take, events: events, document: document)
                let full = median { _ = MotionPaths(take: take, events: events, document: document) }
                var row = "\(name): from nothing \(ms(full))"
                for (when, t) in [("the middle", hour / 2), ("the end", hour - 30)] {
                    for (edit, edited) in [("a zoom moved", moved(document, at: t)), ("a cut", cut(document, at: t))] {
                        let rebuilt = median { _ = MotionPaths(take: take, events: events, document: edited, after: paths) }
                        row += "; \(edit) at \(when) \(ms(rebuilt))"
                        let goal = Duration.milliseconds(document.camera.layouts.isEmpty ? 20 : 30)
                        if edit == "a zoom moved" {
                            #expect(rebuilt <= goal, "\(name), \(edit) at \(when): \(ms(rebuilt))")
                        } else if t > hour / 2 {
                            #expect(rebuilt < full / 4, "\(name), \(edit) at \(when): \(ms(rebuilt))")
                        }
                    }
                }
                lines.append(row)
            }
            print("rebuildingAnHourAfterAnEdit (\(split.zoom.regions.count) blocks, \(events.count) events): " + lines.joined(separator: " | "))
        }
    }
}
