// SPDX-License-Identifier: GPL-3.0-or-later
import Analysis
import ProjectFormat

/// The commands of the camera's layout blocks on the Camera track and of the project's layout (1c design §5.1, §5.5 and
/// §13.1), as pure functions of the document, on the mould of `ZoomCommands`. Each one gives the step that does it
/// (`EditStep`), or `nil` when there is nothing to do.
///
/// - The blocks are kept in source time and edited in output time through `timeMap`, the document's, on the track the
///   zoom's blocks are edited on (`OutputBlockTrack`). A block's place on the track is where the preview shows it
///   (`LayoutTimeline.placedBlocks(of:take:timeMap:)`): its output range with the cuts inside it closed, two blocks at most
///   1 ns apart touching, and one entirely inside another not shown. A block hidden whole in a cut takes no room and stays
///   in the document, so it comes back with its source; as on the Zoom track, a block placed across the closed cut can
///   hold its source, and where both show once the stretch is recovered, the one that starts first rules. What a command
///   places goes back to the source as the zoom's blocks do (plan 1c decision 9).
/// - Blocks never overlap on the track: a new one goes only in free space, at least `minimumDuration` long, and a move or
///   a trim stops at the block next to it and at the ends of the output, and never leaves a block shorter than that. A
///   move keeps the length the block was placed with (`OutputBlockTrack.placedEnd`), which at a speed above 1 is 1 ns more
///   than its output range.
/// - A block keeps the settings of every layout it has been (`bubble`, `split`): changing its `kind` never removes them.
///   Every edit of a block is one `replace` of the whole block, so undoing it brings all of it back. The first time a
///   block is a Bubble (made so, or changed to it), it gets the style that rules the take's bubble at its output start
///   (`TrackCommands.rulingCameraStyle`: the style a change goes to, not what its spring shows on the way), or at its
///   source start for a block that shows nothing (the take's initial style with its changes up to then); the first time
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
        let track = track(doc, timeMap)
        guard let part = track.longestFree(in: output, atLeast: minimumDuration) else { return nil }
        return insert(doc, track, part, kind: kind, makeID: makeID)
    }

    /// Makes a block of layout `kind` that starts at output instant `at` and lasts `defaultDuration`, as `add` does,
    /// clipped to the free space after `at` and to the end of the output: `nil` out of the output, on a block, or with
    /// less than `minimumDuration` free from `at`.
    public static func add(
        _ doc: EditDocument, kind: LayoutKind, at: Int64, timeMap: TimeMap, makeID: (String) -> String
    ) -> EditStep? {
        guard at >= 0, at < timeMap.duration else { return nil }
        let track = track(doc, timeMap)
        let wanted = at..<(at + min(defaultDuration, timeMap.duration - at))
        guard let part = track.free(wanted).first, part.lowerBound == at, part.upperBound - part.lowerBound >= minimumDuration
        else { return nil }
        return insert(doc, track, part, kind: kind, makeID: makeID)
    }

    /// Moves block `id` so its output range starts at `toOutputStart`, as long as it is in the output: it stops at the
    /// blocks before and after it and at the ends of the output, and keeps the length it was placed with. The block keeps
    /// its id, its layout and its settings, and its place in the list. `nil` if it stays where it is, if there is no such
    /// block or it shows nothing.
    public static func move(_ doc: EditDocument, id: String, toOutputStart: Int64, timeMap: TimeMap) -> EditStep? {
        let track = track(doc, timeMap)
        guard let k = index(of: id, in: doc), let current = track.outputs[k] else { return nil }
        var block = doc.camera.layouts[k]
        let length = track.placedEnd(of: current, range(of: block)) - current.lowerBound
        guard let source = track.moved(k, toOutputStart: toOutputStart, length: length) else { return nil }
        (block.take, block.start, block.end) = (source.take, source.start, source.end)
        return replaced(doc, k, with: block, label: .layoutMove)
    }

    /// Moves `edge` of block `id` to output instant `toOutput`: it stops at the block next to it and at the ends of the
    /// output, and leaves the block at least `minimumDuration` long (a shorter one only grows). The other edge keeps its
    /// source instant. `nil` if the edge stays where it is, if there is no such block or it shows nothing.
    public static func trim(_ doc: EditDocument, id: String, edge: ClipEdge, toOutput: Int64, timeMap: TimeMap) -> EditStep? {
        guard let k = index(of: id, in: doc) else { return nil }
        var block = doc.camera.layouts[k]
        let track = track(doc, timeMap)
        guard let trimmed = track.trimmed(k, range(of: block), edge: edge, toOutput: toOutput, minimum: minimumDuration)
        else { return nil }
        (block.start, block.end) = (trimmed.start, trimmed.end)
        return replaced(doc, k, with: block, label: .layoutTrim)
    }

    /// Changes the layout of block `id` to `kind`, keeping its settings of every layout; the first time it is a Bubble or
    /// a Split it gets that layout's settings (see the type's notes). `nil` if it is that layout already, or there is no
    /// such block.
    public static func setKind(_ doc: EditDocument, id: String, _ kind: LayoutKind, timeMap: TimeMap) -> EditStep? {
        guard let k = index(of: id, in: doc), doc.camera.layouts[k].kind != kind else { return nil }
        var block = doc.camera.layouts[k]
        block.kind = kind
        let settled = withFirstSettings(block, doc, outputStart: track(doc, timeMap).outputs[k]?.lowerBound, timeMap)
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

    /// The block shown at output instant `atOutput`, where the preview shows it (`LayoutTimeline.placedBlocks`); `nil`
    /// where the project's layout rules.
    public static func block(atOutput: Int64, in doc: EditDocument, timeMap: TimeMap) -> LayoutBlock? {
        track(doc, timeMap).outputs.firstIndex { $0?.contains(atOutput) == true }.map { doc.camera.layouts[$0] }
    }

    // MARK: - Private

    private static func index(of id: String, in doc: EditDocument) -> Int? {
        doc.camera.layouts.firstIndex { $0.id == id }
    }

    private static func range(of block: LayoutBlock) -> SourceRange {
        SourceRange(take: block.take, start: block.start, end: block.end)
    }

    /// The blocks of `doc` on the Camera track, each where the preview shows it.
    private static func track(_ doc: EditDocument, _ timeMap: TimeMap) -> OutputBlockTrack {
        OutputBlockTrack(sequence: doc.sequence, map: timeMap, outputs: LayoutTimeline.blockOutputs(of: doc, timeMap: timeMap))
    }

    /// `block` with the settings its layout gets the first time it is that layout: a Bubble's style, the one that rules
    /// the take's bubble at output instant `outputStart`, or at the block's source start without one; and a Split's side.
    private static func withFirstSettings(
        _ block: LayoutBlock, _ doc: EditDocument, outputStart: Int64?, _ timeMap: TimeMap
    ) -> LayoutBlock {
        var block = block
        switch block.kind {
        case .bubble where block.bubble == nil:
            let ruling = outputStart.map { TrackCommands.rulingCameraStyle(doc, atOutput: $0, timeMap: timeMap) }
                ?? TrackCommands.rulingCameraStyle(doc, take: block.take, atSource: block.start)
            block.bubble = BubbleLayout(style: ruling.style)
        case .split where block.split == nil:
            block.split = SplitLayout(side: .end)
        default:
            break
        }
        return block
    }

    /// The step that makes a block of layout `kind` over `output`, after the blocks that start before it.
    private static func insert(
        _ doc: EditDocument, _ track: OutputBlockTrack, _ output: Range<Int64>, kind: LayoutKind, makeID: (String) -> String
    ) -> EditStep? {
        guard let source = track.source(of: output) else { return nil }
        var ids = Set(doc.camera.layouts.map(\.id))
        let made = LayoutBlock(
            id: DocumentIDs.new("l-", makeID, avoiding: &ids), take: source.take, start: source.start, end: source.end, kind: kind,
            instant: false)
        let block = withFirstSettings(made, doc, outputStart: output.lowerBound, track.map)
        let position = doc.camera.layouts.firstIndex { $0.start > block.start } ?? doc.camera.layouts.count
        var changes = DocumentChanges()
        changes.insert(block, into: .cameraLayouts, at: position)
        return changes.step(label: .layoutAdd, target: block.id)
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
