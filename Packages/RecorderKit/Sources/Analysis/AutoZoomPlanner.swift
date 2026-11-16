// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import ProjectFormat

/// The automatic zoom `autoZoom-1` (design §8.2): editable zoom blocks from the take's clicks and drags (and pauses of
/// the cursor, with `.clicksAndPauses`), which typing and scrolling hold but never start. A pure function of the take's
/// events and the document (its clips, screens, aspect, padding, settings, user blocks and suppressed ranges).
///
/// It works in output time, so it sees what the output shows (cuts closed, speeds applied; plan decision 16), with the
/// `Activity` of the take and these steps; seconds are of output:
/// 1. Groups: in time order, a click, drag or pause joins the group before it while it starts at most `groupGap` after
///    the group's last one ends and the box of the group with it, with 12 % of the crop on each side, fits in the crop of
///    depth `depth` (the stage over `depth`); otherwise it starts a group.
/// 2. Holding: a span of typing (only with `holdWhileTyping`) or of scrolling that starts at most `groupGap` after a
///    group's last element, or inside it or before it and still going, holds the group to the span's end.
/// 3. Typing alone: with `holdWhileTyping`, a span of typing that holds no group makes one when the last click at or
///    before its start is at most 10 s before it and the pointer went at most 40 pt from that click until then: the group
///    starts with the typing, its box is the click's point.
/// 4. A block lasts from `leadIn` before its group's first element (never before 0) to `leadOut` after its last one or
///    the end of what holds it, at least 1.2 s (its end goes later), never past the end of the output.
/// 5. Neighbours: a block that starts less than 0.8 s after the end of the one before it (or before that end) is merged
///    into it when their boxes fit together (as in 1); otherwise both meet at the midpoint between the last element of
///    the first and the first element of the second.
/// 6. Depth: `min(depth, the depth whose crop fits the box with its margin)`; a block below 1.15× is not made. A block at
///    `depth` leaves it out (`nil`: it follows the setting).
/// 7. Focus: `.follow` with `follow`; otherwise fixed at the centre of the box, as fractions of the screen's rect at
///    the instant of the group's first element.
/// 8. The user's blocks win: a block over one of the user's blocks (`origin: .user`) of the take keeps what is left
///    free, each part only if it lasts at least 1.0 s. A block (or part) and a `suppressed` range of the take (where the
///    user deleted an automatic one) that overlap by half of the range or more, or by half of the block or more, make
///    nothing: a deleted zoom stays deleted when it would come back longer, and none comes back inside a deletion. Both
///    are compared in output time, through `TimeMap.outputRange(ofSource:take:)`; a user's block or a deletion with no
///    output (cut whole, or 0 ns of it kept) takes no room.
/// 9. Each part goes to the source (plan decision 16): its start is the source of its output start, its end the source
///    of 1 ns before its output end plus 1 ns, but never past the source shown at its output end in the same clip (below
///    1× those two are often the same instant), so it ends no later than whatever starts at that output instant. A part
///    that comes after a user's block in output time starts no earlier than the end of that block (faster than 1×, the
///    source of the first instant after it can be a nanosecond inside it); a part left empty is not made. Its id is
///    `regionID`. In start order, never overlapping each other or the user's blocks that have output, in the source or
///    in output time.
///
/// With `enabled` off, or an output of 0 ns, it makes nothing.
public enum AutoZoomPlanner {
    public static let id = "autoZoom-1"

    /// Room left around a block's box on each side, as a fraction of the crop.
    static let margin = 0.12
    static let typingClickWindow: Int64 = 10_000_000_000
    /// In global points.
    static let typingClickDistance = 40.0
    static let minimumDuration: Int64 = 1_200_000_000
    static let neighbourGap: Int64 = 800_000_000
    static let minimumDepth = 1.15
    static let minimumFreeDuration: Int64 = 1_000_000_000

