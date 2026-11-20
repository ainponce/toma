// SPDX-License-Identifier: GPL-3.0-or-later
import Analysis
import CoreGraphics
import Editing
import ProjectFormat

/// What the timeline's Annotations track shows and where (phase 3 design §5.6, plan 3a decision 17): a block for each
/// annotation where the output shows it (`AnnotationTiming.outputRange`, the cuts inside it closed, cut at the end of the
/// output; one all in a cut, or after the end, is not there), in lanes when they overlap, and those of the whole video as
/// a thin bar on top.
///
/// The row, `rowHeight` tall: 3 pt of padding at the top and the bottom; the bar, 4 pt, and 4 pt under it; then the lanes,
/// which share what is left (16 pt each once there are two). Its edges are not edit points (as the privacy blocks').
public enum AnnotationTrackRules {
    /// An annotation of the track: where it is (`item`, on `.annotations`), its lane from the top (0 for the bar) and whether
    /// it is of the whole video, the bar.
    public struct Item: Equatable, Sendable {
        public var item: TimelineItem
        public var lane: Int
        public var whole: Bool

        public init(item: TimelineItem, lane: Int, whole: Bool) {
            self.item = item
            self.lane = lane
            self.whole = whole
        }
    }

    /// The most lanes: the annotations that find none free go in the last one.
    public static let maxLanes = 4
    /// The height of a lane, once there are two or more.
    public static let laneHeight = 16.0
    /// The bar of the whole video, and the room it takes with the space under it.
    public static let barHeight = 4.0
    public static let barRoom = 8.0
    /// The space at the top and at the bottom of the row.
    public static let padding = 3.0

    /// The annotations of `doc` the output shows, bottom to top as they are drawn and pointed at: the whole video's first,
    /// then each lane, from the top. Each one, in the order of its start (then of its end and of the document), goes in
    /// the first lane free at its start (whose last block ends at or before it), up to `maxLanes`; the others go in the
    /// last, where they may overlap, the longest lowest: the one under the pointer is then the shortest there.
    public static func items(_ doc: EditDocument) -> [Item] {
        guard !doc.annotations.items.isEmpty else { return [] }
        let map = TimeMap(sequence: doc.sequence)
        var wholes: [Item] = []
        var timed: [(k: Int, item: TimelineItem)] = []
        for (k, annotation) in doc.annotations.items.enumerated() {
            guard let range = AnnotationTiming.outputRange(of: annotation, document: doc, timeMap: map),
                range.lowerBound < map.duration
            else { continue }
            let output = range.lowerBound..<min(range.upperBound, map.duration)
            guard !output.isEmpty else { continue }
            let item = TimelineItem(id: annotation.id, track: .annotations, output: output)
            if case .whole = annotation.anchor {
                wholes.append(Item(item: item, lane: 0, whole: true))
            } else {
                timed.append((k, item))
            }
        }
        timed.sort { a, b in
            (a.item.output.lowerBound, a.item.output.upperBound, a.k) < (b.item.output.lowerBound, b.item.output.upperBound, b.k)
        }
        var ends: [Int64] = []
        var laned: [(item: Item, order: Int)] = []
        for (order, entry) in timed.enumerated() {
            let start = entry.item.output.lowerBound
            let lane: Int
            if let free = ends.firstIndex(where: { $0 <= start }) {
                lane = free
                ends[free] = entry.item.output.upperBound
            } else if ends.count < maxLanes {
                lane = ends.count
                ends.append(entry.item.output.upperBound)
            } else {
                lane = maxLanes - 1
                ends[lane] = max(ends[lane], entry.item.output.upperBound)
            }
            laned.append((Item(item: entry.item, lane: lane, whole: false), order))
        }
        laned.sort { a, b in
            guard a.item.lane == b.item.lane else { return a.item.lane < b.item.lane }
            if a.item.lane == maxLanes - 1 {
                let (la, lb) = (length(a.item), length(b.item))
                if la != lb { return la > lb }
            }
            return a.order < b.order
        }
        return wholes + laned.map(\.item)
    }

    /// How tall the row of `doc` is, in points: `max(28, 6 + 16 × lanes + (bar ? 8 : 0))` (`TimelineLayout.annotationsHeight`
    /// at least).
    public static func rowHeight(_ doc: EditDocument) -> Double {
        rowHeight(items(doc))
    }

