// SPDX-License-Identifier: GPL-3.0-or-later
import ProjectFormat

/// The commands of the sequence by source ranges (phase 2 design §5.3 and §5.4, plan decision 6): what editing by the
/// transcript takes out of the clips of a take and gives back to them, whatever clips and speeds those source times are
/// in. The rules of `SequenceCommands` hold: no clip shorter than a frame, the speeds as `ClipSpeed.clamped(_:)` reads
/// them, each clip with content left where it is (a point of its take, which no source range takes out and none given
/// back goes across), the cuts of the sound held to their limits, the changes built from the clips they touch and the
/// target the ids of those clips in the order of the sequence.
extension SequenceCommands {
    /// Takes out of the clips of `take` the source that falls in the union of `ranges`, in one step labelled `label`: a
    /// clip inside it is removed, one across an edge trimmed to it, and one with a range inside it cut in two, its second
    /// piece a new clip with the id `makeID("c-")`. A piece shorter than a frame goes with the cut, as with `deleteRange`.
    /// `.failure(.lastClip)` if no clip of at least a frame would be left; nothing in the ranges gives a step without
    /// changes.
    public static func deleteSource(
        _ doc: EditDocument, take: String, ranges: [Range<HostTime>], label: EditLabel, makeID: (String) -> String
    ) -> Result<EditStep, SequenceError> {
        deleteSource(doc, ranges: [take: ranges], label: label, makeID: makeID)
    }

    /// Gives back to the sequence the source of `take` in `range`, clamped to `bounds` (the take's
    /// `TakeTimeline.editableBounds`), that no clip of the take keeps (plan decision 6). Each missing piece plays at the
    /// speed of the clip of the take before it in the source (without one, of the one after it; without either, 1×): it
    /// lengthens that clip if it starts where the clip ends; if not, the clip after it if it ends where that one starts
    /// and has that speed; if not, it is a new clip with the id `makeID("c-")` in its place of the source, right after the
    /// clip before it in the sequence (or right before the one after it, or at the end), if it lasts a frame. A clip with
    /// content of the take is a point the pieces never go across (phase 3 design §9): a piece with one inside is given
    /// back on each side of it, a piece is placed after a point at or before its start and before one at or after its end,
    /// and a clip is not lengthened over one. Clips are never joined, so every id stays. Labelled `.transcriptRestore`;
    /// `nil` if there is nothing to give back.
    public static func restore(
        _ doc: EditDocument, take: String, range: Range<HostTime>, bounds: ClosedRange<HostTime>, makeID: (String) -> String
    ) -> EditStep? {
        restore(doc, take: take, ranges: [range], bounds: bounds, makeID: makeID)
    }

    // MARK: - Internal

    /// `deleteSource` over the ranges of several takes at once, by take: one pass over the sequence, so the step of
    /// several takes is one step.
    static func deleteSource(
        _ doc: EditDocument, ranges: [String: [Range<HostTime>]], label: EditLabel, makeID: (String) -> String
    ) -> Result<EditStep, SequenceError> {
        let cuts = ranges.mapValues(union)
        let frame = oneFrame(of: doc)
        var ids = Set(doc.sequence.map(\.id))
        var changes = SequenceChanges(doc.sequence)
        var touched: [String] = []
        // Removed and inserted so far, for the index of the next change.
        var (removed, inserted) = (0, 0)
        var leavesAFrame = false
        for (k, original) in doc.sequence.enumerated() {
            let inside = (cuts[original.take] ?? []).filter { $0.lowerBound < original.end && $0.upperBound > original.start }
            guard original.content == nil, original.start < original.end, !inside.isEmpty else {
                leavesAFrame = leavesAFrame || lasts(original, frame)
                continue
            }
            touched.append(original.id)
            let clip = written(original)
            // What is left of it between the ranges, in source order, each at least a frame long.
            var pieces: [Clip] = []
            var from = clip.start
            for cut in inside {
                if from < cut.lowerBound { pieces.append(piece(of: clip, from..<cut.lowerBound)) }
                from = max(from, cut.upperBound)
            }
            if from < clip.end { pieces.append(piece(of: clip, from..<clip.end)) }
            pieces = pieces.filter { lasts($0, frame) }
            let index = k - removed + inserted
            guard let first = pieces.first else {
                changes.remove(original, at: index)
                removed += 1
                continue
            }
            leavesAFrame = true
            changes.replace(original, with: first)
            for var next in pieces.dropFirst() {
                next.id = newID(makeID, avoiding: &ids)
                next.audioShift = 0
                inserted += 1
                changes.insert(next, at: k - removed + inserted)
            }
        }
        guard !touched.isEmpty else { return .success(EditStep(label: label, target: "", changes: [])) }
        guard leavesAFrame else { return .failure(.lastClip) }
        return .success(EditStep(label: label, target: touched.joined(separator: ","), changes: changes.changes))
    }

