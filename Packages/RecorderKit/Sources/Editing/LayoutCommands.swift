// SPDX-License-Identifier: GPL-3.0-or-later
import ProjectFormat

/// The commands of the camera's layout blocks on the Camera track and of the project's layout (1c design §5.1, §5.5 and
/// §13.1), as pure functions of the document, on the mould of `ZoomCommands`. Each one gives the step that does it
/// (`EditStep`), or `nil` when there is nothing to do.
///
/// - The blocks are kept in source time and edited in output time through `timeMap`, the document's: a block's place on
///   the track is `TimeMap.outputRange(ofSource:take:)`, with the cuts inside it closed, and a block hidden whole in a cut
///   takes no room and stays in the document, so it comes back with its source. What a command places goes back to the
///   source as the zoom's blocks do (plan 1c decision 9): its start is the source of its output start, its end the source
///   of 1 ns before its output end, and 1 ns, but never past the source shown at its output end in the same clip.
/// - Blocks never overlap on the track: a new one goes only in free space, at least `minimumDuration` long, and a move or
///   a trim stops at the block next to it and at the ends of the output, and never leaves a block shorter than that.
/// - A block keeps the settings of every layout it has been (`bubble`, `split`): changing its `kind` never removes them.
///   Every edit of a block is one `replace` of the whole block, so undoing it brings all of it back. The first time a
///   block is a Bubble (made so, or changed to it), it gets the style that rules the take's bubble at its output start
///   (`TrackCommands.rulingCameraStyle`: the style a change goes to, not what its spring shows on the way); the first time
///   a block or the project is a Split, it gets `SplitLayout(side: .end)`.
/// - The project's layout is set whole (`/camera/layout`): its `split` is an optional key, which a `set` cannot add.
/// - The `target` of a step, which joins a burst of steps into one undo group, is the id of the block it acts on (several
///   in the order of the document, joined by commas), or `/camera/layout` for the project's layout.
public enum LayoutCommands {
    /// The shortest block made or trimmed by hand: 0.5 s of output.
    public static let minimumDuration: Int64 = 500_000_000
    /// A block made at the playhead: 3 s of output from it, clipped to the free space.
    public static let defaultDuration: Int64 = 3_000_000_000
    /// The layout of the first block made in a project (1c design §5.5); later ones take the last one picked.
    public static let firstKind: LayoutKind = .cameraFull
    /// The target of the steps on the project's layout.
    private static let projectLayoutTarget = "/camera/layout"

    /// Makes a block of layout `kind`, not instant, in the free part of the output range `output` (clamped to the
    /// output), with the id `makeID("l-")`. Over several free parts, the longest (the first of those as long), as on the
    /// Zoom track; `nil` if none lasts `minimumDuration`.
    public static func add(
        _ doc: EditDocument, kind: LayoutKind, output: Range<Int64>, timeMap: TimeMap, makeID: (String) -> String
    ) -> EditStep? {
        let track = LayoutTrack(doc, timeMap)
        let parts = track.free(output).filter { $0.upperBound - $0.lowerBound >= minimumDuration }
        guard let part = parts.max(by: { $0.upperBound - $0.lowerBound < $1.upperBound - $1.lowerBound }) else { return nil }
        return track.insert(part, kind: kind, makeID: makeID)
    }

    /// Makes a block of layout `kind` that starts at output instant `at` and lasts `defaultDuration`, as `add` does,
    /// clipped to the free space after `at` and to the end of the output: `nil` out of the output, on a block, or with
    /// less than `minimumDuration` free from `at`.
    public static func add(
        _ doc: EditDocument, kind: LayoutKind, at: Int64, timeMap: TimeMap, makeID: (String) -> String
    ) -> EditStep? {
        guard at >= 0, at < timeMap.duration else { return nil }
        let track = LayoutTrack(doc, timeMap)
        let wanted = at..<(at + min(defaultDuration, timeMap.duration - at))
        guard let part = track.free(wanted).first, part.lowerBound == at, part.upperBound - part.lowerBound >= minimumDuration
        else { return nil }
        return track.insert(part, kind: kind, makeID: makeID)
    }

