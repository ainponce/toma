// SPDX-License-Identifier: GPL-3.0-or-later
import Analysis
import ProjectFormat

/// The commands of the Privacy track (design §7.1), as pure functions of the document, in the manner of `ZoomCommands`:
/// each gives the step that does it, or `nil` when there is nothing to do.
///
/// - The blocks are kept in source time and edited in output time (`OutputBlockTrack`, plan decision 16 of 1b). Unlike
///   zoom blocks they may overlap, so each command looks at its block alone: a move or a trim never stops at another.
/// - Every change of one block is a single `.replace` of the whole block. A block hidden whole in a cut stays in the
///   document and shows nothing (`outputRange` is `nil`).
/// - The `target` of a step is the id of the block (several, in the order of the document, joined by commas).
public enum PrivacyCommands {
    /// The shortest block made or trimmed by hand: 0.3 s of output.
    public static let minimumDuration: Int64 = 300_000_000
    /// A block made from the playhead: 3 s of output.
    public static let defaultDuration: Int64 = 3_000_000_000
    /// Where a new block goes: 40 % × 20 % of the screen's content, centred.
    public static let defaultRect = NormalizedRect(x: 0.3, y: 0.4, width: 0.4, height: 0.2)

    /// Makes a block of `defaultDuration` from output instant `atOutput`, cut where the take of that instant's clip stops
    /// (the end of the run of clips of that take) or the output ends, with the id `makeID("p-")`: blur, strength 0.6,
    /// black, `defaultRect`, by hand, in its place by start. `nil` with less than `minimumDuration` left there.
    public static func add(_ doc: EditDocument, atOutput: Int64, makeID: (String) -> String) -> EditStep? {
        let map = TimeMap(sequence: doc.sequence)
        let start = max(atOutput, 0)
        guard start < map.duration, let shown = map.source(atOutput: start), doc.sequence.indices.contains(shown.clip) else { return nil }
        let take = doc.sequence[shown.clip].take
        var last = shown.clip
        while last + 1 < doc.sequence.count, doc.sequence[last + 1].take == take { last += 1 }
        let takeEnd = last + 1 < map.clipOutputStarts.count ? map.clipOutputStarts[last + 1] : map.duration
        let (sum, overflow) = start.addingReportingOverflow(defaultDuration)
        let end = min(overflow ? .max : sum, takeEnd, map.duration)
        guard end - start >= minimumDuration, let source = track(doc, outputs: []).source(of: start..<end) else { return nil }
        var ids = Set(doc.privacy.blocks.map(\.id))
        let block = PrivacyBlock(
            id: DocumentIDs.new("p-", makeID, avoiding: &ids), take: source.take, start: source.start, end: source.end,
            effect: .blur, strength: 0.6, color: RGBA(0, 0, 0, 1), rect: defaultRect, keys: [], origin: .manual)
        var changes = DocumentChanges()
        changes.insert(block, into: .privacyBlocks, at: doc.privacy.blocks.firstIndex { $0.start > block.start } ?? doc.privacy.blocks.count)
        return changes.step(label: .privacyAdd, target: block.id)
    }

    /// Moves block `id` so its output range starts at `toOutputStart`, kept in the output; its keys move with it (by the
    /// change of its source start, either way and into another take: each keeps its offset from the block's start, held
    /// to the ends of the clock). `nil` if it stays where it is, if there is no such block or it shows nothing.
    public static func move(_ doc: EditDocument, id: String, toOutputStart: Int64) -> EditStep? {
        guard let k = doc.privacy.blocks.firstIndex(where: { $0.id == id }), let output = outputRange(of: doc.privacy.blocks[k], in: doc),
            let source = track(doc, outputs: [output]).moved(0, toOutputStart: toOutputStart)
        else { return nil }
        var block = doc.privacy.blocks[k]
        let (from, to) = (block.start, source.start)
        (block.take, block.start, block.end) = (source.take, source.start, source.end)
        block.keys = block.keys.map { RectKey(t: shifted($0.t, from: from, to: to), rect: $0.rect) }
        return replace(doc, k, block, label: .privacyMove)
    }

    /// Moves `edge` of block `id` to output instant `toOutput`, leaving it at least `minimumDuration` long (a shorter one
    /// only grows); the other edge and the keys keep their source instants. `nil` if the edge stays, if there is no such
    /// block or it shows nothing.
    public static func trim(_ doc: EditDocument, id: String, edge: ClipEdge, toOutput: Int64) -> EditStep? {
        guard let k = doc.privacy.blocks.firstIndex(where: { $0.id == id }), let output = outputRange(of: doc.privacy.blocks[k], in: doc)
        else { return nil }
        var block = doc.privacy.blocks[k]
        let range = SourceRange(take: block.take, start: block.start, end: block.end)
        guard let trimmed = track(doc, outputs: [output]).trimmed(0, range, edge: edge, toOutput: toOutput, minimum: minimumDuration)
        else { return nil }
        (block.start, block.end) = (trimmed.start, trimmed.end)
        return replace(doc, k, block, label: .privacyTrim)
    }

    /// Changes what a block does: `nil` leaves a field alone; the strength is kept in 0…1. `nil` if nothing changes, if
    /// there is no such block or a value is not a number.
    public static func change(
        _ doc: EditDocument, id: String, effect: PrivacyEffect? = nil, strength: Double? = nil, color: RGBA? = nil
    ) -> EditStep? {
        guard let k = doc.privacy.blocks.firstIndex(where: { $0.id == id }) else { return nil }
        var block = doc.privacy.blocks[k]
        if let effect { block.effect = effect }
        if let strength {
            guard !strength.isNaN else { return nil }
            block.strength = min(max(strength, 0), 1)
        }
        if let color {
            guard ![color.r, color.g, color.b, color.a].contains(where: \.isNaN) else { return nil }
            block.color = color
        }
        return replace(doc, k, block, label: .privacyChange)
    }

