// SPDX-License-Identifier: GPL-3.0-or-later
import ProjectFormat

/// Which edge of a clip.
public enum ClipEdge: Sendable {
    case start, end
}

/// Why a command on the sequence did nothing.
public enum SequenceError: Error, Equatable {
    /// It would leave no clip of at least one frame ("There has to be at least one clip.", design §5.5).
    case lastClip
}

/// The commands of the Video track (design §5.5): split, delete, trim and speed, as pure functions of the document. Each
/// one gives the step that does it (`EditStep`), or nothing when there is nothing to do.
///
/// - The sequence is magnetic: the output times come from the clips (`TimeMap`), so deleting a clip closes its gap,
///   and a trim or a speed moves every clip after it.
/// - No clip is left shorter than one output frame at the document's `frameRate` (plan decision 24): a command that
///   would leave one does nothing, except a range deletion, which takes a sliver of an edge clip with the range.
/// - A clip's edge goes as far as the clip next to it in the source, or the start or the end of the take's timeline
///   (`TakeTimeline.bounds`); a pause is no limit, its frozen frame shows (plan decision 6).
/// - Every clip a command writes has its speed in its range, as `ClipSpeed.clamped(_:)` reads it.
/// - The changes are built from the clips they touch, never from the whole document encoded again for each one.
/// - The `target` of a step, which joins a burst of steps into one undo group, is the id of the clip it acts on; for
///   several, their ids in the order of the sequence, joined by commas.
public enum SequenceCommands {
    public static let speedPresets: [Double] = [0.5, 1, 1.5, 2, 4, 8]
    /// `ClipSpeed.range`, 0.25 to 16.
    public static let speedRange: ClosedRange<Double> = ClipSpeed.range

    /// Splits the clip shown at output instant `atOutput` there: the clip ends at the source instant shown there
    /// (`TimeMap.source(atOutput:)`) and a new clip, with the id `makeID("c-")`, goes on from it to the old end, at the same
    /// speed. `nil` on an edge, out of the output, or if either piece would be shorter than a frame.
    public static func split(_ doc: EditDocument, atOutput: Int64, makeID: (String) -> String) -> EditStep? {
        split(doc, at: [atOutput], makeID: makeID)
    }

    /// Splits at both edges of `range` in one step, at each edge as `split(_:atOutput:makeID:)` does: the first that
    /// can be split first, so an edge that would leave a piece shorter than a frame is left out. `nil` if neither can.
    public static func split(_ doc: EditDocument, range: Range<Int64>, makeID: (String) -> String) -> EditStep? {
        split(doc, at: [range.lowerBound, range.upperBound], makeID: makeID)
    }

    /// Deletes the clips with the ids `clipIDs`, and the sequence closes the gap. `.failure(.lastClip)` if no clip of at
    /// least a frame would be left; ids that are not in the sequence are left out, and with none the step has no changes.
    public static func delete(_ doc: EditDocument, clipIDs: Set<String>) -> Result<EditStep, SequenceError> {
        let frame = oneFrame(of: doc)
        var changes = SequenceChanges()
        var removed: [String] = []
        var leavesAFrame = false
        for (k, clip) in doc.sequence.enumerated() {
            if clipIDs.contains(clip.id) {
                changes.remove(clip, at: k - removed.count)
                removed.append(clip.id)
            } else if lasts(clip, frame) {
                leavesAFrame = true
            }
        }
        guard removed.isEmpty || leavesAFrame else { return .failure(.lastClip) }
        return .success(EditStep(label: .delete, target: removed.joined(separator: ","), changes: changes.changes))
    }

