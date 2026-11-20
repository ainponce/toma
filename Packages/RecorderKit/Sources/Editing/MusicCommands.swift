// SPDX-License-Identifier: GPL-3.0-or-later
import ProjectFormat

/// The commands of the Music track and of the Music section of the Audio tab (phase 3 design §7.4 and §7.5, plan decisions
/// 7, 15 and 17), as pure functions of the document. Each one gives the step that does it (`EditStep`), or `nil` when there
/// is nothing to do.
///
/// - The music is anchored to the output: a cut never moves it. An item plays over `[start, end)`; what is past the end of
///   the output is not heard, and the output is the limit of every move and trim.
/// - Items never overlap: a new one goes in a free gap of at least `minimumDuration`, and a move or a trim stops at the item
///   next to it, at 0 and at the end of the output.
/// - Its fades are at most half the item each, its gain is held to `gains`, its `offset` is never negative, and its `source`
///   is always one a theme can play (`DocumentRules.isMusicSource`): nothing here writes anything else.
/// - The `target` of a step is the id of the item it acts on, or the pointer of the setting.
public enum MusicCommands {
    /// The shortest item made or trimmed by hand: 1 s.
    public static let minimumDuration: Int64 = 1_000_000_000
    /// The gains of an item, in dB: `GainRange.silence` (−∞) to +6.
    public static let gains: ClosedRange<Double> = GainRange.silence...6
    /// The amounts of the ducking, in dB.
    static let duckingAmounts: ClosedRange<Double> = -40...0
    /// The attacks of the ducking, in seconds.
    static let duckingAttacks: ClosedRange<Double> = 0.05...2
    /// The releases of the ducking, in seconds.
    static let duckingReleases: ClosedRange<Double> = 0.1...4

    /// A new item of `source` over `output`: offset 0, −14 dB, a fade in of 1 s and a fade out of 2 s (each held to half the
    /// item), looping.
    public static func newItem(id: String, source: String, output: Range<Int64>) -> MusicItem {
        let half = max(output.upperBound - output.lowerBound, 0) / 2
        return MusicItem(
            id: id, source: source, start: output.lowerBound, end: output.upperBound, offset: 0, gain: -14,
            fadeIn: min(1_000_000_000, half), fadeOut: min(2_000_000_000, half), loop: true)
    }

    /// Where a new item goes for the playhead at `atOutput`: all the output without items, otherwise the free gap that has
    /// the playhead (the end of the output counts for the last one), if it lasts `minimumDuration`; `nil` otherwise.
    public static func roomForNew(_ doc: EditDocument, atOutput: Int64, timeMap: TimeMap) -> Range<Int64>? {
        let duration = timeMap.duration
        guard duration > 0 else { return nil }
        var gaps: [Range<Int64>] = [0..<duration]
        for item in shownItems(doc, timeMap: timeMap) {
            gaps = gaps.flatMap { gap -> [Range<Int64>] in
                guard gap.overlaps(item.output) else { return [gap] }
                return [gap.lowerBound..<max(gap.lowerBound, item.output.lowerBound), min(gap.upperBound, item.output.upperBound)..<gap.upperBound]
                    .filter { !$0.isEmpty }
            }
        }
        let at = min(max(atOutput, 0), duration)
        return gaps.first { ($0.contains(at) || ($0.upperBound == duration && at == duration)) && $0.upperBound - $0.lowerBound >= minimumDuration }
    }

    /// An item of `source` in the room `roomForNew` gives, with the id `makeID("mu-")`. `nil` if there is no room, or
    /// `source` is not one a theme can play.
    public static func add(
        _ doc: EditDocument, source: String, atOutput: Int64, timeMap: TimeMap, makeID: (String) -> String
    ) -> EditStep? {
        guard DocumentRules.isMusicSource(source), let room = roomForNew(doc, atOutput: atOutput, timeMap: timeMap) else { return nil }
        var ids = Set(doc.music.items.map(\.id))
        let item = newItem(id: DocumentIDs.new("mu-", makeID, avoiding: &ids), source: source, output: room)
        var changes = DocumentChanges()
        changes.insert(item, into: .music, at: doc.music.items.firstIndex { $0.start > item.start } ?? doc.music.items.count)
        return changes.step(label: .musicAdd, target: item.id)
    }

    /// Edits item `id` with `edit`, then holds it: its id, start and end stay (`move` and `trim` change those), its gain is
    /// held to `gains`, its fades to 0 and half the item, its offset to 0 or more. `nil` if there is no such item, `edit` leaves
    /// it as it was, it gives a `source` a theme cannot play, or a gain that is not a number.
    public static func change(_ doc: EditDocument, id: String, _ edit: (inout MusicItem) -> Void) -> EditStep? {
        guard let k = doc.music.items.firstIndex(where: { $0.id == id }) else { return nil }
        let old = doc.music.items[k]
        var new = old
        edit(&new)
        guard DocumentRules.isMusicSource(new.source), !new.gain.isNaN else { return nil }
        (new.id, new.start, new.end) = (old.id, old.start, old.end)
        return replacing(doc, k, with: held(new), label: .musicChange)
    }

    /// Moves item `id` so it starts at `toOutputStart`, as long as it is: it stops at the items before and after it and at
    /// 0 and the end of the output; what it plays (`offset`) goes with it. `nil` if it stays where it is.
    public static func move(_ doc: EditDocument, id: String, toOutputStart: Int64, timeMap: TimeMap) -> EditStep? {
        guard let k = doc.music.items.firstIndex(where: { $0.id == id }) else { return nil }
        let old = doc.music.items[k]
        let room = room(around: k, doc, timeMap)
        let length = old.end - old.start
        let start = min(max(toOutputStart, room.lowerBound), max(room.upperBound - length, room.lowerBound))
        guard start != old.start else { return nil }
        var new = old
        (new.start, new.end) = (start, start + length)
        return replacing(doc, k, with: new, label: .musicMove)
    }