    /// `restore` of the union of `ranges`, in one step.
    static func restore(
        _ doc: EditDocument, take: String, ranges: [Range<HostTime>], bounds: ClosedRange<HostTime>,
        makeID: (String) -> String
    ) -> EditStep? {
        let wanted = union(
            ranges.compactMap { range in
                let (start, end) = (max(range.lowerBound, bounds.lowerBound), min(range.upperBound, bounds.upperBound))
                return start < end ? start..<end : nil
            })
        let kept = union(doc.sequence.filter { $0.take == take && $0.start < $0.end && $0.content == nil }.map { $0.start..<$0.end })
        // The points of the take's clips with content split what is missing: each piece is on one side of every point.
        let points = Set(doc.sequence.filter { $0.take == take && $0.content != nil }.map(\.start)).sorted()
        let missing = subtracting(kept, from: wanted).flatMap { piece in
            let inside = points.filter { piece.lowerBound < $0 && $0 < piece.upperBound }
            return zip([piece.lowerBound] + inside, inside + [piece.upperBound]).map { $0..<$1 }
        }
        guard !missing.isEmpty else { return nil }
        let frame = oneFrame(of: doc)
        var sequence = doc.sequence
        var ids = Set(sequence.map(\.id))
        var made: Set<String> = []
        for piece in missing {
            // The clips of the take around it, as the pieces before it left the sequence, and the nearest point on each
            // side of it in the sequence: a clip is lengthened, or the piece placed, only with no point in between.
            let clips = sequence.indices.filter {
                sequence[$0].take == take && sequence[$0].start < sequence[$0].end && sequence[$0].content == nil
            }
            let before = clips.filter { sequence[$0].start < piece.lowerBound }.max { sequence[$0].start < sequence[$1].start }
            let after = clips.filter { sequence[$0].start >= piece.upperBound }.min { sequence[$0].start < sequence[$1].start }
            let takePoints = sequence.indices.filter { sequence[$0].take == take && sequence[$0].content != nil }
            let pointBefore = takePoints.last { sequence[$0].start <= piece.lowerBound }
            let pointAfter = takePoints.first { sequence[$0].start >= piece.upperBound }
            let speed = (before ?? after).map { written(sequence[$0]).speed } ?? 1
            if let k = before, sequence[k].end == piece.lowerBound, pointBefore.map({ $0 < k }) ?? true {
                sequence[k] = written(sequence[k])
                sequence[k].end = piece.upperBound
            } else if let k = after, sequence[k].start == piece.upperBound, written(sequence[k]).speed == speed,
                pointAfter.map({ $0 > k }) ?? true
            {
                sequence[k] = written(sequence[k])
                sequence[k].start = piece.lowerBound
            } else {
                var clip = Clip(id: "", take: take, start: piece.lowerBound, end: piece.upperBound, speed: speed)
                guard lasts(clip, frame) else { continue }
                clip.id = newID(makeID, avoiding: &ids)
                made.insert(clip.id)
                // Right after what is before it of the take, a clip or a point, or right before what is after it.
                let previous = [before, pointBefore].compactMap { $0 }.max()
                let next = [after, pointAfter].compactMap { $0 }.min()
                sequence.insert(clip, at: previous.map { $0 + 1 } ?? next ?? sequence.count)
            }
        }
        // The clips lengthened, replaced whole, and then the new ones inserted from the first: each at its index.
        let originals = Dictionary(doc.sequence.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        var changes = SequenceChanges(doc.sequence)
        var touched: [String] = []
        for clip in sequence {
            if made.contains(clip.id) {
                touched.append(clip.id)
            } else if let original = originals[clip.id], original != clip {
                changes.replace(original, with: clip)
                touched.append(clip.id)
            }
        }
        for (index, clip) in sequence.enumerated() where made.contains(clip.id) {
            changes.insert(clip, at: index)
        }
        guard !changes.changes.isEmpty else { return nil }
        return EditStep(label: .transcriptRestore, target: touched.joined(separator: ","), changes: changes.changes)
    }

    // MARK: - Private

    /// `clip` over the source `range` only.
    private static func piece(of clip: Clip, _ range: Range<HostTime>) -> Clip {
        var piece = clip
        piece.start = range.lowerBound
        piece.end = range.upperBound
        return piece
    }

    /// The union of `ranges`: in order, without empty ones, those that overlap or touch joined.
    private static func union(_ ranges: [Range<HostTime>]) -> [Range<HostTime>] {
        var result: [Range<HostTime>] = []
        for range in ranges.filter({ !$0.isEmpty }).sorted(by: { $0.lowerBound < $1.lowerBound }) {
            if let last = result.last, range.lowerBound <= last.upperBound {
                result[result.count - 1] = last.lowerBound..<max(last.upperBound, range.upperBound)
            } else {
                result.append(range)
            }
        }
        return result
    }

    /// What of `ranges` is not in `taken`, both in order and disjoint (as `union` gives them).
    private static func subtracting(_ taken: [Range<HostTime>], from ranges: [Range<HostTime>]) -> [Range<HostTime>] {
        var result: [Range<HostTime>] = []
        for range in ranges {
            var from = range.lowerBound
            for cut in taken where cut.lowerBound < range.upperBound && cut.upperBound > range.lowerBound {
                if from < cut.lowerBound { result.append(from..<cut.lowerBound) }
                from = max(from, cut.upperBound)
            }
            if from < range.upperBound { result.append(from..<range.upperBound) }
        }
        return result
    }
}
