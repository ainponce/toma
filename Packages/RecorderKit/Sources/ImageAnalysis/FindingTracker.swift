// SPDX-License-Identifier: GPL-3.0-or-later
import ProjectFormat

/// Something sensitive seen in one sample (`ScanSample`): what it is, its text and where it is. Not `Codable`: the text
/// only ever lives in memory, while the scan runs.
public struct FrameObservation: Equatable, Sendable {
    public var kind: SensitiveKind
    /// The text found, which tells the same one apart in the next samples; `nil` for a face.
    public var text: String?
    /// Where it is, in fractions of the screen's content (`ScanSample.crop`), as a block's rect.
    public var rect: NormalizedRect

    public init(kind: SensitiveKind, text: String?, rect: NormalizedRect) {
        self.kind = kind
        self.text = text
        self.rect = rect
    }
}

/// One thing the scan found in a take, over the source times `[start, end)`, where `keys` say: what the findings sheet
/// lists and the cache keeps, with the text masked (`SensitiveText.masked`), never whole.
public struct PrivacyFinding: Codable, Equatable, Sendable {
    public var kind: SensitiveKind
    public var masked: String
    public var take: String
    public var start: HostTime
    /// Excluded.
    public var end: HostTime
    /// Where it is, in fractions of the screen's content, in time order: a block's keys.
    public var keys: [RectKey]

    public init(kind: SensitiveKind, masked: String, take: String, start: HostTime, end: HostTime, keys: [RectKey]) {
        self.kind = kind
        self.masked = masked
        self.take = take
        self.start = start
        self.end = end
        self.keys = keys
    }

    /// The block that hides it (design §7.2, "Desenfocar N"): a blur at 0.6 over its span, with its keys and its kind's
    /// origin, its rect the first key's (all of the content for a finding without keys, which the scan never makes).
    public func block(id: String) -> PrivacyBlock {
        PrivacyBlock(
            id: id, take: take, start: start, end: end, effect: .blur, strength: 0.6, rect: keys.first?.rect ?? .unit,
            keys: keys, origin: kind.origin)
    }
}

/// `sensitiveScan-1`'s tracking (design §7.2): what the samples of a take saw, joined into findings.
///
/// - What two samples at most `joinGap` apart saw is one finding when it is of the same kind and either its rects
///   overlap with an IoU of `minimumIoU` or more, or its text is one the finding had (a scrolled line keeps its text,
///   however far it went). A finding takes at most one observation of a sample and an observation joins at most one
///   finding: the same text first, then the larger IoU, then the nearer in time. One sample missed (Vision does miss
///   one now and then) does not split a finding; a longer gap does.
/// - Its span goes from its first sample − `widen` to its last + `widen`, within the span asked for: at 4 samples a
///   second, that is every instant from where it was last not seen to where it was next not seen.
/// - Each rect grows by `grow` of its height on each side (in fractions of the content, both ways), cut to the content.
/// - One key per sample, its rect covering also the places of the samples before and after it: whatever the text did
///   between two samples (a scroll that slows down, a window coming up with the same address elsewhere), the block
///   hides both places all along. Before its first sample and after its last one, it also covers where the text would
///   have been if it had gone on moving as it did between its first (last) two samples, at most as far again: a line
///   scrolled into view was moving before it was first seen. Of a run of keys with the same rect only the first and the
///   last are kept: the rect between them is that one either way.
///
/// Samples are added in time order, each once; a second call at the same instant adds to that instant (a crossfade's
/// screen being left), and an earlier one starts findings of its own.
public struct FindingTracker: Sendable {
    public static let joinGap: Int64 = 500_000_000
    public static let minimumIoU = 0.3
    public static let widen: Int64 = 250_000_000
    public static let grow = 0.2

    private struct Sample: Sendable {
        var t: HostTime
        var rect: NormalizedRect
    }

    /// A finding while it is being followed.
    private struct Track: Sendable {
        var kind: SensitiveKind
        /// The first text seen, for the mask.
        var text: String?
        var texts: Set<String>
        var samples: [Sample]
    }