    /// Moves block `id` so its output range starts at `toOutputStart`, as long as it is in the output: it stops at the
    /// blocks before and after it and at the ends of the output. The block keeps its id, its layout and its settings, and
    /// its place in the list. `nil` if it stays where it is, if there is no such block or it shows nothing.
    public static func move(_ doc: EditDocument, id: String, toOutputStart: Int64, timeMap: TimeMap) -> EditStep? {
        let track = LayoutTrack(doc, timeMap)
        guard let k = index(of: id, in: doc), let current = track.outputs[k] else { return nil }
        let room = track.room(around: k)
        let length = current.upperBound - current.lowerBound
        let start = min(max(toOutputStart, room.lowerBound), max(room.upperBound - length, room.lowerBound))
        guard start != current.lowerBound, let source = track.source(of: start..<(start + length)) else { return nil }
        var block = doc.camera.layouts[k]
        (block.take, block.start, block.end) = (source.take, source.start, source.end)
        return replaced(doc, k, with: block, label: .layoutMove)
    }

    /// Moves `edge` of block `id` to output instant `toOutput`: it stops at the block next to it and at the ends of the
    /// output, and leaves the block at least `minimumDuration` long (a shorter one only grows). The other edge keeps its
    /// source instant. `nil` if the edge stays where it is, if there is no such block or it shows nothing.
    public static func trim(_ doc: EditDocument, id: String, edge: ClipEdge, toOutput: Int64, timeMap: TimeMap) -> EditStep? {
        let track = LayoutTrack(doc, timeMap)
        guard let k = index(of: id, in: doc), let current = track.outputs[k] else { return nil }
        let room = track.room(around: k)
        var block = doc.camera.layouts[k]
        switch edge {
        case .start:
            let latest = max(current.upperBound - minimumDuration, current.lowerBound)
            let lower = min(max(toOutput, room.lowerBound), latest)
            guard lower != current.lowerBound, let shown = track.shown(atOutput: lower), shown.take == block.take else { return nil }
            block.start = shown.source
        case .end:
            let earliest = min(current.lowerBound + minimumDuration, current.upperBound)
            let upper = max(min(toOutput, room.upperBound), earliest)
            guard upper != current.upperBound, let end = track.sourceEnd(of: upper, take: block.take) else { return nil }
            block.end = end
        }
        guard block.start < block.end else { return nil }
        return replaced(doc, k, with: block, label: .layoutTrim)
    }

    /// Changes the layout of block `id` to `kind`, keeping its settings of every layout; the first time it is a Bubble or
    /// a Split it gets that layout's settings (see the type's notes). `nil` if it is that layout already, if there is no
    /// such block, or if it becomes a Bubble for the first time and shows nothing: there is no start to copy the style of.
    public static func setKind(_ doc: EditDocument, id: String, _ kind: LayoutKind, timeMap: TimeMap) -> EditStep? {
        guard let k = index(of: id, in: doc), doc.camera.layouts[k].kind != kind else { return nil }
        let track = LayoutTrack(doc, timeMap)
        var block = doc.camera.layouts[k]
        block.kind = kind
        guard let settled = track.withFirstSettings(block, outputStart: track.outputs[k]?.lowerBound) else { return nil }
        return replaced(doc, k, with: settled, label: .layoutChange)
    }

    /// Whether block `id` jumps at its edges instead of blending with the spring (Transition: Smooth · Instant). `nil` if
    /// it does so already, or there is no such block.
    public static func setInstant(_ doc: EditDocument, id: String, _ instant: Bool) -> EditStep? {
        guard let k = index(of: id, in: doc) else { return nil }
        var block = doc.camera.layouts[k]
        block.instant = instant
        return replaced(doc, k, with: block, label: .layoutChange)
    }

