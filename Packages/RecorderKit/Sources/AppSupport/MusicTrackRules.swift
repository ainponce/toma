// SPDX-License-Identifier: GPL-3.0-or-later
import Editing
import ProjectFormat

/// What is under the pointer in the Music track.
public enum MusicTrackHit: Equatable, Sendable {
    case body(id: String)
    case edge(id: String, edge: ClipEdge)
    /// With ⌥: the body, to slide the piece under its place (`offset`).
    case slip(id: String)
    case gainLine(id: String)
    case empty
}

/// What the timeline's Music track shows and does where it is pointed at (phase 3 design §7.4, plan 3c decisions 7, 13
/// and 15).
public enum MusicTrackRules {
    /// How far from an edge or the volume line, in points, it is still pointed at.
    public static let grab = 4.0
    /// The most places a piece is shown to start again; a piece shorter than the output over this has no more marks.
    public static let maxWraps = 4096

    /// A piece of music as the output plays it.
    public struct Block: Equatable, Sendable {
        public var id: String
        /// Where it sounds: `[start, min(end, duration of the output))`.
        public var output: Range<Int64>
        /// Each at most half of `output`.
        public var fadeIn: Int64
        public var fadeOut: Int64
        /// The output times, inside `output`, where the piece starts again (with `loop`).
        public var wraps: [Int64]
        /// With `loop` off, where the file ends and the rest is silence (`output.lowerBound` if it was already over at the
        /// start); `nil` when the file lasts to the end of the block or its length is not known.
        public var runsOutAt: Int64?
        /// In dB.
        public var gain: Double

        public init(id: String, output: Range<Int64>, fadeIn: Int64, fadeOut: Int64, wraps: [Int64], runsOutAt: Int64?, gain: Double) {
            self.id = id
            self.output = output
            self.fadeIn = fadeIn
            self.fadeOut = fadeOut
            self.wraps = wraps
            self.runsOutAt = runsOutAt
            self.gain = gain
        }
    }

    /// The pieces of `doc`'s music that sound, by their start; `lengths` is each file's length in ns by `MusicItem.source`
    /// (a source without one has no wraps nor end). The end that sounds is cut at the output's (`timeMap.duration`).
    public static func blocks(_ doc: EditDocument, timeMap: TimeMap, lengths: [String: Int64]) -> [Block] {
        let items = doc.music.items.sorted { $0.start < $1.start }
        return items.compactMap { item -> Block? in
            let (start, end) = (max(item.start, 0), min(item.end, timeMap.duration))
            guard start < end else { return nil }
            let half = (end - start) / 2
            var wraps: [Int64] = []
            var runsOutAt: Int64?
            if let length = lengths[item.source], length > 0 {
                let offset = max(item.offset, 0)
                if item.loop {
                    var next = start + (length - offset % length)
                    while next < end, wraps.count < maxWraps {
                        wraps.append(next)
                        let (sum, overflow) = next.addingReportingOverflow(length)
                        if overflow { break }
                        next = sum
                    }
                } else {
                    let (left, overflow) = length.subtractingReportingOverflow(offset)
                    let over = overflow || left <= 0 ? start : start + left
                    if over < end { runsOutAt = max(over, start) }
                }
            }
            return Block(
                id: item.id, output: start..<end, fadeIn: min(max(item.fadeIn, 0), half), fadeOut: min(max(item.fadeOut, 0), half),
                wraps: wraps, runsOutAt: runsOutAt, gain: item.gain)
        }
    }

    /// What is at (`x`, `y`) of a track `height` tall, with each piece's span in points: its edge within `grab` (the
    /// nearest), then, inside it, ⌥ is `slip`, its volume line within `grab` (`AudioRowGeometry`) is `gainLine`, and the
    /// rest is `body`.
    public static func hit(
        x: Double, y: Double, option: Bool, height: Double, blocks: [(Block, x: ClosedRange<Double>)]
    ) -> MusicTrackHit {
        var edge: (id: String, edge: ClipEdge, distance: Double)?
        for (block, span) in blocks {
            for (side, at) in [(ClipEdge.start, span.lowerBound), (.end, span.upperBound)] {
                let distance = abs(at - x)
                if distance <= grab, distance < (edge?.distance ?? .infinity) { edge = (block.id, side, distance) }
            }
        }
        if let edge { return .edge(id: edge.id, edge: edge.edge) }
        guard let (block, _) = blocks.first(where: { $0.x.contains(x) }) else { return .empty }
        if option { return .slip(id: block.id) }
        if abs(AudioRowGeometry.y(ofGain: block.gain, height: height) - y) <= grab { return .gainLine(id: block.id) }
        return .body(id: block.id)
    }
}