    private let take: String
    private var tracks: [Track] = []
    /// The tracks a later sample can still join: their last sample is at most `joinGap` before the last instant added.
    private var open: [Int] = []

    public init(take: String) {
        self.take = take
    }

    /// Adds what the sample at source instant `t` saw. Observations whose rect is not finite or has nothing inside the
    /// content are left out.
    public mutating func add(_ observations: [FrameObservation], at t: HostTime) {
        open.removeAll { tracks[$0].samples[tracks[$0].samples.count - 1].t.nanoseconds &+ UInt64(Self.joinGap) < t.nanoseconds }
        let usable: [(index: Int, observation: FrameObservation)] = observations.enumerated().compactMap { index, observation in
            guard let rect = Self.inContent(observation.rect) else { return nil }
            var observation = observation
            observation.rect = rect
            return (index, observation)
        }

        struct Pair {
            var track: Int
            var observation: Int
            var sameText: Bool
            var iou: Double
            var gap: UInt64
        }
        var pairs: [Pair] = []
        for track in open {
            let last = tracks[track].samples[tracks[track].samples.count - 1]
            guard last.t < t else { continue }
            let gap = t.nanoseconds - last.t.nanoseconds
            guard gap <= UInt64(Self.joinGap) else { continue }
            for (k, candidate) in usable.enumerated() where candidate.observation.kind == tracks[track].kind {
                let sameText = candidate.observation.text.map { tracks[track].texts.contains($0) } ?? false
                let iou = Self.iou(last.rect, candidate.observation.rect)
                guard sameText || iou >= Self.minimumIoU else { continue }
                pairs.append(Pair(track: track, observation: k, sameText: sameText, iou: iou, gap: gap))
            }
        }
        pairs.sort {
            if $0.sameText != $1.sameText { return $0.sameText }
            if $0.iou != $1.iou { return $0.iou > $1.iou }
            return ($0.gap, $0.track, $0.observation) < ($1.gap, $1.track, $1.observation)
        }
        var joined = [Int?](repeating: nil, count: usable.count)
        var taken = Set<Int>()
        for pair in pairs where joined[pair.observation] == nil && !taken.contains(pair.track) {
            joined[pair.observation] = pair.track
            taken.insert(pair.track)
        }
        for (k, candidate) in usable.enumerated() {
            let observation = candidate.observation
            let sample = Sample(t: t, rect: observation.rect)
            if let track = joined[k] {
                tracks[track].samples.append(sample)
                if let text = observation.text {
                    tracks[track].texts.insert(text)
                    if tracks[track].text == nil { tracks[track].text = text }
                }
            } else {
                tracks.append(Track(
                    kind: observation.kind, text: observation.text, texts: Set([observation.text].compactMap { $0 }),
                    samples: [sample]))
                open.append(tracks.count - 1)
            }
        }
    }

    /// The findings of the samples within `span` (the take's, `ScanSampling.span`), by start.
    public func findings(within span: Range<HostTime>) -> [PrivacyFinding] {
        tracks.enumerated()
            .compactMap { index, track in finding(of: track, within: span).map { (index, $0) } }
            .sorted { ($0.1.start, $0.0) < ($1.1.start, $1.0) }
            .map(\.1)
    }

    private func finding(of track: Track, within span: Range<HostTime>) -> PrivacyFinding? {
        let samples = track.samples.filter { span.contains($0.t) }.sorted { $0.t < $1.t }
        guard let first = samples.first, let last = samples.last else { return nil }
        let widen = UInt64(Self.widen)
        let start = max(HostTime(nanoseconds: first.t.nanoseconds - min(widen, first.t.nanoseconds)), span.lowerBound)
        let end = min(HostTime(nanoseconds: last.t.nanoseconds &+ widen), span.upperBound)

        let grown = samples.map { Self.grown($0.rect) }
        // Where it would have been at `start` and at `end` moving on as between its two first (last) samples.
        var before: NormalizedRect?
        var after: NormalizedRect?
        if samples.count >= 2 {
            before = Self.movedOn(grown[0], from: samples[1], to: samples[0], until: start)
            let n = samples.count
            after = Self.movedOn(grown[n - 1], from: samples[n - 2], to: samples[n - 1], until: end)
        }
        var keys: [RectKey] = samples.indices.map { i in
            let neighbours = [i > 0 ? grown[i - 1] : before, grown[i], i + 1 < grown.count ? grown[i + 1] : after]
            return RectKey(t: samples[i].t, rect: Self.bounds(of: neighbours.compactMap { $0 }))
        }
        // Of a run of keys with the same rect, the first and the last.
        keys = keys.indices.compactMap { i in
            let inside = i > 0 && i + 1 < keys.count && keys[i - 1].rect == keys[i].rect && keys[i + 1].rect == keys[i].rect
            return inside ? nil : keys[i]
        }
        return PrivacyFinding(
            kind: track.kind, masked: SensitiveText.masked(Substring(track.text ?? ""), kind: track.kind), take: take,
            start: start, end: end, keys: keys)
    }