    /// How tall the row of `items` is.
    public static func rowHeight(_ items: [Item]) -> Double {
        let (lanes, bar) = shape(of: items)
        return max(TimelineLayout.annotationsHeight, 2 * padding + laneHeight * Double(lanes) + (bar ? barRoom : 0))
    }

    /// The lanes `items` take and whether they have a bar.
    public static func shape(of items: [Item]) -> (lanes: Int, bar: Bool) {
        var lanes = 0, bar = false
        for item in items {
            if item.whole { bar = true } else { lanes = max(lanes, item.lane + 1) }
        }
        return (lanes, bar)
    }

    /// Where a block is drawn in a row `rowHeight` tall from `rowTop` with `lanes` lanes (and the bar, with `bar`): the bar
    /// (`lane` `nil`) 4 pt under the padding; lane `lane` its share of the row under the bar, 1 pt in from each of its
    /// edges once there are two or more lanes, so they are apart.
    public static func band(lane: Int?, lanes: Int, bar: Bool, rowTop: Double, rowHeight: Double) -> (top: Double, height: Double) {
        guard let lane else { return (rowTop + padding, barHeight) }
        let (top, height) = laneBand(lane, lanes: lanes, bar: bar, rowTop: rowTop, rowHeight: rowHeight)
        let inset = lanes > 1 ? 1.0 : 0
        return (top + inset, max(height - 2 * inset, 1))
    }

    /// The annotation at `point`, in the timeline's own coordinates (as `TimelineHitTest.hit`: `x` with the headers, `y`
    /// with the rows' scroll) on the row `rowHeight` tall from `rowTop` that shows `items` (`items(_:)`), at `scale` and
    /// scrolled by `offset` (`TimelineLayout`); `nil` on nothing or outside the row.
    ///
    /// The top of the row, down to the bar's room, is the bar (all of the row when there are no lanes); under it, the lane
    /// the point is in (the padding is its nearest lane's). Of the blocks there under the point, the top one, but at a point
    /// two blocks share the one that starts there. Within `TimelineHitTest.edgeZone` of an edge (a third of its width at
    /// most) a block's edge; the bar has none (the whole video neither moves nor trims).
    public static func hit(
        at point: CGPoint, items: [Item], rowTop: Double, rowHeight: Double, scale: Double, offset: Double
    ) -> (id: String, edge: ClipEdge?)? {
        let y = Double(point.y), px = Double(point.x)
        guard y >= rowTop, y < rowTop + rowHeight, scale > 0, scale.isFinite else { return nil }
        let (lanes, bar) = shape(of: items)
        let onBar = bar && (lanes == 0 || y < rowTop + padding + barRoom)
        var lane = 0
        if !onBar {
            guard lanes > 0 else { return nil }
            let first = laneBand(0, lanes: lanes, bar: bar, rowTop: rowTop, rowHeight: rowHeight)
            lane = min(max(Int(((y - first.top) / first.height).rounded(.down)), 0), lanes - 1)
        }
        func x(_ τ: Int64) -> Double { TimelineLayout.headerWidth + Double(τ) * scale / 1e9 - offset }
        var found: (item: Item, left: Double, right: Double)?
        for item in items where onBar ? item.whole : !item.whole && item.lane == lane {
            let (left, right) = (x(item.item.output.lowerBound), x(item.item.output.upperBound))
            guard px >= left, px <= right else { continue }
            // At a shared point, the block that starts there.
            if let current = found, current.right > px, right <= px { continue }
            found = (item, left, right)
        }
        guard let (item, left, right) = found else { return nil }
        guard !item.whole else { return (item.item.id, nil) }
        let zone = min(TimelineHitTest.edgeZone, (right - left) / 3)
        if px - left <= zone { return (item.item.id, .start) }
        if right - px <= zone { return (item.item.id, .end) }
        return (item.item.id, nil)
    }

    /// Lane `lane`'s whole share of the row: under the padding and the bar's room, `(rowHeight − 6 − bar) / lanes` tall.
    private static func laneBand(_ lane: Int, lanes: Int, bar: Bool, rowTop: Double, rowHeight: Double) -> (top: Double, height: Double) {
        let top = rowTop + padding + (bar ? barRoom : 0)
        let height = max((rowHeight - 2 * padding - (bar ? barRoom : 0)) / Double(max(lanes, 1)), 1)
        return (top + height * Double(lane), height)
    }

    private static func length(_ item: Item) -> Int64 {
        item.item.output.upperBound - item.item.output.lowerBound
    }
}
