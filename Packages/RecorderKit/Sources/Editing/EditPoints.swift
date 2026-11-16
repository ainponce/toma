// SPDX-License-Identifier: GPL-3.0-or-later
import ProjectFormat

/// The instants of the output that ↑ and ↓ move the playhead to and that edges snap to (design §5.5 and §5.7): the
/// edges of the clips, of the zoom blocks and of the camera's layout blocks (1c design §5.5), the camera and the screen
/// changes, the take's markers, and the start and the end, all in output time.
///
/// Each one is where the output shows it (`TimeMap`): a block from its first kept instant to the end of its last one,
/// with the cuts inside it closed (`outputRange(ofSource:take:)`); a change or a marker at its own instant if it is
/// kept. What is cut is not a point: a change in a cut rules from the start of the next clip, which is one already.
public struct EditPoints: Sendable {
    /// In order, without repeats, from 0 to the output's duration.
    public private(set) var all: [Int64]

    /// `markers`: the source instants of the take's `marker` events. In 1b a project has one take, the sequence's.
    public init(document: EditDocument, timeMap: TimeMap, markers: [HostTime]) {
        var points = timeMap.clipOutputStarts + [0, timeMap.duration]
        let blocks = document.zoom.regions.map { ($0.take, $0.start, $0.end) }
            + document.camera.layouts.map { ($0.take, $0.start, $0.end) }
        for (take, start, end) in blocks where start < end {
            if let range = timeMap.outputRange(ofSource: start..<end, take: take) {
                points += [range.lowerBound, range.upperBound]
            }
        }
        points += document.camera.changes.compactMap { timeMap.output(atSource: $0.t, take: $0.take) }
        points += document.screens.changes.compactMap { timeMap.output(atSource: $0.t, take: $0.take) }
        if let take = document.sequence.first?.take {
            points += markers.compactMap { timeMap.output(atSource: $0, take: take) }
        }
        all = Set(points).sorted()
    }

    /// The last point before `t`; `nil` if there is none.
    public func previous(before t: Int64) -> Int64? {
        let index = firstIndex { $0 >= t }
        return index > 0 ? all[index - 1] : nil
    }

    /// The first point after `t`; `nil` if there is none.
    public func next(after t: Int64) -> Int64? {
        let index = firstIndex { $0 > t }
        return index < all.count ? all[index] : nil
    }

    /// The point of `all` or of `extra` (the playhead) closest to `t`, if it is at most `tolerance` away; otherwise
    /// `t`. Of two as close, the earlier.
    public func snap(_ t: Int64, tolerance: Int64, also extra: [Int64]) -> Int64 {
        guard tolerance >= 0 else { return t }
        // The points of `all` on either side of `t`.
        let index = firstIndex { $0 >= t }
        let candidates = all[max(index - 1, 0)..<min(index + 1, all.count)] + extra
        guard let closest = candidates.min(by: { (Self.distance($0, t), $0) < (Self.distance($1, t), $1) }),
            Self.distance(closest, t) <= UInt64(tolerance)
        else { return t }
        return closest
    }

    /// The index of the first point for which `isAfter` is true, given that it is false before it and true from it on.
    private func firstIndex(where isAfter: (Int64) -> Bool) -> Int {
        var (low, high) = (0, all.count)
        while low < high {
            let middle = low + (high - low) / 2
            if isAfter(all[middle]) { high = middle } else { low = middle + 1 }
        }
        return low
    }

    /// `|a − b|`, which never overflows: it fits in a `UInt64`, and the wrapped difference holds it.
    private static func distance(_ a: Int64, _ b: Int64) -> UInt64 {
        a >= b ? UInt64(bitPattern: a &- b) : UInt64(bitPattern: b &- a)
    }
}
