// SPDX-License-Identifier: GPL-3.0-or-later
import ProjectFormat

/// The blocks of a track of the timeline, kept in source time and edited in output time: the Zoom track's (design §5.4)
/// and the Camera track's layouts (1c design §5.5). Each track places its blocks in the output its own way and gives
/// them here as `outputs`; what is free, where a block can go and which source a place in the output is are the same for
/// both.
///
/// - A place in the output goes back to the source as the planner places its blocks (plan decision 16, 1c plan decision
///   9): its start is the source of its output start, its end the source of 1 ns before its output end, and 1 ns, but
///   never past the source shown at its output end in the same clip.
/// - Blocks never overlap on the track: a new one goes only in free space, and a move or a trim stops at the block next to
///   it and at the ends of the output. A block that shows nothing takes no room, so one hidden whole in a cut stays where
///   it is in the source, under what is placed across the closed cut.
struct OutputBlockTrack {
    let sequence: [Clip]
    let map: TimeMap
    /// The output range of each block, in the order of the document; `nil` for one that shows nothing.
    let outputs: [Range<Int64>?]

    /// The output range of each of `blocks` (`TimeMap.outputRange(ofSource:take:)`, with the cuts inside it closed), in
    /// order; `nil` for one that shows nothing.
    static func outputs(of blocks: [SourceRange], in map: TimeMap) -> [Range<Int64>?] {
        blocks.map { block in
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

    /// The longest free part of `range` (the first of those as long), if it lasts at least `minimum`.
    func longestFree(in range: Range<Int64>, atLeast minimum: Int64) -> Range<Int64>? {
        let parts = free(range).filter { $0.upperBound - $0.lowerBound >= minimum }
        return parts.max { $0.upperBound - $0.lowerBound < $1.upperBound - $1.lowerBound }
    }

    /// Where block `k` can go: from the end of the block before it (or 0) to the start of the one after it (or the end
    /// of the output). A block over it (placed across a cut over one hidden there, or in a document edited by hand) is no
    /// limit.
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
        guard let shown = map.source(atOutput: τ), sequence.indices.contains(shown.clip) else { return nil }
        return (sequence[shown.clip].take, shown.source)
    }

    /// The source range of `output`, of the take shown at both its ends; `nil` if they are not of one take.
    func source(of output: Range<Int64>) -> SourceRange? {
        guard !output.isEmpty, let first = shown(atOutput: output.lowerBound),
            let end = sourceEnd(of: output.upperBound, take: first.take), first.source < end
        else { return nil }
        return SourceRange(take: first.take, start: first.source, end: end)
    }

    /// The source end of a block of `take` whose output ends at `upper`: the source of `upper − 1` and 1 ns, but never past
    /// the source shown at `upper` in the same clip; `nil` if `upper − 1` is not in a clip of `take`.
    func sourceEnd(of upper: Int64, take: String) -> HostTime? {
        guard upper > 0, let last = map.source(atOutput: upper - 1), sequence.indices.contains(last.clip),
            sequence[last.clip].take == take
        else { return nil }
        var end = HostTime(nanoseconds: last.source.nanoseconds + 1)
        if upper < map.duration, let next = map.source(atOutput: upper), next.clip == last.clip { end = min(end, next.source) }
        return end
    }

    /// The output end where block `block`, shown over `output`, was placed: `output`'s end, or 1 ns after it when placing
    /// the block's end there gives its source end. At a speed above 1 the source end of a place maps back 1 ns short, so
    /// this is the length a block was given, which moving it keeps.
    func placedEnd(of output: Range<Int64>, _ block: SourceRange) -> Int64 {
        guard output.upperBound < map.duration, sourceEnd(of: output.upperBound + 1, take: block.take) == block.end
        else { return output.upperBound }
        return output.upperBound + 1
    }

    /// The source range of block `k` with its output range starting at `toOutputStart`, `length` long (its own by
    /// default): it stops at the blocks before and after it and at the ends of the output. `nil` if it stays where it is,
    /// if it shows nothing, or if the place is not of one take.
    func moved(_ k: Int, toOutputStart: Int64, length: Int64? = nil) -> SourceRange? {
        guard let current = outputs[k] else { return nil }
        let room = room(around: k)
        let length = min(length ?? (current.upperBound - current.lowerBound), room.upperBound - room.lowerBound)
        let start = min(max(toOutputStart, room.lowerBound), max(room.upperBound - length, room.lowerBound))
        guard start != current.lowerBound else { return nil }
        return source(of: start..<(start + length))
    }

    /// `block`, block `k`, with `edge` moved to output instant `toOutput`: it stops at the block next to it and at the ends
    /// of the output, and leaves the block at least `minimum` long (a shorter one only grows). The other edge keeps its
    /// source instant. `nil` if the edge stays where it is, if the block shows nothing, or if that instant is not of its
    /// take.
    func trimmed(_ k: Int, _ block: SourceRange, edge: ClipEdge, toOutput: Int64, minimum: Int64) -> SourceRange? {
        guard let current = outputs[k] else { return nil }
        let room = room(around: k)
        var trimmed = block
        switch edge {
        case .start:
            let latest = max(current.upperBound - minimum, current.lowerBound)
            let lower = min(max(toOutput, room.lowerBound), latest)
            guard lower != current.lowerBound, let shown = shown(atOutput: lower), shown.take == block.take else { return nil }
            trimmed.start = shown.source
        case .end:
            let earliest = min(current.lowerBound + minimum, current.upperBound)
            let upper = max(min(toOutput, room.upperBound), earliest)
            guard upper != current.upperBound, let end = sourceEnd(of: upper, take: block.take) else { return nil }
            trimmed.end = end
        }
        guard trimmed.start < trimmed.end else { return nil }
        return trimmed
    }
}
