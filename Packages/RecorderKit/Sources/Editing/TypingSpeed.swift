// SPDX-License-Identifier: GPL-3.0-or-later
import Analysis
import ProjectFormat

/// `typingSpeed-1` (phase 2 design §7.5): the stretches of typing sped up. A stretch is an `Activity.typing` span of at
/// least 2 s (typing as `keyActivity` shows it, never the keys), shrunk 0.25 s on each side and taken to the source; the
/// clips it falls in are split at its edges and the piece inside plays at the speed chosen. It is one step (`.speedTyping`).
///
/// - A clip that does not play at 1× is left alone, whatever falls in it, and so is a clip with content (a point of its
///   take, which no stretch falls in).
/// - A stretch across a cut gives one piece in each clip it covers.
/// - No clip is left shorter than a frame (plan decision 24): an edge that would leave a piece shorter than that is not
///   made, and the sped piece goes on to the edge of the clip (or to the next sped piece) instead; a piece that would last
///   less than a frame once sped is not sped.
/// - Every id and number of the rule is frozen with its id: a change to any of them is a new rule.
/// - With several takes in the sequence (phase 3 design §8.1, plan 3d decision 17), each take's typing is found in its
///   own clips by its own events, and every take's stretches are sped up in the one step; with one take, it is the
///   phase 2's.
public enum TypingSpeed {
    public static let id = "typingSpeed-1"
    /// The speeds the popover offers.
    public static let speeds: [Double] = [2, 3, 4, 8]
    public static let defaultSpeed = 3.0
    /// The least a typing span lasts to be sped up: 2 s.
    public static let minimumSpan: Int64 = 2_000_000_000
    /// What each side of a span gives back to normal speed: 0.25 s.
    public static let inset: Int64 = 250_000_000

    /// What a speed gives: the stretches it speeds up, and what they last in the output before and after, in ns.
    public struct Summary: Equatable, Sendable {
        public var count: Int
        public var before: Int64
        public var after: Int64

        public init(count: Int, before: Int64, after: Int64) {
            self.count = count
            self.before = before
            self.after = after
        }
    }

    /// The source of the stretches to speed up, one range for each clip a stretch covers that plays at 1×, in the order of
    /// the sequence. Empty with no typing of `minimumSpan` or more.
    public static func spans(_ doc: EditDocument, take: TakeRecord, events: [InputEvent]) -> [SourceRange] {
        candidates(doc, take: take, events: events).flatMap { clip in
            clip.ranges.map { SourceRange(take: take.id, start: $0.start, end: $0.end) }
        }
    }

    /// What `apply` with `speed` would give.
    public static func summary(_ doc: EditDocument, take: TakeRecord, events: [InputEvent], speed: Double) -> Summary {
        summary(doc, takes: [(take, events)], speed: speed)
    }

    /// What `apply(_:takes:speed:makeID:)` with `speed` would give: the stretches of every take, and what they last.
    public static func summary(_ doc: EditDocument, takes: [(TakeRecord, [InputEvent])], speed: Double) -> Summary {
        let speed = ClipSpeed.clamped(speed)
        var (count, before, after): (Int, Int64, Int64) = (0, 0, 0)
        for (take, events) in distinct(takes) {
            var stretches = Set<Int>()
            for clip in plan(doc, take: take, events: events, speed: speed) {
                for piece in clip.pieces where piece.speed != 1 {
                    stretches.formUnion(piece.stretches)
                    before += Int64(piece.end.nanoseconds - piece.start.nanoseconds)
                    after += TimeMap.outputDuration(of: piece.clip(id: "", take: take.id))
                }
            }
            count += stretches.count
        }
        return Summary(count: count, before: before, after: after)
    }

    /// The step that speeds the stretches up to `speed` (clamped to `ClipSpeed.range`), the new clips with the ids
    /// `makeID("c-")` gives; its target the ids of the clips it touched, in the order of the sequence. `nil` with nothing to
    /// speed up.
    public static func apply(
        _ doc: EditDocument, take: TakeRecord, events: [InputEvent], speed: Double, makeID: (String) -> String
    ) -> EditStep? {
        apply(doc, takes: [(take, events)], speed: speed, makeID: makeID)
    }

    /// `apply(_:take:events:speed:makeID:)` of every take of `takes` (each with its events; a take given twice, the first
    /// time), in one step: the clips of each take split by its own stretches, the new ids made in the order of the
    /// sequence, whatever the order of `takes`.
    public static func apply(
        _ doc: EditDocument, takes: [(TakeRecord, [InputEvent])], speed: Double, makeID: (String) -> String
    ) -> EditStep? {
        let speed = ClipSpeed.clamped(speed)
        // Each take's clips are its own, so the plans never share one.
        let clips = distinct(takes).flatMap { plan(doc, take: $0.0, events: $0.1, speed: speed) }.sorted { $0.index < $1.index }
        guard !clips.isEmpty else { return nil }
        var ids = Set(doc.sequence.map(\.id))
        // A clip sped up heard sooner reads further back in its take: the cuts held to what each of `takes` has.
        let bounds = Dictionary(distinct(takes).map { take, events in
            let editable = TakeTimeline.editableBounds(take: take, events: events)
            return (take.id, editable.start...editable.end)
        }) { first, _ in first }
        var changes = SequenceChanges(doc.sequence, takeBounds: bounds)
        var inserted = 0
        var touched: [String] = []
        for clip in clips {
            let original = doc.sequence[clip.index]
            touched.append(original.id)
            // The first piece starts where the clip did, its cut of the sound with it; the others start theirs with the
            // picture.
            var first = clip.pieces[0].clip(id: original.id, take: original.take)
            first.audioShift = original.audioShift
            changes.replace(original, with: first)
            for piece in clip.pieces.dropFirst() {
                inserted += 1
                let id = SequenceCommands.newID(makeID, avoiding: &ids)
                changes.insert(piece.clip(id: id, take: original.take), at: clip.index + inserted)
            }
        }
        return EditStep(label: .speedTyping, target: touched.joined(separator: ","), changes: changes.changes)
    }