    public static func plan(take: TakeRecord, events: [InputEvent], document: EditDocument) -> [ZoomRegion] {
        let timeMap = TimeMap(sequence: document.sequence)
        guard document.zoom.auto.enabled, timeMap.duration > 0 else { return [] }
        let stage = StagePoints(take: take, events: events, document: document)
        let found = ActivityExtraction(take: take, events: events, timeMap: timeMap, stage: stage)
        let planner = Planner(settings: document.zoom.auto, stage: stage, timeMap: timeMap, sequence: document.sequence)
        let blocks = planner.neighboursSettled(planner.blocks(of: planner.groups(found)))

        let users = planner.placed(
            document.zoom.regions.filter { $0.origin == .user && $0.take == take.id }.map { ($0.start, $0.end) }, take: take.id)
        let suppressed = planner.placed(
            document.zoom.suppressed.filter { $0.take == take.id }.map { ($0.start, $0.end) }, take: take.id).map(\.output)
        let parts = blocks.flatMap { block in
            planner.free(block.start..<block.end, from: users.map(\.output))
                .filter { !planner.isSuppressed($0, by: suppressed) }
                .map { (block: block, output: $0) }
        }
        return planner.regions(of: parts, beside: users, take: take.id)
    }

    /// The id of an automatic block of `take` over the source `[start, end)` (plan decision 10): `z-` and the first 4
    /// bytes, in lowercase hex, of SHA-256 of the UTF-8 of `"autoZoom-1|<take>|<start>|<end>"`, the times in
    /// nanoseconds. Planning again without changes gives the same ids.
    public static func regionID(take: String, start: HostTime, end: HostTime) -> String {
        PlannerID.make(prefix: "z-", [id, take, "\(start.nanoseconds)", "\(end.nanoseconds)"])
    }
}

/// The steps of `AutoZoomPlanner.plan`, with its settings in output nanoseconds.
private struct Planner {
    /// What a block zooms on: a click, a drag or a pause, over `[start, end]` of output.
    struct Element {
        var start: Int64
        var end: Int64
        /// In stage units.
        var box: Rect
        /// The source instant of `start`, where `box` was placed.
        var host: HostTime
    }

    struct Group {
        /// The output times of its first element's start and its last element's end.
        var first: Int64
        var last: Int64
        var box: Rect
        var host: HostTime
        /// The end of what holds it; `last` when nothing does.
        var held: Int64
    }

    /// A source range of the take, and the output range it is seen in.
    struct Placed {
        var start: HostTime
        var end: HostTime
        var output: Range<Int64>
    }

    struct Block {
        var start: Int64
        var end: Int64
        /// As in `Group`.
        var first: Int64
        var last: Int64
        var box: Rect
        var host: HostTime
        var depth: Double
    }

    let settings: AutoZoomSettings
    let stage: StagePoints
    let timeMap: TimeMap
    /// The clips `timeMap` maps.
    let sequence: [Clip]
    let gap: Int64
    let leadIn: Int64
    let leadOut: Int64

    init(settings: AutoZoomSettings, stage: StagePoints, timeMap: TimeMap, sequence: [Clip]) {
        self.settings = settings
        self.stage = stage
        self.timeMap = timeMap
        self.sequence = sequence
        gap = TimeMap.outputNanoseconds(seconds: settings.groupGap)
        leadIn = TimeMap.outputNanoseconds(seconds: settings.leadIn)
        leadOut = TimeMap.outputNanoseconds(seconds: settings.leadOut)
    }

    /// Steps 1 to 3: the groups, with what holds them, in start order.
    func groups(_ found: ActivityExtraction) -> [Group] {
        let activity = found.activity
        var elements = activity.clicks.map { Element(start: $0.output, end: $0.output, box: Self.box(at: $0.point), host: $0.host) }
        elements += activity.drags.compactMap { drag in
            timeMap.source(atOutput: drag.start).map { Element(start: drag.start, end: drag.end, box: drag.box, host: $0.source) }
        }
        if settings.triggers == .clicksAndPauses {
            elements += activity.pauses.map { Element(start: $0.output, end: $0.output, box: Self.box(at: $0.point), host: $0.host) }
        }
        elements = elements.enumerated().sorted { ($0.element.start, $0.offset) < ($1.element.start, $1.offset) }.map(\.element)

        var groups: [Group] = []
        for element in elements {
            if let group = groups.last, element.start - group.last <= gap {
                let box = Self.union(group.box, element.box)
                if fits(box) {
                    groups[groups.count - 1] = Group(
                        first: group.first, last: max(group.last, element.end), box: box, host: group.host, held: group.held)
                    continue
                }
            }
            groups.append(Group(first: element.start, last: element.end, box: element.box, host: element.host, held: element.end))
        }

        let typing = settings.holdWhileTyping ? activity.typing : []
        if settings.holdWhileTyping {
            let alone = typing.filter { span in !groups.contains { holds(span, $0) } }
            groups += alone.compactMap { typingGroup($0, found) }
        }
        let spans = typing + activity.scrolls
        return groups.map { group in
            var group = group
            for span in spans where holds(span, group) { group.held = max(group.held, span.upperBound) }
            return group
        }
        .enumerated().sorted { ($0.element.first, $0.offset) < ($1.element.first, $1.offset) }.map(\.element)
    }