    /// Puts block `id`'s rect at `rect` (kept inside the content, `PrivacyGeometry.clamped`) at source time `atSource`.
    /// With no keys it is the block's rect; with keys, every key (and the rect) moves by what the rect at that time
    /// changes, so the block keeps the shape of its path. `nil` if nothing changes, if there is no such block or a value
    /// is not a number.
    public static func setRect(_ doc: EditDocument, id: String, _ rect: NormalizedRect, atSource: HostTime) -> EditStep? {
        guard let k = doc.privacy.blocks.firstIndex(where: { $0.id == id }),
            ![rect.x, rect.y, rect.width, rect.height].contains(where: { !$0.isFinite })
        else { return nil }
        var block = doc.privacy.blocks[k]
        let target = PrivacyGeometry.clamped(rect)
        if block.keys.isEmpty {
            block.rect = target
        } else {
            let now = PrivacyGeometry.rect(of: block, atSource: atSource)
            let (dx, dy, dw, dh) = (target.x - now.x, target.y - now.y, target.width - now.width, target.height - now.height)
            func shifted(_ r: NormalizedRect) -> NormalizedRect {
                PrivacyGeometry.clamped(NormalizedRect(x: r.x + dx, y: r.y + dy, width: r.width + dw, height: r.height + dh))
            }
            block.rect = shifted(block.rect)
            block.keys = block.keys.map { RectKey(t: $0.t, rect: shifted($0.rect)) }
        }
        return replace(doc, k, block, label: .privacyChange)
    }

    /// Deletes the blocks with the ids `ids`; ids of no block are left out, `nil` with none.
    public static func delete(_ doc: EditDocument, ids: Set<String>) -> EditStep? {
        var changes = DocumentChanges()
        var removed: [String] = []
        for (k, block) in doc.privacy.blocks.enumerated() where ids.contains(block.id) {
            changes.remove(block, from: .privacyBlocks, at: k - removed.count)
            removed.append(block.id)
        }
        return changes.step(label: .privacyDelete, target: removed.joined(separator: ","))
    }

    /// Adds the blocks the scan found, in one step, each with a new id (`makeID("p-")`) and in its place by start.
    /// `nil` with none.
    public static func addAuto(_ doc: EditDocument, blocks: [PrivacyBlock], makeID: (String) -> String) -> EditStep? {
        var ids = Set(doc.privacy.blocks.map(\.id))
        var working = doc.privacy.blocks
        var changes = DocumentChanges()
        for var block in blocks.enumerated().sorted(by: { ($0.element.start, $0.offset) < ($1.element.start, $1.offset) }).map(\.element) {
            block.id = DocumentIDs.new("p-", makeID, avoiding: &ids)
            let index = working.firstIndex { $0.start > block.start } ?? working.count
            changes.insert(block, into: .privacyBlocks, at: index)
            working.insert(block, at: index)
        }
        return changes.step(label: .privacyAuto, target: EditCollection.privacyBlocks.rawValue)
    }

    /// Where the output shows `block`, with the cuts inside it closed; `nil` if it shows nothing.
    public static func outputRange(of block: PrivacyBlock, in doc: EditDocument) -> Range<Int64>? {
        let range = SourceRange(take: block.take, start: block.start, end: block.end)
        return OutputBlockTrack.outputs(of: [range], in: TimeMap(sequence: doc.sequence))[0]
    }

    /// The blocks the output shows at output instant `atOutput`, in the order of the document.
    public static func blocks(atOutput: Int64, in doc: EditDocument) -> [PrivacyBlock] {
        let map = TimeMap(sequence: doc.sequence)
        let ranges = doc.privacy.blocks.map { SourceRange(take: $0.take, start: $0.start, end: $0.end) }
        let outputs = OutputBlockTrack.outputs(of: ranges, in: map)
        return zip(doc.privacy.blocks, outputs).compactMap { block, output in
            guard let output, output.contains(atOutput) else { return nil }
            return block
        }
    }

    /// `t` at the same signed offset from `to` as it is from `from`, held to 0 and to the latest host time (a key may be
    /// before the block's start, and a block may move earlier or into an earlier take).
    private static func shifted(_ t: HostTime, from: HostTime, to: HostTime) -> HostTime {
        if t >= from {
            let (sum, overflow) = to.nanoseconds.addingReportingOverflow(t.nanoseconds - from.nanoseconds)
            return HostTime(nanoseconds: overflow ? .max : sum)
        }
        let back = from.nanoseconds - t.nanoseconds
        return HostTime(nanoseconds: to.nanoseconds > back ? to.nanoseconds - back : 0)
    }

    private static func replace(_ doc: EditDocument, _ k: Int, _ block: PrivacyBlock, label: EditLabel) -> EditStep? {
        let old = doc.privacy.blocks[k]
        var changes = DocumentChanges()
        changes.replace(old, with: block, in: .privacyBlocks, id: old.id)
        return changes.step(label: label, target: old.id)
    }

    private static func track(_ doc: EditDocument, outputs: [Range<Int64>?]) -> OutputBlockTrack {
        OutputBlockTrack(sequence: doc.sequence, map: TimeMap(sequence: doc.sequence), outputs: outputs)
    }
}
