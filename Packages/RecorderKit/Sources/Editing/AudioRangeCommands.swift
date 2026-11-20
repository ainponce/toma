// SPDX-License-Identifier: GPL-3.0-or-later
import ProjectFormat

/// The commands of the volume stretches of an audio row and of the J and L cut (phase 3 design §7.2 and §7.3, plan
/// decisions 9, 10 and 13), as pure functions of the document. Each one gives the step that does it (`EditStep`), or `nil`
/// when there is nothing to do.
///
/// - A stretch is kept in the source of its take (`GainRange`, in `audio.tracks["<take>/<track>"].ranges`) and edited in
///   output time as the sound is heard: clip `k`'s sound plays over `[audioStarts[k], audioStarts[k + 1])` (the end of the
///   output for the last one), so a J or an L cut moves a stretch with the sound, not with the picture. Its start is the
///   source of its output start, its end the source of 1 ns before its output end, and 1 ns, but never past the source
///   heard at its output end in the same clip.
/// - A stretch over clips of two takes is one `GainRange` per take with the same id, each in its own take's collection, and
///   is edited as one. A cut inside it is closed (one range in the source, two shown).
/// - Stretches never overlap in a key: a new one cuts, splits or removes what it covers of the old ones; a trim stops at
///   the stretch next to it. Nothing here writes a gain outside `gains`.
/// - The `target` of a step is the id of the stretch or of the clip it acts on.
public enum AudioRangeCommands {
    /// The shortest stretch made or trimmed by hand: 100 ms of output.
    public static let minimumDuration: Int64 = 100_000_000
    /// The gains of a stretch, in dB: `GainRange.silence` (−∞) to +12.
    public static let gains: ClosedRange<Double> = GainRange.silence...12

    /// A stretch where the output shows it: one `GainRange` cut in two by a cut of the sequence is two of these, with its id.
    public struct ShownRange: Equatable, Sendable {
        public var id: String
        public var output: Range<Int64>
        public var gain: Double

        public init(id: String, output: Range<Int64>, gain: Double) {
            self.id = id
            self.output = output
            self.gain = gain
        }
    }

    // MARK: - The stretches

    /// The stretches of audio track `track` (every take's key `<take>/<track>`) where the output plays them, by output
    /// start and then id; one a cut hides whole shows nothing.
    public static func shownRanges(_ doc: EditDocument, track: String, timeMap: TimeMap) -> [ShownRange] {
        let placed = placements(doc, track: track, timeMap: timeMap)
        var result: [ShownRange] = []
        for id in Set(placed.map(\.id)) {
            let pieces = placed.filter { $0.id == id }.sorted { $0.output.lowerBound < $1.output.lowerBound }
            var merged: [ShownRange] = []
            for piece in pieces {
                // Touching pieces are not cut apart: only a gap is.
                if let last = merged.last, last.output.upperBound == piece.output.lowerBound {
                    merged[merged.count - 1].output = last.output.lowerBound..<piece.output.upperBound
                } else {
                    merged.append(ShownRange(id: id, output: piece.output, gain: piece.gain))
                }
            }
            result += merged
        }
        return result.sorted { ($0.output.lowerBound, $0.id) < ($1.output.lowerBound, $1.id) }
    }