    /// Whether `span` holds `group`: it starts at most `gap` after the group's last element (or before) and ends after
    /// the group's first.
    private func holds(_ span: Range<Int64>, _ group: Group) -> Bool {
        span.lowerBound <= group.last.addingSaturating(gap) && span.upperBound > group.first
    }

    /// Step 3: the group a span of typing alone makes, at the last click before it.
    private func typingGroup(_ span: Range<Int64>, _ found: ActivityExtraction) -> Group? {
        let clicks = found.activity.clicks
        let next = Self.partition(clicks.count) { clicks[$0].output <= span.lowerBound }
        guard next > 0 else { return nil }
        let click = clicks[next - 1], point = found.clickPoints[next - 1]
        guard span.lowerBound - click.output <= AutoZoomPlanner.typingClickWindow else { return nil }
        let samples = found.samples
        var index = Self.partition(samples.count) { samples[$0].output <= click.output }
        while index < samples.count, samples[index].output <= span.lowerBound {
            if distance(samples[index].point, point) > AutoZoomPlanner.typingClickDistance { return nil }
            index += 1
        }
        return Group(first: span.lowerBound, last: span.lowerBound, box: Self.box(at: click.point), host: click.host, held: span.upperBound)
    }

    /// Steps 4 and 6: the block of each group, without those too shallow or empty.
    func blocks(of groups: [Group]) -> [Block] {
        groups.compactMap { group in
            let start = max(group.first.subtractingSaturating(leadIn), 0)
            let end = min(
                max(max(group.last, group.held).addingSaturating(leadOut), start.addingSaturating(AutoZoomPlanner.minimumDuration)),
                timeMap.duration)
            let depth = min(settings.depth, Self.fittingDepth(group.box, stage: stage.stageSize))
            guard depth >= AutoZoomPlanner.minimumDepth, start < end else { return nil }
            return Block(start: start, end: end, first: group.first, last: group.last, box: group.box, host: group.host, depth: depth)
        }
    }

    /// Step 5: neighbours merged or meeting at their midpoint.
    func neighboursSettled(_ blocks: [Block]) -> [Block] {
        var settled: [Block] = []
        for var block in blocks {
            guard var previous = settled.last, block.start - previous.end < AutoZoomPlanner.neighbourGap else {
                settled.append(block)
                continue
            }
            let box = Self.union(previous.box, block.box)
            if fits(box) {
                previous.end = max(previous.end, block.end)
                previous.last = max(previous.last, block.last)
                previous.box = box
                previous.depth = min(settings.depth, Self.fittingDepth(box, stage: stage.stageSize))
                settled[settled.count - 1] = previous
            } else {
                let middle = previous.last + (block.first - previous.last) / 2
                previous.end = middle
                block.start = middle
                settled[settled.count - 1] = previous
                settled.append(block)
            }
        }
        return settled.filter { $0.start < $0.end }
    }

    /// The source ranges `[start, end)` of `take` with their output ranges, without those cut whole or lasting 0 ns.
    func placed(_ ranges: [(start: HostTime, end: HostTime)], take: String) -> [Placed] {
        ranges.compactMap { range in
            guard range.start < range.end, let output = timeMap.outputRange(ofSource: range.start..<range.end, take: take),
                !output.isEmpty
            else { return nil }
            return Placed(start: range.start, end: range.end, output: output)
        }
    }

    /// Step 8: what is left of `range` free of `taken`, in order; `range` itself when nothing takes any of it, and
    /// otherwise only the parts that last at least `minimumFreeDuration`.
    func free(_ range: Range<Int64>, from taken: [Range<Int64>]) -> [Range<Int64>] {
        var parts = [range]
        var overlapped = false
        for other in taken where other.overlaps(range) {
            overlapped = true
            parts = parts.flatMap { part -> [Range<Int64>] in
                guard part.overlaps(other) else { return [part] }
                return [part.lowerBound..<max(part.lowerBound, other.lowerBound), min(part.upperBound, other.upperBound)..<part.upperBound]
                    .filter { !$0.isEmpty }
            }
        }
        return overlapped ? parts.filter { $0.upperBound - $0.lowerBound >= AutoZoomPlanner.minimumFreeDuration } : parts
    }

