// SPDX-License-Identifier: GPL-3.0-or-later
import Analysis
import ProjectFormat

/// The commands of the Zoom track and its card (design §5.4 and §5.5), as pure functions of the document. Each one gives
/// the step that does it (`EditStep`), or `nil` when there is nothing to do; `regenerate`, which always plans, gives a
/// step without changes then.
///
/// - The blocks are kept in source time and edited in output time: a block's place on the track is
///   `TimeMap.outputRange(ofSource:take:)`, with the cuts inside it closed, and a block hidden whole in a cut takes no
///   room. What a command places goes back to the source as the planner places its blocks (plan decision 16): its start
///   is the source of its output start, its end the source of 1 ns before its output end, and 1 ns, but never past the
///   source shown at its output end in the same clip.
/// - Blocks never overlap on the track: a new one goes only in free space, at least `minimumDuration` long, and a move
///   or a trim stops at the block next to it and at the ends of the output.
/// - Touching an automatic block (trimming or changing it) makes it the user's (`origin: .user`), which the planner never
///   replaces. Moving one makes it a block of the user's with a new id, and deleting one goes: either way its source
///   range goes into `zoom.suppressed`, so planning again never fills the place it left, whatever the settings.
/// - The `target` of a step, which joins a burst of steps into one undo group, is the id of the block it acts on (several
///   in the order of the document, joined by commas), or the pointer of the setting.
public enum ZoomCommands {
    /// The shortest block made or trimmed by hand: 0.3 s of output.
    public static let minimumDuration: Int64 = 300_000_000
    /// A block made with a double click: 3 s of output, centred on the instant.
    public static let defaultDuration: Int64 = 3_000_000_000
    /// The depths of a block (design §5.4): 1.25× to 4×.
    static let depthRange: ClosedRange<Double> = 1.25...4

    /// Makes a block of the user's in the free part of the output range `output` (clamped to the output), with the id
    /// `makeID("z-")`: at the project's depth (`zoom.auto.depth`), following the cursor, moving with the spring. Over
    /// several free parts, the longest (the first of those as long); `nil` if none lasts `minimumDuration`.
    public static func add(_ doc: EditDocument, output: Range<Int64>, makeID: (String) -> String) -> EditStep? {
        let track = ZoomTrack(doc)
        let parts = track.free(output).filter { $0.upperBound - $0.lowerBound >= minimumDuration }
        guard let part = parts.max(by: { $0.upperBound - $0.lowerBound < $1.upperBound - $1.lowerBound }) else { return nil }
        return track.insert(part, makeID: makeID)
    }

    /// Makes a block of `defaultDuration` centred on output instant `at`, as `add` does, but only in the free space
    /// around `at`: `nil` on a block, or with less than `minimumDuration` free there.
    public static func addCentered(_ doc: EditDocument, at: Int64, makeID: (String) -> String) -> EditStep? {
        let track = ZoomTrack(doc)
        let half = defaultDuration / 2
        let around = track.free(at.subtractingSaturating(half)..<at.addingSaturating(defaultDuration - half))
        guard let part = around.first(where: { $0.contains(at) }), part.upperBound - part.lowerBound >= minimumDuration
        else { return nil }
        return track.insert(part, makeID: makeID)
    }

    /// Moves block `id` so its output range starts at `toOutputStart`, as long as it is in the output: it stops at the
    /// blocks before and after it and at the ends of the output. An automatic block becomes one of the user's with the id
    /// `makeID("z-")` (the old one, from its planned place, would be planned again there), which goes where its start puts
    /// it in the list, and its old source range goes into `zoom.suppressed` (as a deletion's does): the planner never
    /// fills that place again, even with other settings or once the moved block is deleted. The step's target is the
    /// block's id after the move. `nil` if it stays where it is, if there is no such block or it shows nothing.
    public static func move(_ doc: EditDocument, id: String, toOutputStart: Int64, makeID: (String) -> String) -> EditStep? {
        let track = ZoomTrack(doc)
        guard let k = doc.zoom.regions.firstIndex(where: { $0.id == id }), let current = track.outputs[k] else { return nil }
        let room = track.room(around: k)
        let length = current.upperBound - current.lowerBound
        let start = min(max(toOutputStart, room.lowerBound), max(room.upperBound - length, room.lowerBound))
        guard start != current.lowerBound, let source = track.source(of: start..<(start + length)) else { return nil }
        let old = doc.zoom.regions[k]
        var region = old
        (region.take, region.start, region.end) = (source.take, source.start, source.end)
        guard old.origin == .auto else { return touched(doc, k, region, label: .zoomMove) }
        var ids = Set(doc.zoom.regions.map(\.id))
        region.id = DocumentIDs.new("z-", makeID, avoiding: &ids)
        region.origin = .user
        var rest = doc.zoom.regions
        rest.remove(at: k)
        var changes = DocumentChanges()
        changes.remove(old, from: .zoomRegions, at: k)
        changes.insert(region, into: .zoomRegions, at: rest.firstIndex { $0.start > region.start } ?? rest.count)
        let range = SourceRange(take: old.take, start: old.start, end: old.end)
        if !doc.zoom.suppressed.contains(range) { changes.insert(range, into: .zoomSuppressed, at: doc.zoom.suppressed.count) }
        return changes.step(label: .zoomMove, target: region.id)
    }