    // MARK: - Rects

    /// `rect`'s part inside the content (0…1 both ways); `nil` when it is not finite or has nothing inside.
    private static func inContent(_ rect: NormalizedRect) -> NormalizedRect? {
        guard [rect.x, rect.y, rect.width, rect.height].allSatisfy(\.isFinite), rect.width > 0, rect.height > 0 else { return nil }
        let (x0, y0) = (max(rect.x, 0), max(rect.y, 0))
        let (x1, y1) = (min(rect.x + rect.width, 1), min(rect.y + rect.height, 1))
        guard x1 > x0, y1 > y0 else { return nil }
        return NormalizedRect(x: x0, y: y0, width: x1 - x0, height: y1 - y0)
    }

    /// `rect` grown by `grow` of its height on each side, cut to the content. Never `nil` for a rect inside it.
    private static func grown(_ rect: NormalizedRect) -> NormalizedRect {
        let margin = grow * rect.height
        return inContent(NormalizedRect(
            x: rect.x - margin, y: rect.y - margin, width: rect.width + 2 * margin, height: rect.height + 2 * margin)) ?? rect
    }

    /// `rect` (grown at sample `to`) moved on from `to` to instant `until` at the speed its centre went from `from` to
    /// `to`, at most as far as it went between them; cut to the content (`nil` when that leaves nothing).
    private static func movedOn(_ rect: NormalizedRect, from: Sample, to: Sample, until: HostTime) -> NormalizedRect? {
        let between = abs(Double(to.t.nanoseconds) - Double(from.t.nanoseconds))
        guard between > 0 else { return nil }
        let ratio = min(1, abs(Double(until.nanoseconds) - Double(to.t.nanoseconds)) / between)
        let dx = ((to.rect.x - from.rect.x) + (to.rect.width - from.rect.width) / 2) * ratio
        let dy = ((to.rect.y - from.rect.y) + (to.rect.height - from.rect.height) / 2) * ratio
        // Still: the very rect, so that a run of still keys is one.
        guard dx != 0 || dy != 0 else { return rect }
        return inContent(NormalizedRect(x: rect.x + dx, y: rect.y + dy, width: rect.width, height: rect.height))
    }

    /// The smallest rect holding all of `rects` (at least one): the very rect when they are all the same.
    private static func bounds(of rects: [NormalizedRect]) -> NormalizedRect {
        if let first = rects.first, rects.allSatisfy({ $0 == first }) { return first }
        let x0 = rects.map(\.x).min() ?? 0, y0 = rects.map(\.y).min() ?? 0
        let x1 = rects.map { $0.x + $0.width }.max() ?? 1, y1 = rects.map { $0.y + $0.height }.max() ?? 1
        return NormalizedRect(x: x0, y: y0, width: x1 - x0, height: y1 - y0)
    }

    /// Intersection over union of two rects with positive sizes.
    static func iou(_ a: NormalizedRect, _ b: NormalizedRect) -> Double {
        let width = min(a.x + a.width, b.x + b.width) - max(a.x, b.x)
        let height = min(a.y + a.height, b.y + b.height) - max(a.y, b.y)
        guard width > 0, height > 0 else { return 0 }
        let intersection = width * height
        return intersection / (a.width * a.height + b.width * b.height - intersection)
    }
}