    /// A stretch of `gain` dB (held to `gains`) over output range `forOutput` (clamped to the output) of audio track
    /// `track`, in each of `takes` (the takes the sequence shows that recorded it) the range shows: id `makeID("g-")`.
    /// It cuts the stretches it covers (`AudioRangeCommands` doc). A key the document lacks is made with one `set` of
    /// `/audio/tracks`, as `TrackCommands.setTrackGain` makes it. `nil` if less than `minimumDuration` of output is
    /// asked, if nothing of those takes is heard there, or the gain is not a number.
    public static func addRange(
        _ doc: EditDocument, track: String, takes: [String], forOutput: Range<Int64>, gain: Double, timeMap: TimeMap,
        makeID: (String) -> String
    ) -> EditStep? {
        guard !gain.isNaN else { return nil }
        let gain = min(max(gain, gains.lowerBound), gains.upperBound)
        let lower = max(forOutput.lowerBound, 0), upper = min(forOutput.upperBound, timeMap.duration)
        guard lower < upper, upper - lower >= minimumDuration else { return nil }
        let pieces = pieces(doc, in: lower..<upper, timeMap: timeMap).filter { takes.contains(doc.sequence[$0.clip].take) }
        var order: [String] = []
        var sources: [String: (start: HostTime, end: HostTime)] = [:]
        for piece in pieces {
            let take = doc.sequence[piece.clip].take
            guard let start = sourceStart(piece.clip, at: piece.output.lowerBound, timeMap),
                let end = sourceEnd(piece.clip, at: piece.output.upperBound, timeMap), start < end
            else { continue }
            if sources[take] == nil {
                order.append(take)
                sources[take] = (start, end)
            } else if let first = sources[take] {
                sources[take] = (first.start, max(first.end, end))
            }
        }
        guard !order.isEmpty else { return nil }

        var ids = Set(doc.audio.tracks.values.flatMap { $0.ranges.map(\.id) })
        let id = DocumentIDs.new("g-", makeID, avoiding: &ids)
        var tracks = doc.audio.tracks
        var keys: [String] = []
        for take in order {
            guard let source = sources[take] else { continue }
            let key = AudioPlan.key(take: take, track: track)
            keys.append(key)
            var held = doc.audio.trackGain(take: take, track: track, takes: order) ?? TrackGain(gain: 1, muted: false)
            if doc.audio.tracks[key] == nil { held.ranges = [] } else { held = doc.audio.tracks[key] ?? held }
            held.ranges = inserting(
                GainRange(id: id, take: take, start: source.start, end: source.end, gain: gain), into: held.ranges, makeID: makeID,
                avoiding: &ids)
            tracks[key] = held
        }
        var changes = DocumentChanges()
        guard keys.allSatisfy({ doc.audio.tracks[$0] != nil }) else {
            changes.set(["audio", "tracks"], from: doc.audio.tracks, to: tracks)
            return changes.step(label: .audioRange, target: id)
        }
        for key in keys {
            guard let old = doc.audio.tracks[key]?.ranges, let new = tracks[key]?.ranges else { continue }
            changes.edit(.gainRanges(track: key), from: old, to: new, id: \.id)
        }
        return changes.step(label: .audioRange, target: id)
    }

    /// Stretch `id` of `track` at `gain` dB (held to `gains`), in every take it has. `nil` if there is no such stretch, it
    /// has that gain already, or the gain is not a number.
    public static func setGain(_ doc: EditDocument, track: String, id: String, gain: Double) -> EditStep? {
        guard !gain.isNaN else { return nil }
        let gain = min(max(gain, gains.lowerBound), gains.upperBound)
        var changes = DocumentChanges()
        for (key, k) in locations(of: id, in: doc, track: track) {
            guard let old = doc.audio.tracks[key]?.ranges[k] else { continue }
            var new = old
            new.gain = gain
            changes.replace(old, with: new, in: .gainRanges(track: key), id: id)
        }
        return changes.step(label: .audioRange, target: id)
    }

    /// Moves `edge` of stretch `id` to output instant `toOutput`: it stops at the stretch next to it of the same take and
    /// at the ends of the output, and leaves the stretch at least `minimumDuration` long (a shorter one only grows). The
    /// other edge keeps its source instant. The first edge is of the first take it is heard in, the last of the last; an
    /// instant of another take is `nil`, and so is one that leaves it where it is, or a stretch nothing shows.
    public static func trim(
        _ doc: EditDocument, track: String, id: String, edge: ClipEdge, toOutput: Int64, timeMap: TimeMap
    ) -> EditStep? {
        let placed = placements(doc, track: track, timeMap: timeMap)
        let own = placed.filter { $0.id == id }.sorted { $0.output.lowerBound < $1.output.lowerBound }
        guard let first = own.first, let last = own.last else { return nil }
        let (lower, upper) = (first.output.lowerBound, own.map(\.output.upperBound).max() ?? last.output.upperBound)
        let others = placed.filter { $0.id != id }
        var (key, take) = (AudioPlan.key(take: first.take, track: track), first.take)
        var range: GainRange?
        switch edge {
        case .start:
            let floor = max(0, others.filter { $0.take == take && $0.output.upperBound <= lower }.map(\.output.upperBound).max() ?? 0)
            let latest = max(upper - minimumDuration, lower)
            let target = min(max(toOutput, floor), latest)
            guard target != lower, let k = clip(heardAt: target, take: take, doc, timeMap),
                var old = doc.audio.tracks[key]?.ranges.first(where: { $0.id == id }),
                let start = sourceStart(k, at: target, timeMap), start < old.end
            else { return nil }
            old.start = start
            range = old
        case .end:
            (key, take) = (AudioPlan.key(take: last.take, track: track), last.take)
            let ceiling = min(
                timeMap.duration, others.filter { $0.take == take && $0.output.lowerBound >= upper }.map(\.output.lowerBound).min() ?? timeMap.duration)
            let earliest = min(lower + minimumDuration, upper)
            let target = max(min(toOutput, ceiling), earliest)
            guard target != upper, target > 0, let k = clip(heardAt: target - 1, take: take, doc, timeMap),
                var old = doc.audio.tracks[key]?.ranges.first(where: { $0.id == id }),
                let end = sourceEnd(k, at: target, timeMap), end > old.start
            else { return nil }
            old.end = end
            range = old
        }
        guard let new = range, let old = doc.audio.tracks[key]?.ranges.first(where: { $0.id == id }) else { return nil }
        var changes = DocumentChanges()
        changes.replace(old, with: new, in: .gainRanges(track: key), id: id)
        return changes.step(label: .audioRange, target: id)
    }