    /// Moves `edge` of block `id` to output instant `toOutput`: it stops at the block next to it and at the ends of the
    /// output, and leaves the block at least `minimumDuration` long (a shorter one only grows). The other edge keeps its
    /// source instant. `nil` if the edge stays where it is, if there is no such block or it shows nothing.
    public static func trim(_ doc: EditDocument, id: String, edge: ClipEdge, toOutput: Int64) -> EditStep? {
        let track = ZoomTrack(doc)
        guard let k = doc.zoom.regions.firstIndex(where: { $0.id == id }), let current = track.outputs[k] else { return nil }
        let room = track.room(around: k)
        var region = doc.zoom.regions[k]
        switch edge {
        case .start:
            let latest = max(current.upperBound - minimumDuration, current.lowerBound)
            let lower = min(max(toOutput, room.lowerBound), latest)
            guard lower != current.lowerBound, let shown = track.map.source(atOutput: lower),
                doc.sequence[shown.clip].take == region.take
            else { return nil }
            region.start = shown.source
        case .end:
            let earliest = min(current.lowerBound + minimumDuration, current.upperBound)
            let upper = max(min(toOutput, room.upperBound), earliest)
            guard upper != current.upperBound, let end = track.sourceEnd(of: upper, take: region.take) else { return nil }
            region.end = end
        }
        guard region.start < region.end else { return nil }
        return touched(doc, k, region, label: .zoomChange)
    }

    /// Changes what the card of the selected block shows: `nil` leaves a field alone, and `depth: .some(nil)` goes back to
    /// the project's depth (`zoom.auto.depth`). A depth is kept in `depthRange` and a fixed focus in the screen
    /// (fractions from 0 to 1). `nil` if nothing changes, if there is no such block or a value is not a number.
    public static func change(
        _ doc: EditDocument, id: String, depth: Double?? = nil, focus: ZoomFocus? = nil, instant: Bool? = nil
    ) -> EditStep? {
        guard let k = doc.zoom.regions.firstIndex(where: { $0.id == id }) else { return nil }
        var region = doc.zoom.regions[k]
        if let depth {
            if let value = depth {
                guard !value.isNaN else { return nil }
                region.depth = min(max(value, depthRange.lowerBound), depthRange.upperBound)
            } else {
                region.depth = nil
            }
        }
        if let focus {
            switch focus {
            case .follow:
                region.focus = .follow
            case let .fixed(x, y):
                guard !x.isNaN, !y.isNaN else { return nil }
                region.focus = .fixed(x: min(max(x, 0), 1), y: min(max(y, 0), 1))
            }
        }
        if let instant { region.instant = instant }
        guard region != doc.zoom.regions[k] else { return nil }
        return touched(doc, k, region, label: .zoomChange)
    }

    /// Deletes the blocks with the ids `ids`; for each automatic one, its source range goes into `zoom.suppressed` (once),
    /// so the planner does not put it back. Ids of no block are left out; `nil` with none.
    public static func delete(_ doc: EditDocument, ids: Set<String>) -> EditStep? {
        var changes = DocumentChanges()
        var removed: [String] = []
        var suppressed = doc.zoom.suppressed
        var deletions: [SourceRange] = []
        for (k, region) in doc.zoom.regions.enumerated() where ids.contains(region.id) {
            changes.remove(region, from: .zoomRegions, at: k - removed.count)
            removed.append(region.id)
            let range = SourceRange(take: region.take, start: region.start, end: region.end)
            if region.origin == .auto, !suppressed.contains(range) {
                suppressed.append(range)
                deletions.append(range)
            }
        }
        for (offset, range) in deletions.enumerated() {
            changes.insert(range, into: .zoomSuppressed, at: doc.zoom.suppressed.count + offset)
        }
        return changes.step(label: .zoomDelete, target: removed.joined(separator: ","))
    }