    /// Step 8: whether `range` and one of the `suppressed` ranges overlap by half of that range or more, or by half of
    /// `range` or more.
    func isSuppressed(_ range: Range<Int64>, by suppressed: [Range<Int64>]) -> Bool {
        suppressed.contains { other in
            let overlap = range.clamped(to: other)
            let covered = overlap.upperBound - overlap.lowerBound
            /// Whether `covered` is half of `whole` or more.
            func half(_ whole: Range<Int64>) -> Bool { covered >= whole.upperBound - whole.lowerBound - covered }
            return covered > 0 && (half(other) || half(range))
        }
    }

    /// Steps 6, 7 and 9: the zoom regions of `parts` (each a block, or a part of it left free), in the source, none
    /// starting inside the user's blocks `users` that come before it in output time.
    func regions(of parts: [(block: Block, output: Range<Int64>)], beside users: [Placed], take: String) -> [ZoomRegion] {
        parts.compactMap { part in
            guard var range = source(of: part.output, take: take) else { return nil }
            for user in users where user.output.upperBound <= part.output.lowerBound { range.start = max(range.start, user.end) }
            guard range.start < range.end else { return nil }
            let block = part.block
            return ZoomRegion(
                id: AutoZoomPlanner.regionID(take: take, start: range.start, end: range.end), take: take, start: range.start,
                end: range.end, origin: .auto, depth: block.depth == settings.depth ? nil : block.depth, focus: focus(of: block),
                instant: false)
        }
        .sorted { ($0.start, $0.end) < ($1.start, $1.end) }
    }

    /// Step 9: the source range of `output` of `take` (decision 16, with its end never past the source shown at the
    /// end of `output` in the same clip); `nil` if an end is not of `take`'s clips.
    private func source(of output: Range<Int64>, take: String) -> (start: HostTime, end: HostTime)? {
        guard let first = timeMap.source(atOutput: output.lowerBound), let last = timeMap.source(atOutput: output.upperBound - 1),
            sequence[first.clip].take == take, sequence[last.clip].take == take
        else { return nil }
        var end = HostTime(nanoseconds: last.source.nanoseconds + 1)
        if output.upperBound < timeMap.duration, let next = timeMap.source(atOutput: output.upperBound), next.clip == last.clip {
            end = min(end, next.source)
        }
        guard first.source < end else { return nil }
        return (first.source, end)
    }

    /// Step 7.
    private func focus(of block: Block) -> ZoomFocus {
        guard !settings.follow else { return .follow }
        let center = SIMD2(block.box.x + block.box.width / 2, block.box.y + block.box.height / 2)
        guard let screen = stage.screenRect(at: block.host), screen.width > 0, screen.height > 0 else { return .fixed(x: 0.5, y: 0.5) }
        return .fixed(x: (center.x - screen.x) / screen.width, y: (center.y - screen.y) / screen.height)
    }

    /// Whether `box` fits in the crop of `settings.depth` with its margin on each side.
    private func fits(_ box: Rect) -> Bool {
        let room = stage.stageSize * ((1 - 2 * AutoZoomPlanner.margin) / settings.depth)
        return box.width <= room.x && box.height <= room.y
    }

    /// The deepest zoom whose crop of the stage of `stage` fits `box` with its margin on each side (infinite for a
    /// point).
    private static func fittingDepth(_ box: Rect, stage: SIMD2<Double>) -> Double {
        let room = stage * (1 - 2 * AutoZoomPlanner.margin)
        return min(room.x / box.width, room.y / box.height)
    }

    private static func box(at point: SIMD2<Double>) -> Rect {
        Rect(x: point.x, y: point.y, width: 0, height: 0)
    }

    private static func union(_ a: Rect, _ b: Rect) -> Rect {
        let x = min(a.x, b.x), y = min(a.y, b.y)
        return Rect(x: x, y: y, width: max(a.x + a.width, b.x + b.width) - x, height: max(a.y + a.height, b.y + b.height) - y)
    }

    /// The first index in `0..<count` for which `isBefore` is false, given that it is true for a prefix and false after.
    private static func partition(_ count: Int, _ isBefore: (Int) -> Bool) -> Int {
        var (low, high) = (0, count)
        while low < high {
            let middle = low + (high - low) / 2
            if isBefore(middle) { low = middle + 1 } else { high = middle }
        }
        return low
    }
}