    // MARK: - Private

    /// `takes` with each take once (by its id), the first time it is given.
    private static func distinct(_ takes: [(TakeRecord, [InputEvent])]) -> [(TakeRecord, [InputEvent])] {
        var seen: Set<String> = []
        return takes.filter { seen.insert($0.0.id).inserted }
    }

    /// A piece of a clip: at 1× or sped, with the stretches it holds.
    private struct Piece {
        var start: HostTime
        var end: HostTime
        var speed: Double
        var stretches: Set<Int>

        func clip(id: String, take: String) -> Clip {
            Clip(id: id, take: take, start: start, end: end, speed: speed)
        }
    }

    /// A clip at 1× and the source ranges of the stretches in it, each with its stretch.
    private struct Candidate {
        var index: Int
        var ranges: [(start: HostTime, end: HostTime, stretch: Int)]
    }

    /// A clip the step splits: its position in the sequence and its pieces, in order, at least one of them sped.
    private struct ClipPlan {
        var index: Int
        var pieces: [Piece]
    }

    /// The stretches in the output of `doc`: the spans of typing of two seconds or more, shrunk on both sides.
    private static func stretches(_ doc: EditDocument, take: TakeRecord, events: [InputEvent]) -> [Range<Int64>] {
        let map = TimeMap(sequence: doc.sequence)
        return Activity.extract(take: take, events: events, document: doc, timeMap: map).typing.compactMap { span in
            guard span.upperBound - span.lowerBound >= minimumSpan else { return nil }
            let shrunk = (span.lowerBound + inset)..<(span.upperBound - inset)
            return shrunk.isEmpty ? nil : shrunk
        }
    }

    /// The clips at 1× of `take` that the stretches fall in, with where.
    private static func candidates(_ doc: EditDocument, take: TakeRecord, events: [InputEvent]) -> [Candidate] {
        let found = stretches(doc, take: take, events: events)
        guard !found.isEmpty else { return [] }
        let map = TimeMap(sequence: doc.sequence)
        var result: [Candidate] = []
        for (k, clip) in doc.sequence.enumerated() where clip.take == take.id && ClipSpeed.clamped(clip.speed) == 1 {
            guard clip.content == nil, clip.start < clip.end else { continue }
            let start = map.clipOutputStarts[k]
            let end = start + TimeMap.outputDuration(of: clip)
            var ranges: [(start: HostTime, end: HostTime, stretch: Int)] = []
            for (i, stretch) in found.enumerated() {
                let (lo, hi) = (max(stretch.lowerBound, start), min(stretch.upperBound, end))
                guard lo < hi else { continue }
                // At 1× the source goes as the output does.
                let s = HostTime(nanoseconds: clip.start.nanoseconds + UInt64(lo - start))
                let e = HostTime(nanoseconds: min(clip.start.nanoseconds + UInt64(hi - start), clip.end.nanoseconds))
                ranges.append((s, e, i))
            }
            if !ranges.isEmpty { result.append(Candidate(index: k, ranges: ranges)) }
        }
        return result
    }

    /// The clips split, each as its pieces.
    private static func plan(_ doc: EditDocument, take: TakeRecord, events: [InputEvent], speed: Double) -> [ClipPlan] {
        let frame = SequenceCommands.oneFrame(of: doc)
        func lasts(_ start: HostTime, _ end: HostTime, speed: Double) -> Bool {
            SequenceCommands.lasts(Clip(id: "", take: "", start: start, end: end, speed: speed), frame)
        }
        var plans: [ClipPlan] = []
        for candidate in candidates(doc, take: take, events: events) {
            let clip = SequenceCommands.written(doc.sequence[candidate.index])
            // The sped pieces: a range that would last less than a frame sped stays at 1×.
            var sped: [Piece] = candidate.ranges.filter { lasts($0.start, $0.end, speed: speed) }
                .map { Piece(start: $0.start, end: $0.end, speed: speed, stretches: [$0.stretch]) }
            guard !sped.isEmpty else { continue }
            // A gap at 1× shorter than a frame goes to the sped piece next to it, or joins the two around it.
            if !lasts(clip.start, sped[0].start, speed: 1) { sped[0].start = clip.start }
            if !lasts(sped[sped.count - 1].end, clip.end, speed: 1) { sped[sped.count - 1].end = clip.end }
            var merged: [Piece] = []
            for piece in sped {
                if var last = merged.last, !lasts(last.end, piece.start, speed: 1) {
                    last.end = piece.end
                    last.stretches.formUnion(piece.stretches)
                    merged[merged.count - 1] = last
                } else {
                    merged.append(piece)
                }
            }
            var pieces: [Piece] = []
            var cursor = clip.start
            for piece in merged {
                if cursor < piece.start { pieces.append(Piece(start: cursor, end: piece.start, speed: 1, stretches: [])) }
                pieces.append(piece)
                cursor = piece.end
            }
            if cursor < clip.end { pieces.append(Piece(start: cursor, end: clip.end, speed: 1, stretches: [])) }
            plans.append(ClipPlan(index: candidate.index, pieces: pieces))
        }
        return plans
    }
}