    /// Moves `edge` of item `id` to output instant `toOutput`: it stops at the item next to it, at 0 and at the end of the
    /// output, and leaves the item at least `minimumDuration` long (a shorter one only grows). The start keeps the music in
    /// its place (`offset` moves with it, and never goes before 0: the start does not go back past the music's own start);
    /// the fades are held to half the item. `nil` if the edge stays where it is.
    public static func trim(_ doc: EditDocument, id: String, edge: ClipEdge, toOutput: Int64, timeMap: TimeMap) -> EditStep? {
        guard let k = doc.music.items.firstIndex(where: { $0.id == id }) else { return nil }
        let old = doc.music.items[k]
        let room = room(around: k, doc, timeMap)
        var new = old
        switch edge {
        case .start:
            let latest = max(old.end - minimumDuration, old.start)
            let earliest = max(room.lowerBound, old.start - old.offset)
            let start = min(max(toOutput, min(earliest, old.start)), latest)
            guard start != old.start else { return nil }
            new.start = start
            new.offset = max(old.offset + (start - old.start), 0)
        case .end:
            let earliest = min(old.start + minimumDuration, old.end)
            let end = max(min(toOutput, max(room.upperBound, earliest)), earliest)
            guard end != old.end else { return nil }
            new.end = end
        }
        return replacing(doc, k, with: held(new), label: .musicTrim)
    }

    /// Slides what item `id` plays, without moving it: `offset`, never negative, and with `loop` and the length of the
    /// theme (`themeLength`, ns), its remainder. `nil` if it stays where it is.
    public static func slip(_ doc: EditDocument, id: String, offset: Int64, themeLength: Int64?) -> EditStep? {
        guard let k = doc.music.items.firstIndex(where: { $0.id == id }) else { return nil }
        var new = doc.music.items[k]
        var offset = max(offset, 0)
        if new.loop, let themeLength, themeLength > 0 { offset %= themeLength }
        new.offset = offset
        return replacing(doc, k, with: new, label: .musicMove)
    }

    /// Takes item `id` out. `nil` if there is no such item.
    public static func delete(_ doc: EditDocument, id: String) -> EditStep? {
        guard let k = doc.music.items.firstIndex(where: { $0.id == id }) else { return nil }
        var changes = DocumentChanges()
        changes.remove(doc.music.items[k], from: .music, at: k)
        return changes.step(label: .musicDelete, target: id)
    }

    /// The ducking as a whole, held: the amount to −40...0 dB, the attack to 0.05...2 s and the release to 0.1...4 s; a
    /// value that is not a number is the one of `Ducking.default`. One `set` of `/music/ducking`; `nil` if it is the one
    /// there is.
    public static func setDucking(_ doc: EditDocument, _ ducking: Ducking) -> EditStep? {
        func held(_ value: Double, _ range: ClosedRange<Double>, _ fallback: Double) -> Double {
            value.isNaN ? fallback : min(max(value, range.lowerBound), range.upperBound)
        }
        var new = ducking
        new.amount = held(ducking.amount, duckingAmounts, Ducking.default.amount)
        new.attack = held(ducking.attack, duckingAttacks, Ducking.default.attack)
        new.release = held(ducking.release, duckingReleases, Ducking.default.release)
        var changes = DocumentChanges()
        changes.set(["music", "ducking"], from: doc.music.ducking, to: new)
        return changes.step(label: .musicDucking, target: "/music/ducking")
    }

    /// The items as the output plays them, in the order of the document: the end is the item's or the end of the output,
    /// the first; one that starts at or after the end of the output, or lasts nothing, is not shown.
    public static func shownItems(_ doc: EditDocument, timeMap: TimeMap) -> [(id: String, output: Range<Int64>)] {
        doc.music.items.compactMap { item in
            let (lower, upper) = (max(item.start, 0), min(item.end, timeMap.duration))
            return lower < upper ? (item.id, lower..<upper) : nil
        }
    }

    // MARK: - Private

    /// Where item `k` can go: from the end of the item before it (or 0) to the start of the one after it (or the end of the
    /// output).
    private static func room(around k: Int, _ doc: EditDocument, _ map: TimeMap) -> Range<Int64> {
        let current = doc.music.items[k]
        var (lower, upper) = (Int64(0), map.duration)
        for (j, other) in doc.music.items.enumerated() where j != k {
            if other.end <= current.start { lower = max(lower, other.end) }
            if other.start >= current.end { upper = min(upper, other.start) }
        }
        return lower..<max(lower, upper)
    }

    /// `item` with its gain, fades and offset held.
    private static func held(_ item: MusicItem) -> MusicItem {
        var item = item
        item.gain = min(max(item.gain, gains.lowerBound), gains.upperBound)
        let half = max(item.end - item.start, 0) / 2
        item.fadeIn = min(max(item.fadeIn, 0), half)
        item.fadeOut = min(max(item.fadeOut, 0), half)
        item.offset = max(item.offset, 0)
        return item
    }

    private static func replacing(_ doc: EditDocument, _ k: Int, with new: MusicItem, label: EditLabel) -> EditStep? {
        var changes = DocumentChanges()
        changes.replace(doc.music.items[k], with: new, in: .music, id: new.id)
        return changes.step(label: label, target: new.id)
    }
}