    /// Deletes the output range `output` (clamped to the output) in one step: the clips inside it are removed, a clip
    /// across an edge is trimmed to that edge, and a clip with the whole range inside it is cut in two, its second piece a
    /// new clip with the id `makeID("c-")`. What is left of a clip at an edge that is shorter than a frame goes with the
    /// range. `.failure(.lastClip)` if no clip of at least a frame would be left; a range with nothing of the output in
    /// it gives a step without changes.
    public static func deleteRange(
        _ doc: EditDocument, output: Range<Int64>, makeID: (String) -> String
    ) -> Result<EditStep, SequenceError> {
        let map = TimeMap(sequence: doc.sequence)
        let frame = oneFrame(of: doc)
        let (a, b) = (max(output.lowerBound, 0), min(output.upperBound, map.duration))
        var ids = Set(doc.sequence.map(\.id))
        var changes = SequenceChanges()
        var touched: [String] = []
        // Removed and inserted so far, for the index of the next change.
        var (removed, inserted) = (0, 0)
        var leavesAFrame = false
        for (k, original) in doc.sequence.enumerated() {
            let start = map.clipOutputStarts[k]
            let end = k + 1 < doc.sequence.count ? map.clipOutputStarts[k + 1] : map.duration
            guard a < b, start < b, end > a else {
                leavesAFrame = leavesAFrame || lasts(original, frame)
                continue
            }
            touched.append(original.id)
            let clip = written(original)
            // What is left of it before the range and after it, each where the output shows it.
            var pieces: [Clip] = []
            if start < a, let shown = map.source(atOutput: a), shown.clip == k {
                var head = clip
                head.end = shown.source
                if lasts(head, frame) { pieces.append(head) }
            }
            if end > b, let shown = map.source(atOutput: b), shown.clip == k {
                var tail = clip
                tail.start = shown.source
                if lasts(tail, frame) { pieces.append(tail) }
            }
            let index = k - removed + inserted
            guard let first = pieces.first else {
                changes.remove(original, at: index)
                removed += 1
                continue
            }
            leavesAFrame = true
            changes.replace(original, with: first)
            if pieces.count == 2 {
                var tail = pieces[1]
                tail.id = newID(makeID, avoiding: &ids)
                changes.insert(tail, at: index + 1)
                inserted += 1
            }
        }
        guard !touched.isEmpty else { return .success(EditStep(label: .delete, target: "", changes: [])) }
        guard leavesAFrame else { return .failure(.lastClip) }
        return .success(EditStep(label: .delete, target: touched.joined(separator: ","), changes: changes.changes))
    }

    /// The source instants `edge` of clip `clipID` can go to (plan decisions 6 and 24): back to the edge of the clip of
    /// the same take before or after it in the source, or to the start or the end of `TakeTimeline.bounds` of `take` (the
    /// clip's take), pauses included; forward while at least a frame of the clip is left. Always holds where the edge
    /// is now. Without a clip `clipID`, the take's bounds.
    public static func trimLimits(
        _ doc: EditDocument, clipID: String, edge: ClipEdge, take: TakeRecord, events: [InputEvent]
    ) -> ClosedRange<HostTime> {
        let bounds = TakeTimeline.bounds(take: take, events: events)
        guard let k = doc.sequence.firstIndex(where: { $0.id == clipID }) else { return bounds.start...bounds.end }
        let clip = doc.sequence[k]
        // The other clips of the take that show anything.
        let others = doc.sequence.indices.lazy.filter { $0 != k }.map { doc.sequence[$0] }
            .filter { $0.take == clip.take && $0.start < $0.end }
        let shortest = shortestSource(lasting: oneFrame(of: doc), speed: clip.speed)
        switch edge {
        case .start:
            let before = others.filter { $0.start < clip.start }.map(\.end).max()
            let earliest = max(bounds.start, before ?? bounds.start)
            let latest = clip.end.nanoseconds >= shortest ? clip.end.nanoseconds - shortest : 0
            return min(earliest, clip.start)...max(HostTime(nanoseconds: latest), clip.start)
        case .end:
            let after = others.filter { $0.start > clip.start }.map(\.start).min()
            let latest = min(bounds.end, after ?? bounds.end)
            let (sum, overflow) = clip.start.nanoseconds.addingReportingOverflow(shortest)
            return min(HostTime(nanoseconds: overflow ? .max : sum), clip.end)...max(latest, clip.end)
        }
    }