    /// Plans the automatic blocks of `take` again with `settings` (`AutoZoomPlanner`, which leaves the user's blocks and
    /// the suppressed ranges alone), in one step: `/zoom/auto` set to `settings`, and the blocks as `replanned` gives them.
    /// With `enabled` off, it only removes. Without anything to change, the step has no changes.
    public static func regenerate(_ doc: EditDocument, take: TakeRecord, events: [InputEvent], settings: AutoZoomSettings) -> EditStep {
        var planned = doc
        planned.zoom.auto = settings
        var changes = DocumentChanges()
        changes.set(["zoom", "auto"], from: doc.zoom.auto, to: settings)
        changes.edit(.zoomRegions, from: doc.zoom.regions, to: replanned(planned, take: take, events: events), id: \.id)
        return changes.stepEvenIfEmpty(label: .zoomRegenerate, target: "/zoom/auto")
    }

    /// The blocks of `doc` with the automatic ones of `take` that were not touched planned again (`AutoZoomPlanner`, with
    /// the document as it is: its settings, its stage, its user's blocks and suppressed ranges; nothing with `enabled`
    /// off): the others kept in their order, each planned one before the first kept that starts after it. A planned block
    /// the document has already, the same, stays where it is; one whose id a kept block has is left out, so no two blocks
    /// share an id. What `regenerate` and `StyleCommands.applyDefaultStyle` write.
    static func replanned(_ doc: EditDocument, take: TakeRecord, events: [InputEvent]) -> [ZoomRegion] {
        func untouched(_ region: ZoomRegion) -> Bool { region.origin == .auto && region.take == take.id }
        var planned = doc
        planned.zoom.regions = doc.zoom.regions.filter { !untouched($0) }
        let made = doc.zoom.auto.enabled ? AutoZoomPlanner.plan(take: take, events: events, document: planned) : []

        let taken = Set(planned.zoom.regions.map(\.id))
        let old = Dictionary(doc.zoom.regions.filter(untouched).map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let new = made.filter { !taken.contains($0.id) }
        let same = Set(new.filter { old[$0.id] == $0 }.map(\.id))
        let kept = doc.zoom.regions.filter { !untouched($0) || same.contains($0.id) }
        var regions: [ZoomRegion] = []
        var next = 0
        for region in new.sorted(by: { $0.start < $1.start }) where !same.contains(region.id) {
            while next < kept.count, kept[next].start <= region.start {
                regions.append(kept[next])
                next += 1
            }
            regions.append(region)
        }
        regions += kept[next...]
        return regions
    }

    /// "Show Zooms" (design §5.4): off, no block zooms, and none is deleted.
    public static func setShow(_ doc: EditDocument, _ show: Bool) -> EditStep? {
        var changes = DocumentChanges()
        changes.set(["zoom", "show"], from: doc.zoom.show, to: show)
        return changes.step(label: .zoomChange, target: "/zoom/show")
    }

    /// The zoom's motion blur, the shutter as a fraction of a frame from 0 to 1; `nil` for one that is not a number.
    public static func setMotionBlur(_ doc: EditDocument, _ value: Double) -> EditStep? {
        guard !value.isNaN else { return nil }
        var changes = DocumentChanges()
        changes.set(["zoom", "motionBlur"], from: doc.zoom.motionBlur, to: min(max(value, 0), 1))
        return changes.step(label: .zoomChange, target: "/zoom/motionBlur")
    }

    /// The step that makes block `k` of `doc` `region`, the user's.
    private static func touched(_ doc: EditDocument, _ k: Int, _ region: ZoomRegion, label: EditLabel) -> EditStep? {
        var region = region
        region.origin = .user
        let old = doc.zoom.regions[k]
        var changes = DocumentChanges()
        changes.replace(old, with: region, in: .zoomRegions, id: old.id)
        return changes.step(label: label, target: old.id)
    }
}

/// The blocks of a document on the Zoom track: where the output shows each one.
private struct ZoomTrack {
    let doc: EditDocument
    let map: TimeMap
    /// The output range of each of `zoom.regions`, in order; `nil` for one that shows nothing.
    let outputs: [Range<Int64>?]