    /// Takes stretch `id` of `track` out, in every take it has. `nil` if there is no such stretch.
    public static func delete(_ doc: EditDocument, track: String, id: String) -> EditStep? {
        var changes = DocumentChanges()
        for (key, k) in locations(of: id, in: doc, track: track).sorted(by: { ($0.key, $0.index) > ($1.key, $1.index) }) {
            guard let old = doc.audio.tracks[key]?.ranges[k] else { continue }
            changes.remove(old, from: .gainRanges(track: key), at: k)
        }
        return changes.step(label: .audioRange, target: id)
    }

    // MARK: - The cut of the sound

    /// The `audioShift`s clip `k` can have, in ns of output, with what there is of each take
    /// (`SequenceRules.audioShiftRange(of:at:takeBounds:)`); `0...0` for an index out of the sequence.
    public static func shiftLimits(_ doc: EditDocument, clip k: Int, takeBounds: [String: ClosedRange<HostTime>]) -> ClosedRange<Int64> {
        guard doc.sequence.indices.contains(k) else { return 0...0 }
        return SequenceRules.audioShiftRange(of: doc.sequence, at: k, takeBounds: takeBounds)
    }

    /// Moves the cut of the sound at the start of clip `k` to `shift` ns of output (negative a J cut, positive an L cut),
    /// held to `shiftLimits`. `nil` if the clip has no cut that moves (the first, one with content or next to one), or it
    /// is there already.
    public static func setAudioShift(
        _ doc: EditDocument, clip k: Int, to shift: Int64, takeBounds: [String: ClosedRange<HostTime>]
    ) -> EditStep? {
        guard doc.sequence.indices.contains(k) else { return nil }
        let limits = shiftLimits(doc, clip: k, takeBounds: takeBounds)
        guard limits != 0...0 || doc.sequence[k].audioShift != 0 else { return nil }
        let held = min(max(shift, limits.lowerBound), limits.upperBound)
        let old = doc.sequence[k]
        guard held != old.audioShift else { return nil }
        var new = old
        new.audioShift = held
        var changes = DocumentChanges()
        changes.replace(old, with: new, in: .sequence, id: old.id)
        return changes.step(label: .audioShift, target: old.id)
    }

    // MARK: - Private

    /// A stretch of the sound where the output plays it, in one take.
    private struct Placed {
        var id: String
        var take: String
        var output: Range<Int64>
        var gain: Double
    }

    /// Clip `clip`'s sound over `output` (inside its window).
    private struct Piece {
        var clip: Int
        var output: Range<Int64>
    }

    /// Where the sound of each clip plays: `[audioStarts[k], audioStarts[k + 1])`, to the end of the output for the last. A
    /// clip with content or without output has none.
    private static func windows(_ doc: EditDocument, _ map: TimeMap) -> [(clip: Int, window: Range<Int64>)] {
        var found: [(Int, Range<Int64>)] = []
        for k in doc.sequence.indices where doc.sequence[k].content == nil && TimeMap.outputDuration(of: doc.sequence[k]) > 0 {
            guard doc.sequence[k].start < doc.sequence[k].end, k < map.audioStarts.count else { continue }
            let lower = min(max(map.audioStarts[k], 0), map.duration)
            let upper = min(max(k + 1 < map.audioStarts.count ? map.audioStarts[k + 1] : map.duration, 0), map.duration)
            if lower < upper { found.append((k, lower..<upper)) }
        }
        return found
    }

    /// The parts of `output` each clip's sound plays, in order.
    private static func pieces(_ doc: EditDocument, in output: Range<Int64>, timeMap: TimeMap) -> [Piece] {
        windows(doc, timeMap).compactMap { k, window in
            let (lower, upper) = (max(window.lowerBound, output.lowerBound), min(window.upperBound, output.upperBound))
            return lower < upper ? Piece(clip: k, output: lower..<upper) : nil
        }
    }

