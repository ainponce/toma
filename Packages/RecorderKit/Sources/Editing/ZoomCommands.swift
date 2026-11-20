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
    public static let depthRange: ClosedRange<Double> = 1.25...4

    /// Makes a block of the user's in the free part of the output range `output` (clamped to the output), with the id
    /// `makeID("z-")`: at the project's depth (`zoom.auto.depth`), following the cursor, moving with the spring. Over
    /// several free parts, the longest (the first of those as long); `nil` if none lasts `minimumDuration`.
    public static func add(_ doc: EditDocument, output: Range<Int64>, makeID: (String) -> String) -> EditStep? {
        let track = track(doc)
        guard let part = track.longestFree(in: output, atLeast: minimumDuration) else { return nil }
        return insert(doc, track, part, makeID: makeID)
    }

    /// Makes a block of `defaultDuration` centred on output instant `at`, as `add` does, but only in the free space
    /// around `at`: `nil` on a block, or with less than `minimumDuration` free there.
    public static func addCentered(_ doc: EditDocument, at: Int64, makeID: (String) -> String) -> EditStep? {
        let track = track(doc)
        let half = defaultDuration / 2
        let around = track.free(at.subtractingSaturating(half)..<at.addingSaturating(defaultDuration - half))
        guard let part = around.first(where: { $0.contains(at) }), part.upperBound - part.lowerBound >= minimumDuration
        else { return nil }
        return insert(doc, track, part, makeID: makeID)
    }

    /// Moves block `id` so its output range starts at `toOutputStart`, as long as it is in the output: it stops at the
    /// blocks before and after it and at the ends of the output. An automatic block becomes one of the user's with the id
    /// `makeID("z-")` (the old one, from its planned place, would be planned again there), which goes where its start puts
    /// it in the list, and its old source range goes into `zoom.suppressed` (as a deletion's does): the planner never
    /// fills that place again, even with other settings or once the moved block is deleted. The step's target is the
    /// block's id after the move. `nil` if it stays where it is, if there is no such block or it shows nothing.
    public static func move(_ doc: EditDocument, id: String, toOutputStart: Int64, makeID: (String) -> String) -> EditStep? {
        guard let k = doc.zoom.regions.firstIndex(where: { $0.id == id }),
            let source = track(doc).moved(k, toOutputStart: toOutputStart)
        else { return nil }
        let old = doc.zoom.regions[k]
        var region = old
        (region.take, region.start, region.end) = (source.take, source.start, source.end)
        guard old.origin == .auto else { return touched(doc, k, region, label: .zoomMove) }
        region.mode = Self.writtenMode(of: old, auto: doc.zoom.auto)
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
        guard let k = doc.zoom.regions.firstIndex(where: { $0.id == id }) else { return nil }
        var region = doc.zoom.regions[k]
        let range = SourceRange(take: region.take, start: region.start, end: region.end)
        guard let trimmed = track(doc).trimmed(k, range, edge: edge, toOutput: toOutput, minimum: minimumDuration) else { return nil }
        (region.start, region.end) = (trimmed.start, trimmed.end)
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

    /// Changes the mode of block `id` to `mode` (`classic` is `nil` in a block of the user's). An automatic block becomes
    /// the user's with the mode written. `nil` if it already shows that mode or there is no such block.
    public static func setMode(_ doc: EditDocument, id: String, mode: ZoomMode) -> EditStep? {
        guard let k = doc.zoom.regions.firstIndex(where: { $0.id == id }) else { return nil }
        var region = doc.zoom.regions[k]
        guard region.resolvedMode(auto: doc.zoom.auto) != mode else { return nil }
        region.mode = mode == .classic ? nil : mode
        return touched(doc, k, region, label: .zoomMode, keepingMode: true)
    }

    /// Changes the lens of block `id`: `nil` leaves a field alone, the radius is held in `LoupeStyle.radiusRange`, and a
    /// lens equal to the default is `nil`. `nil` if nothing changes, there is no such block or the radius is not a number.
    public static func setLoupe(_ doc: EditDocument, id: String, radius: Double? = nil, shape: LoupeShape? = nil) -> EditStep? {
        guard let k = doc.zoom.regions.firstIndex(where: { $0.id == id }) else { return nil }
        if let radius, radius.isNaN { return nil }
        var region = doc.zoom.regions[k]
        var style = region.resolvedLoupe
        if let radius {
            style.radius = min(max(radius, LoupeStyle.radiusRange.lowerBound), LoupeStyle.radiusRange.upperBound)
        }
        if let shape { style.shape = shape }
        region.loupe = style == .default ? nil : style
        guard region != doc.zoom.regions[k] else { return nil }
        return touched(doc, k, region, label: .zoomChange)
    }

    /// The mode of the automatic blocks without one of their own (`/zoom/auto/mode`), in one step that plans nothing.
    /// `nil` if it is the same.
    public static func setAutoMode(_ doc: EditDocument, _ mode: ZoomMode) -> EditStep? {
        var changes = DocumentChanges()
        changes.set(["zoom", "auto", "mode"], from: doc.zoom.auto.mode, to: mode)
        return changes.step(label: .zoomMode, target: "/zoom/auto/mode")
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
    private static func touched(
        _ doc: EditDocument, _ k: Int, _ region: ZoomRegion, label: EditLabel, keepingMode: Bool = false
    ) -> EditStep? {
        var region = region
        let old = doc.zoom.regions[k]
        // An automatic block keeps the mode it showed when it becomes the user's, so it never changes with the owner.
        if old.origin == .auto, !keepingMode { region.mode = writtenMode(of: old, auto: doc.zoom.auto) }
        region.origin = .user
        var changes = DocumentChanges()
        changes.replace(old, with: region, in: .zoomRegions, id: old.id)
        return changes.step(label: label, target: old.id)
    }

    /// The `mode` a block of the user's holds to show what `block` shows: `nil` for `classic`.
    private static func writtenMode(of block: ZoomRegion, auto: AutoZoomSettings) -> ZoomMode? {
        let mode = block.resolvedMode(auto: auto)
        return mode == .classic ? nil : mode
    }

    /// The blocks of `doc` on the Zoom track: each where the output shows it, with the cuts inside it closed.
    private static func track(_ doc: EditDocument) -> OutputBlockTrack {
        let map = TimeMap(sequence: doc.sequence)
        let ranges = doc.zoom.regions.map { SourceRange(take: $0.take, start: $0.start, end: $0.end) }
        return OutputBlockTrack(sequence: doc.sequence, map: map, outputs: OutputBlockTrack.outputs(of: ranges, in: map))
    }

    /// The step that makes a block of the user's over `output`.
    private static func insert(
        _ doc: EditDocument, _ track: OutputBlockTrack, _ output: Range<Int64>, makeID: (String) -> String
    ) -> EditStep? {
        guard let source = track.source(of: output) else { return nil }
        var ids = Set(doc.zoom.regions.map(\.id))
        let region = ZoomRegion(
            id: DocumentIDs.new("z-", makeID, avoiding: &ids), take: source.take, start: source.start, end: source.end,
            origin: .user, depth: min(max(doc.zoom.auto.depth, depthRange.lowerBound), depthRange.upperBound), focus: .follow,
            instant: false, mode: doc.zoom.auto.mode == .classic ? nil : doc.zoom.auto.mode)
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