    /// The bubble's style (shape, size and place) of Bubble block `id`, its own; the size is kept in the document's sizes,
    /// as the take's. `nil` if that is its style already, if there is no such block or it is not a Bubble, or the size is
    /// not a number.
    public static func setBubbleStyle(_ doc: EditDocument, id: String, _ style: CameraStyle) -> EditStep? {
        guard !style.size.isNaN, let k = index(of: id, in: doc), doc.camera.layouts[k].kind == .bubble else { return nil }
        var style = style
        style.size = min(max(style.size, TrackCommands.cameraSizes.lowerBound), TrackCommands.cameraSizes.upperBound)
        var block = doc.camera.layouts[k]
        block.bubble = BubbleLayout(style: style)
        return replaced(doc, k, with: block, label: .layoutChange)
    }

    /// The split of block `id`, or of the project's layout with `id: nil`: `nil` leaves a field alone, `share` is kept in
    /// `SplitLayout.shareRange`, and `share: .some(nil)` goes back to the automatic part. Only that of a Split: `nil` if the
    /// block or the project shows another layout, if nothing changes, if there is no such block or the share is not a
    /// number.
    public static func setSplit(_ doc: EditDocument, id: String?, side: CameraSide? = nil, share: Double?? = nil) -> EditStep? {
        func edited(_ split: SplitLayout?) -> SplitLayout? {
            var split = split ?? SplitLayout(side: .end)
            if let side { split.side = side }
            if let share {
                if let value = share {
                    guard !value.isNaN else { return nil }
                    split.share = min(max(value, SplitLayout.shareRange.lowerBound), SplitLayout.shareRange.upperBound)
                } else {
                    split.share = nil
                }
            }
            return split
        }
        guard let id else {
            var layout = doc.camera.layout
            guard layout.kind == .split, let split = edited(layout.split) else { return nil }
            layout.split = split
            return projectLayout(doc, layout, label: .cameraSplit)
        }
        guard let k = index(of: id, in: doc), doc.camera.layouts[k].kind == .split else { return nil }
        var block = doc.camera.layouts[k]
        guard let split = edited(block.split) else { return nil }
        block.split = split
        return replaced(doc, k, with: block, label: .cameraSplit)
    }

    /// The project's layout, which rules outside the blocks: one `set` of `/camera/layout`, which keeps its split, and
    /// writes `SplitLayout(side: .end)` the first time it is a Split. `nil` if it is that layout already.
    public static func setProjectLayout(_ doc: EditDocument, _ kind: LayoutKind) -> EditStep? {
        var layout = doc.camera.layout
        guard layout.kind != kind else { return nil }
        layout.kind = kind
        if kind == .split, layout.split == nil { layout.split = SplitLayout(side: .end) }
        return projectLayout(doc, layout, label: .cameraLayout)
    }

    /// Deletes the blocks with the ids `ids`. Ids of no block are left out; `nil` with none.
    public static func delete(_ doc: EditDocument, ids: Set<String>) -> EditStep? {
        var changes = DocumentChanges()
        var removed: [String] = []
        for (k, block) in doc.camera.layouts.enumerated() where ids.contains(block.id) {
            changes.remove(block, from: .cameraLayouts, at: k - removed.count)
            removed.append(block.id)
        }
        return changes.step(label: .layoutDelete, target: removed.joined(separator: ","))
    }

    /// The block shown at output instant `atOutput`, `nil` where the project's layout rules: of the blocks whose output
    /// range holds it, the one that starts first (the first in the document of those that start together), as
    /// `LayoutTimeline` shows a block over another in a document edited by hand.
    public static func block(atOutput: Int64, in doc: EditDocument, timeMap: TimeMap) -> LayoutBlock? {
        let track = LayoutTrack(doc, timeMap)
        let holding = track.outputs.enumerated().compactMap { k, output in
            output.flatMap { $0.contains(atOutput) ? (k, $0.lowerBound) : nil }
        }
        return holding.min { ($0.1, $0.0) < ($1.1, $1.0) }.map { doc.camera.layouts[$0.0] }
    }

    // MARK: - Private

    private static func index(of id: String, in doc: EditDocument) -> Int? {
        doc.camera.layouts.firstIndex { $0.id == id }
    }

    /// The step that makes block `k` of `doc` `block`, the whole block in one `replace`.
    private static func replaced(_ doc: EditDocument, _ k: Int, with block: LayoutBlock, label: EditLabel) -> EditStep? {
        let old = doc.camera.layouts[k]
        var changes = DocumentChanges()
        changes.replace(old, with: block, in: .cameraLayouts, id: old.id)
        return changes.step(label: label, target: old.id)
    }