    init(_ doc: EditDocument) {
        self.doc = doc
        let map = TimeMap(sequence: doc.sequence)
        self.map = map
        outputs = doc.zoom.regions.map { region in
            guard region.start < region.end, let range = map.outputRange(ofSource: region.start..<region.end, take: region.take),
                !range.isEmpty
            else { return nil }
            return range
        }
    }

    /// What is left of `range`, clamped to the output, free of every block, in order.
    func free(_ range: Range<Int64>) -> [Range<Int64>] {
        let lower = max(range.lowerBound, 0), upper = min(range.upperBound, map.duration)
        guard lower < upper else { return [] }
        var parts = [lower..<upper]
        for case let taken? in outputs {
            parts = parts.flatMap { part -> [Range<Int64>] in
                guard part.overlaps(taken) else { return [part] }
                return [part.lowerBound..<max(part.lowerBound, taken.lowerBound), min(part.upperBound, taken.upperBound)..<part.upperBound]
                    .filter { !$0.isEmpty }
            }
        }
        return parts
    }

    /// Where block `k` can go: from the end of the block before it (or 0) to the start of the one after it (or the end
    /// of the output). A block over it (in a document edited by hand) is no limit.
    func room(around k: Int) -> Range<Int64> {
        guard let current = outputs[k] else { return 0..<map.duration }
        var (lower, upper) = (Int64(0), map.duration)
        for (j, other) in outputs.enumerated() where j != k {
            guard let other else { continue }
            if other.upperBound <= current.lowerBound { lower = max(lower, other.upperBound) }
            if other.lowerBound >= current.upperBound { upper = min(upper, other.lowerBound) }
        }
        return lower..<max(lower, upper)
    }

    /// The source range of `output` (plan decision 16), of the take shown at both its ends; `nil` if they are not of one
    /// take.
    func source(of output: Range<Int64>) -> (take: String, start: HostTime, end: HostTime)? {
        guard !output.isEmpty, let first = map.source(atOutput: output.lowerBound) else { return nil }
        let take = doc.sequence[first.clip].take
        guard let end = sourceEnd(of: output.upperBound, take: take), first.source < end else { return nil }
        return (take, first.source, end)
    }

    /// The source end of a block of `take` whose output ends at `upper`: the source of `upper − 1` and 1 ns, but never past
    /// the source shown at `upper` in the same clip; `nil` if `upper − 1` is not in a clip of `take`.
    func sourceEnd(of upper: Int64, take: String) -> HostTime? {
        guard upper > 0, let last = map.source(atOutput: upper - 1), doc.sequence[last.clip].take == take else { return nil }
        var end = HostTime(nanoseconds: last.source.nanoseconds + 1)
        if upper < map.duration, let next = map.source(atOutput: upper), next.clip == last.clip { end = min(end, next.source) }
        return end
    }

    /// The step that makes a block of the user's over `output`.
    func insert(_ output: Range<Int64>, makeID: (String) -> String) -> EditStep? {
        guard let source = source(of: output) else { return nil }
        var ids = Set(doc.zoom.regions.map(\.id))
        let region = ZoomRegion(
            id: DocumentIDs.new("z-", makeID, avoiding: &ids), take: source.take, start: source.start, end: source.end,
            origin: .user, depth: min(max(doc.zoom.auto.depth, ZoomCommands.depthRange.lowerBound), ZoomCommands.depthRange.upperBound),
            focus: .follow, instant: false)
        let index = doc.zoom.regions.firstIndex { $0.start > region.start } ?? doc.zoom.regions.count
        var changes = DocumentChanges()
        changes.insert(region, into: .zoomRegions, at: index)
        return changes.step(label: .zoomAdd, target: region.id)
    }
}

extension Int64 {
    /// `self + other`, at `Int64.max` or `Int64.min` where it would overflow.
    fileprivate func addingSaturating(_ other: Int64) -> Int64 {
        let (sum, overflow) = addingReportingOverflow(other)
        return overflow ? (other > 0 ? .max : .min) : sum
    }

    /// `self − other`, at `Int64.max` or `Int64.min` where it would overflow.
    fileprivate func subtractingSaturating(_ other: Int64) -> Int64 {
        let (difference, overflow) = subtractingReportingOverflow(other)
        return overflow ? (other > 0 ? .min : .max) : difference
    }
}
