// SPDX-License-Identifier: GPL-3.0-or-later

/// Which segments of the working take a save of the last N seconds keeps, and under which names (fases 4 y 5 design
/// §10.3, plan 5c decision 6).
///
/// The screen is the take's tracks of `TrackKind.isScreen`; its end, the latest end of their closed segments, and its
/// start, the earliest start. The cut is N seconds before the end, or the screen's start if less than N was recorded:
/// the document starts there (`Clip.start`). Of every track, the closed segments that end after the cut and start before
/// the end are kept, the one across the cut whole, so the events start at the first of them (up to a segment before the
/// cut) and stretching the clip back shows what its files hold. Open segments are left out.
public struct ReplayCut: Equatable, Sendable {
    /// A segment file to copy, both paths relative to their package's root: from the working package to the saved one.
    public struct FileCopy: Equatable, Sendable {
        public var from: String
        public var to: String

        public init(from: String, to: String) {
            self.from = from
            self.to = to
        }
    }

    /// Where the document starts.
    public var cut: HostTime
    /// The start of the first segment kept, of any track: where the saved events start.
    public var start: HostTime
    /// The end of the screen.
    public var end: HostTime
    /// The tracks kept, in the take's order, with their segments renumbered from 1 in `takes/<takeID>/` and `rotated`
    /// made `stopped` (it never leaves the working package, design §11); a track with no segment kept is left out.
    public var tracks: [TrackRecord]
    /// One per segment kept, in the order of `tracks`.
    public var files: [FileCopy]
    /// Track id → index in the working take → index in the saved one.
    public var renumbered: [String: [Int: Int]]

    public init(
        cut: HostTime, start: HostTime, end: HostTime, tracks: [TrackRecord], files: [FileCopy], renumbered: [String: [Int: Int]]
    ) {
        self.cut = cut
        self.start = start
        self.end = end
        self.tracks = tracks
        self.files = files
        self.renumbered = renumbered
    }

    /// The cut of the last `seconds` of `take` into a take `takeID`. Throws `noScreen` when no track of the screen has a
    /// closed segment.
    public static func make(take: TakeRecord, seconds: Int, takeID: String) throws(ReplayError) -> ReplayCut {
        let screen = take.tracks.filter(\.kind.isScreen).flatMap { $0.segments.filter(\.isClosed) }
        guard let screenStart = screen.map(\.startHostTime).min(), let end = screen.compactMap(\.endHostTime).max() else {
            throw .noScreen
        }
        let cut = max(end.adding(seconds: -Double(max(0, seconds))), screenStart)

        var tracks: [TrackRecord] = []
        var files: [FileCopy] = []
        var renumbered: [String: [Int: Int]] = [:]
        for track in take.tracks {
            let kept = track.segments
                .filter { segment in
                    guard let segmentEnd = segment.endHostTime, segment.isClosed else { return false }
                    return segmentEnd > cut && segment.startHostTime < end
                }
                .sorted { $0.startHostTime < $1.startHostTime }
            guard !kept.isEmpty else { continue }
            var saved = track
            saved.segments = kept.enumerated().map { offset, segment in
                var copy = segment
                copy.index = offset + 1
                copy.file = "takes/\(takeID)/\(track.id)/" + ProjectPackage.segmentFileName(index: copy.index)
                if copy.endReason == .rotated { copy.endReason = .stopped }
                return copy
            }
            for (old, new) in zip(kept, saved.segments) {
                files.append(FileCopy(from: old.file, to: new.file))
                renumbered[track.id, default: [:]][old.index] = new.index
            }
            tracks.append(saved)
        }
        // The screen ends after the cut, so it has a segment kept and `start` is never after the cut.
        let start = tracks.flatMap { $0.segments.map(\.startHostTime) }.min() ?? cut
        return ReplayCut(cut: cut, start: start, end: end, tracks: tracks, files: files, renumbered: renumbered)
    }
}

extension SegmentRecord {
    /// Whether the recorder closed it: it has its end and why.
    fileprivate var isClosed: Bool { endHostTime != nil && endReason != nil }
}