    /// Moves `edge` of clip `clipID` to `toSource`, clamped to `limits` (`trimLimits`, worked out once for a drag). `nil`
    /// if the edge stays where it is, there is no such clip, or the clip would be shorter than a frame.
    public static func trim(
        _ doc: EditDocument, clipID: String, edge: ClipEdge, toSource: HostTime, limits: ClosedRange<HostTime>
    ) -> EditStep? {
        guard let original = doc.sequence.first(where: { $0.id == clipID }) else { return nil }
        let to = min(max(toSource, limits.lowerBound), limits.upperBound)
        var clip = written(original)
        switch edge {
        case .start:
            guard to != original.start else { return nil }
            clip.start = to
        case .end:
            guard to != original.end else { return nil }
            clip.end = to
        }
        guard lasts(clip, oneFrame(of: doc)) else { return nil }
        var changes = SequenceChanges()
        changes.replace(original, with: clip)
        return EditStep(label: .trim, target: clipID, changes: changes.changes)
    }

    /// Trims the clip under the playhead at output instant `atOutput`: its start up to the source instant shown there
    /// (that frame is its first), or its end (that frame is the next clip's). `nil` on an edge, out of the output, or if
    /// less than a frame of the clip would be left: it does not stop short of the playhead.
    public static func trimToPlayhead(
        _ doc: EditDocument, edge: ClipEdge, atOutput: Int64, take: TakeRecord, events: [InputEvent]
    ) -> EditStep? {
        let map = TimeMap(sequence: doc.sequence)
        guard atOutput > 0, atOutput < map.duration, let shown = map.source(atOutput: atOutput) else { return nil }
        let clipID = doc.sequence[shown.clip].id
        let limits = trimLimits(doc, clipID: clipID, edge: edge, take: take, events: events)
        guard limits.contains(shown.source) else { return nil }
        return trim(doc, clipID: clipID, edge: edge, toSource: shown.source, limits: limits)
    }

    /// Plays the clips with the ids `clipIDs` at `speed`, clamped to `speedRange` (`ClipSpeed.clamped(_:)`: one that is
    /// not a number is 1). All or nothing: `nil` if any of them would be shorter than a frame, or if none changes.
    public static func setSpeed(_ doc: EditDocument, clipIDs: Set<String>, speed: Double) -> EditStep? {
        let speed = ClipSpeed.clamped(speed)
        let frame = oneFrame(of: doc)
        var changes = SequenceChanges()
        var changed: [String] = []
        for clip in doc.sequence where clipIDs.contains(clip.id) && clip.speed != speed {
            var faster = clip
            faster.speed = speed
            guard lasts(faster, frame) else { return nil }
            changes.replace(clip, with: faster)
            changed.append(clip.id)
        }
        guard !changed.isEmpty else { return nil }
        return EditStep(label: .speed, target: changed.joined(separator: ","), changes: changes.changes)
    }

    // MARK: - Private

    /// Splits the clips at the output instants `outputs`, each in the clip shown there, in order.
    private static func split(_ doc: EditDocument, at outputs: [Int64], makeID: (String) -> String) -> EditStep? {
        let map = TimeMap(sequence: doc.sequence)
        let frame = oneFrame(of: doc)
        // The source instants to split each clip at, in order.
        var cuts: [Int: [HostTime]] = [:]
        for τ in Set(outputs).sorted() where τ > 0 && τ < map.duration {
            guard let shown = map.source(atOutput: τ) else { continue }
            cuts[shown.clip, default: []].append(shown.source)
        }
        var ids = Set(doc.sequence.map(\.id))
        var changes = SequenceChanges()
        var inserted = 0
        var target: String?
        for (k, instants) in cuts.sorted(by: { $0.key < $1.key }) {
            let original = doc.sequence[k]
            // Its pieces, each at least a frame long: a cut that would leave less is left out.
            var pieces: [Clip] = []
            var rest = written(original)
            for x in instants {
                var (head, tail) = (rest, rest)
                head.end = x
                tail.start = x
                guard lasts(head, frame), lasts(tail, frame) else { continue }
                pieces.append(head)
                rest = tail
            }
            guard let first = pieces.first else { continue }
            pieces.append(rest)
            changes.replace(original, with: first)
            for var piece in pieces.dropFirst() {
                piece.id = newID(makeID, avoiding: &ids)
                inserted += 1
                changes.insert(piece, at: k + inserted)
            }
            target = target ?? original.id
        }
        guard let target else { return nil }
        return EditStep(label: .split, target: target, changes: changes.changes)
    }