    /// The step that makes the project's layout `layout`.
    private static func projectLayout(_ doc: EditDocument, _ layout: CameraLayout, label: EditLabel) -> EditStep? {
        var changes = DocumentChanges()
        changes.set(["camera", "layout"], from: doc.camera.layout, to: layout)
        return changes.step(label: label, target: projectLayoutTarget)
    }
}

/// The blocks of a document on the Camera track: where the output shows each one.
private struct LayoutTrack {
    let doc: EditDocument
    let map: TimeMap
    /// The output range of each of `camera.layouts`, in order; `nil` for one that shows nothing.
    let outputs: [Range<Int64>?]

    init(_ doc: EditDocument, _ map: TimeMap) {
        self.doc = doc
        self.map = map
        outputs = doc.camera.layouts.map { block in
            guard block.start < block.end, let range = map.outputRange(ofSource: block.start..<block.end, take: block.take),
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

    /// The take and the source instant shown at output instant `τ`; `nil` for an output of 0 ns.
    func shown(atOutput τ: Int64) -> (take: String, source: HostTime)? {
        guard let shown = map.source(atOutput: τ), doc.sequence.indices.contains(shown.clip) else { return nil }
        return (doc.sequence[shown.clip].take, shown.source)
    }

    /// The source range of `output` (plan 1c decision 9), of the take shown at both its ends; `nil` if they are not of
    /// one take.
    func source(of output: Range<Int64>) -> (take: String, start: HostTime, end: HostTime)? {
        guard !output.isEmpty, let first = shown(atOutput: output.lowerBound),
            let end = sourceEnd(of: output.upperBound, take: first.take), first.source < end
        else { return nil }
        return (first.take, first.source, end)
    }

    /// The source end of a block of `take` whose output ends at `upper`: the source of `upper − 1` and 1 ns, but never past
    /// the source shown at `upper` in the same clip; `nil` if `upper − 1` is not in a clip of `take`.
    func sourceEnd(of upper: Int64, take: String) -> HostTime? {
        guard upper > 0, let last = map.source(atOutput: upper - 1), doc.sequence.indices.contains(last.clip),
            doc.sequence[last.clip].take == take
        else { return nil }
        var end = HostTime(nanoseconds: last.source.nanoseconds + 1)
        if upper < map.duration, let next = map.source(atOutput: upper), next.clip == last.clip { end = min(end, next.source) }
        return end
    }

    /// `block` with the settings its layout gets the first time it is that layout: a Bubble's style, the one that rules
    /// the take's bubble at output instant `outputStart` (`nil` without one), and a Split's side.
    func withFirstSettings(_ block: LayoutBlock, outputStart: Int64?) -> LayoutBlock? {
        var block = block
        switch block.kind {
        case .bubble where block.bubble == nil:
            guard let outputStart else { return nil }
            block.bubble = BubbleLayout(style: TrackCommands.rulingCameraStyle(doc, atOutput: outputStart, timeMap: map).style)
        case .split where block.split == nil:
            block.split = SplitLayout(side: .end)
        default:
            break
        }
        return block
    }

    /// The step that makes a block of layout `kind` over `output`, after the blocks that start before it.
    func insert(_ output: Range<Int64>, kind: LayoutKind, makeID: (String) -> String) -> EditStep? {
        guard let source = source(of: output) else { return nil }
        var ids = Set(doc.camera.layouts.map(\.id))
        let made = LayoutBlock(
            id: DocumentIDs.new("l-", makeID, avoiding: &ids), take: source.take, start: source.start, end: source.end, kind: kind,
            instant: false)
        guard let block = withFirstSettings(made, outputStart: output.lowerBound) else { return nil }
        let index = doc.camera.layouts.firstIndex { $0.start > block.start } ?? doc.camera.layouts.count
        var changes = DocumentChanges()
        changes.insert(block, into: .cameraLayouts, at: index)
        return changes.step(label: .layoutAdd, target: block.id)
    }
}