    /// The clip of `take` whose sound plays output instant `τ`.
    private static func clip(heardAt τ: Int64, take: String, _ doc: EditDocument, _ map: TimeMap) -> Int? {
        windows(doc, map).first { doc.sequence[$0.clip].take == take && $0.window.contains(τ) }?.clip
    }

    /// The source instant of clip `k` heard at output instant `τ`; `nil` before the start of the take.
    private static func sourceStart(_ k: Int, at τ: Int64, _ map: TimeMap) -> HostTime? {
        let source = map.audioSource(ofClip: k, atOutput: τ)
        return source < 0 ? nil : HostTime(nanoseconds: UInt64(source))
    }

    /// The source end of a stretch of clip `k`'s sound that ends at output instant `upper`: the source of `upper − 1` and
    /// 1 ns, but never past the source heard at `upper` in the same clip.
    private static func sourceEnd(_ k: Int, at upper: Int64, _ map: TimeMap) -> HostTime? {
        let last = map.audioSource(ofClip: k, atOutput: upper - 1)
        guard last >= 0, last < Int64.max else { return nil }
        var end = last + 1
        if upper < map.duration, k + 1 >= map.audioStarts.count || upper < map.audioStarts[k + 1] {
            end = min(end, max(map.audioSource(ofClip: k, atOutput: upper), last))
        }
        return HostTime(nanoseconds: UInt64(end))
    }

    /// Every stretch of `track`, in every take's key, as the output plays it: one `Placed` per run of a clip's sound.
    private static func placements(_ doc: EditDocument, track: String, timeMap: TimeMap) -> [Placed] {
        let windows = windows(doc, timeMap)
        var found: [Placed] = []
        for (key, gain) in doc.audio.tracks.sorted(by: { $0.key < $1.key }) where key.hasSuffix("/" + track) {
            for range in gain.ranges where range.start < range.end {
                for (k, window) in windows where doc.sequence[k].take == range.take {
                    let clip = doc.sequence[k]
                    let lowest = timeMap.audioSource(ofClip: k, atOutput: window.lowerBound)
                    let highest = timeMap.audioSource(ofClip: k, atOutput: window.upperBound)
                    let lo = max(Int64(clamping: range.start.nanoseconds), lowest), hi = min(Int64(clamping: range.end.nanoseconds), highest)
                    guard lo < hi else { continue }
                    let start = Int64(clamping: clip.start.nanoseconds), speed = ClipSpeed.clamped(clip.speed)
                    let origin = timeMap.clipOutputStarts[k]
                    func output(_ x: Int64) -> Int64 {
                        let (offset, overflow) = x.subtractingReportingOverflow(start)
                        guard !overflow else { return x < start ? window.lowerBound : window.upperBound }
                        let rounded = (Double(offset) / speed).rounded()
                        let moved = rounded.isNaN ? 0 : Int64(min(max(rounded, -9e18), 9e18))
                        let (sum, added) = origin.addingReportingOverflow(moved)
                        return added ? window.upperBound : min(max(sum, window.lowerBound), window.upperBound)
                    }
                    let part = output(lo)..<output(hi)
                    if !part.isEmpty { found.append(Placed(id: range.id, take: range.take, output: part, gain: range.gain)) }
                }
            }
        }
        return found
    }

    /// The `(key, index)` of each stretch `id` of `track`.
    private static func locations(of id: String, in doc: EditDocument, track: String) -> [(key: String, index: Int)] {
        var found: [(String, Int)] = []
        for (key, gain) in doc.audio.tracks.sorted(by: { $0.key < $1.key }) where key.hasSuffix("/" + track) {
            for (k, range) in gain.ranges.enumerated() where range.id == id { found.append((key, k)) }
        }
        return found
    }

    /// `ranges` with `new` in it: what `new` covers of the others of its take goes (an old one that holds it is split in
    /// two, the second with a new id), and `new` goes before the first that starts after it.
    private static func inserting(
        _ new: GainRange, into ranges: [GainRange], makeID: (String) -> String, avoiding ids: inout Set<String>
    ) -> [GainRange] {
        var result: [GainRange] = []
        for old in ranges {
            guard old.take == new.take, old.start < new.end, old.end > new.start else {
                result.append(old)
                continue
            }
            var left = old, right = old
            let hasLeft = old.start < new.start, hasRight = old.end > new.end
            left.end = new.start
            right.start = new.end
            if hasLeft { result.append(left) }
            if hasRight {
                if hasLeft { right.id = DocumentIDs.new("g-", makeID, avoiding: &ids) }
                result.append(right)
            }
        }
        result.insert(new, at: result.firstIndex { $0.take == new.take && $0.start > new.start } ?? result.count)
        return result
    }
}