    /// One frame of output at the document's frame rate, the shortest a clip can be (plan decision 24).
    private static func oneFrame(of doc: EditDocument) -> Int64 {
        TimeMap.frameTime(1, frameRate: max(doc.frameRate, 1))
    }

    /// Whether `clip` lasts at least `frame` of output.
    private static func lasts(_ clip: Clip, _ frame: Int64) -> Bool {
        TimeMap.outputDuration(of: clip) >= frame
    }

    /// `clip` with its speed as the time map reads it, the one a command writes.
    private static func written(_ clip: Clip) -> Clip {
        var clip = clip
        clip.speed = ClipSpeed.clamped(clip.speed)
        return clip
    }

    /// The fewest nanoseconds of source that last at least `frame` of output at `speed`, as `TimeMap` rounds them.
    private static func shortestSource(lasting frame: Int64, speed: Double) -> UInt64 {
        func lasts(_ length: UInt64) -> Bool {
            SequenceCommands.lasts(
                Clip(id: "", take: "", start: HostTime(nanoseconds: 0), end: HostTime(nanoseconds: length), speed: speed), frame)
        }
        // `round(L / v) ≥ frame` from `L ≥ (frame − ½) × v` on; the steps only correct the `Double`'s rounding.
        var length = UInt64(max(0, ((Double(frame) - 0.5) * ClipSpeed.clamped(speed)).rounded(.up)))
        while !lasts(length) { length += 1 }
        while length > 0, lasts(length - 1) { length -= 1 }
        return length
    }

    /// A new clip id that no clip of the sequence has, nor one this command made: `makeID("c-")`, which gives 8 random
    /// hex digits and so almost never one in use. If it gives only ids in use, the first free `c-` id counting from 1.
    private static func newID(_ makeID: (String) -> String, avoiding ids: inout Set<String>) -> String {
        for _ in 0..<8 {
            let id = makeID("c-")
            if ids.insert(id).inserted { return id }
        }
        var number = 0
        while true {
            number += 1
            let hex = String(number, radix: 16)
            let id = "c-" + String(repeating: "0", count: max(0, 8 - hex.count)) + hex
            if ids.insert(id).inserted { return id }
        }
    }
}

/// The changes of a command to `/sequence`, in order, each built from the clips it touches.
private struct SequenceChanges {
    private(set) var changes: [EditChange] = []

    /// `EditCollection.sequence`.
    private static let collection = JSONPointer(
        components: EditCollection.sequence.rawValue.split(separator: "/").map(String.init))

    mutating func replace(_ clip: Clip, with new: Clip) {
        changes.append(.replace(collection: Self.collection, id: clip.id, before: Self.encoded(clip), after: Self.encoded(new)))
    }

    /// Removes `clip`, at `index` of the sequence as the changes before this one leave it.
    mutating func remove(_ clip: Clip, at index: Int) {
        changes.append(.remove(collection: Self.collection, index: index, value: Self.encoded(clip)))
    }

    /// Inserts `clip` at `index` of the sequence as the changes before this one leave it.
    mutating func insert(_ clip: Clip, at index: Int) {
        changes.append(.insert(collection: Self.collection, index: index, value: Self.encoded(clip)))
    }

    /// `clip` as it is in the document. One that cannot be encoded (a speed that is not a number) cannot be in an encoded
    /// document either: it becomes `null`, which applying the change refuses (as `EditDocument.insertChange` does).
    private static func encoded(_ clip: Clip) -> JSONValue {
        (try? JSONValue(encoding: clip)) ?? .null
    }
}
