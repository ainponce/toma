// SPDX-License-Identifier: GPL-3.0-or-later
import ProjectFormat

/// A track of the editor's timeline (design §5.5).
public enum TimelineTrack: Equatable, Sendable {
    /// The output's time, the take's markers and the in and out marks.
    case ruler
    /// The clips of the sequence, with thumbnails of the screen.
    case video
    /// Which screen is shown when, with two or more screens.
    case screen
    /// The zoom blocks.
    case zoom
    /// The captions, with a transcript (phase 2; empty until the captions feature draws in it).
    case captions
    /// The privacy blocks, with any (phase 2; empty until the privacy feature draws in it).
    case privacy
    /// The camera's changes.
    case camera
    /// The waveform of audio track `id` (`TrackRecord.id`), of every take the sequence shows that recorded it.
    case audio(id: String)
    /// The annotations, with any (phase 3 design §5.6; empty until the annotations feature draws in it).
    case annotations
    /// The sound of the imported clips, with a clip of the sequence or an annotation that shows one (phase 3 design §7.2;
    /// empty until the audio feature draws in it).
    case importedAudio
    /// The music, with any (phase 3 design §7.2 and §7.4; empty until the audio feature draws in it).
    case music
}

/// One row of the timeline, top to bottom: its track and how tall it is, in points.
public struct TimelineRow: Equatable, Sendable {
    public var track: TimelineTrack
    public var height: Double

    public init(track: TimelineTrack, height: Double) {
        self.track = track
        self.height = height
    }
}

/// The geometry of the editor's timeline (design §5.5): which tracks a take shows and how tall they are, its scale
/// (points per second of output) and where an output time is drawn.
///
/// Left of the tracks are their headers, `headerWidth` wide; output time `τ` (nanoseconds) is drawn at
/// `headerWidth + τ / 10⁹ × scale − offset`, `offset` being how far the timeline is scrolled, in points. The scale goes
/// from the whole sequence in the tracks' width (`fitScale`) to 600 pt per second (10 pt per frame at 60 fps).
public struct TimelineLayout: Equatable, Sendable {
    /// The headers of the tracks, with their icon and name.
    public static let headerWidth = 88.0
    /// The closest the timeline zooms in.
    public static let maxPointsPerSecond = 600.0
    /// The ruler's height, which the design does not give. The Camera row is 32 pt since 1c (design §5.5: it holds the
    /// layout blocks as well as the bubble's changes).
    public static let rulerHeight = 24.0
    static let videoHeight = 56.0
    static let screenHeight = 24.0
    static let zoomHeight = 28.0
    static let captionsHeight = 28.0
    static let privacyHeight = 28.0
    static let cameraHeight = 32.0
    static let audioHeight = 36.0
    /// The rows of phase 3 (plan decision 14).
    public static let annotationsHeight = 28.0
    public static let importedAudioHeight = 36.0
    public static let musicHeight = 36.0

    /// Top to bottom: the ruler, Video, Captions (with a transcript), Annotations (with annotations), Screen (with a take
    /// of two or more screen tracks that recorded something), Zoom, Privacy (with privacy blocks), Camera (with a camera
    /// that recorded something), one row for each audio track that recorded something, the microphones before the system
    /// audio and the system audio before an iPhone's or iPad's sound, each in the takes' order, then Imported Clips (with a
    /// clip of the sequence or an annotation that shows an imported video) and Music (with music).
    public var tracks: [TimelineRow]

    /// The tracks of `take`, the take of `document`'s sequence: `init(takes: [take], document:)`.
    public init(take: TakeRecord, document: EditDocument) {
        self.init(takes: [take], document: document)
    }

    /// The tracks of `takes`, those `document`'s sequence shows (phase 3 design §9), in the order it first shows them.
    /// The audio rows are their tracks' union by id: a track of one id is one row, whichever takes recorded it, where its
    /// kind and the first take that has it put it. They depend on the takes and on what the document has: what the
    /// document does with them is drawn in them. With one take and nothing of phase 3, the rows of phase 2.
    public init(takes: [TakeRecord], document: EditDocument) {
        var recorded: [TrackRecord] = []
        var ids: Set<String> = []
        for take in takes {
            for track in take.tracks where !track.segments.isEmpty && ids.insert(track.id).inserted { recorded.append(track) }
        }
        let twoScreens = takes.contains { $0.tracks.filter { !$0.segments.isEmpty && $0.kind.isScreen }.count >= 2 }
        var tracks = [TimelineRow(track: .ruler, height: Self.rulerHeight), TimelineRow(track: .video, height: Self.videoHeight)]
        if document.transcript != nil { tracks.append(TimelineRow(track: .captions, height: Self.captionsHeight)) }
        if !document.annotations.items.isEmpty { tracks.append(TimelineRow(track: .annotations, height: Self.annotationsHeight)) }
        if twoScreens { tracks.append(TimelineRow(track: .screen, height: Self.screenHeight)) }
        tracks.append(TimelineRow(track: .zoom, height: Self.zoomHeight))
        if !document.privacy.blocks.isEmpty { tracks.append(TimelineRow(track: .privacy, height: Self.privacyHeight)) }
        if recorded.contains(where: { $0.kind == .camera }) { tracks.append(TimelineRow(track: .camera, height: Self.cameraHeight)) }
        for kind in [TrackKind.microphone, .systemAudio, .deviceAudio] {
            tracks += recorded.filter { $0.kind == kind }.map { TimelineRow(track: .audio(id: $0.id), height: Self.audioHeight) }
        }
        if Self.hasImportedSound(document) { tracks.append(TimelineRow(track: .importedAudio, height: Self.importedAudioHeight)) }
        if !document.music.items.isEmpty { tracks.append(TimelineRow(track: .music, height: Self.musicHeight)) }
        self.tracks = tracks
    }

    /// Whether `document` shows an imported video, whose sound the Imported Clips row holds: a clip of the sequence
    /// (`ClipContent.media`) or an annotation (`AnnotationKind.clip`).
    private static func hasImportedSound(_ document: EditDocument) -> Bool {
        document.sequence.contains { if case .media? = $0.content { true } else { false } }
            || document.annotations.items.contains { if case .clip = $0.kind { true } else { false } }
    }

    /// The scale that shows `duration` seconds of output in `width` points (the tracks' width, without the headers),
    /// and never more than `maxPointsPerSecond`: that, if there is nothing to fit or no width to fit it in.
    public static func fitScale(duration: Double, width: Double) -> Double {
        guard duration > 0, width > 0, duration.isFinite, width.isFinite else { return maxPointsPerSecond }
        return min(width / duration, maxPointsPerSecond)
    }

    /// `s` within the scales the timeline allows: from `fitScale(duration:width:)` to `maxPointsPerSecond`. A scale that is
    /// not a number is the fitted one.
    public static func clampScale(_ s: Double, duration: Double, width: Double) -> Double {
        let fit = fitScale(duration: duration, width: width)
        guard !s.isNaN else { return fit }
        return min(max(s, fit), maxPointsPerSecond)
    }

    /// Where output time `ofOutput` (nanoseconds) is drawn: `headerWidth + τ / 10⁹ × scale − offset` points from the
    /// timeline's left edge. `τ × scale` is worked out before the division, so a time of whole milliseconds at a whole
    /// scale is drawn where its decimal value says (1 234 000 000 ns at 100 pt/s is 123.4 pt).
    public func x(ofOutput τ: Int64, scale: Double, offset: Double) -> Double {
        Self.headerWidth + Double(τ) * scale / 1e9 - offset
    }

    /// The output time drawn at `atX`, the inverse of `x(ofOutput:scale:offset:)`, rounded to the nanosecond, so
    /// `output(atX: x(ofOutput: τ))` is `τ` for any output up to a day long at any scale of the timeline. It is not
    /// clamped to the output: left of its start it is negative. 0 for a point that is not a number.
    public func output(atX x: Double, scale: Double, offset: Double) -> Int64 {
        let τ = ((x - Self.headerWidth + offset) * 1e9 / scale).rounded()
        guard τ.isFinite else { return 0 }
        // `Double(Int64.max)` is 2⁶³, one past it.
        if τ >= Double(Int64.max) { return .max }
        if τ <= Double(Int64.min) { return .min }
        return Int64(τ)
    }

    /// The output time (nanoseconds) at the same place in the timeline at `scale` scrolled by `offset` and fitted to the
    /// tracks' `width` (`fitScale`, scrolled by 0), for `duration` seconds of output: scaling around it, ⇧Z goes from the
    /// view there is to the fitted one without a jump. At area x = τ* × fit both times, so τ* = offset / (scale − fit)
    /// seconds, never past the end; 0 when the scale is the fitted one or closer than it can be.
    public static func fitAnchor(scale: Double, offset: Double, duration: Double, width: Double) -> Int64 {
        let fit = fitScale(duration: duration, width: width)
        guard scale > fit, offset > 0, scale.isFinite, offset.isFinite else { return 0 }
        let seconds = min(offset / (scale - fit), max(duration, 0))
        return Int64((seconds * 1e9).rounded())
    }

    /// A thumbnail of the Video track (design §5.5): one of the tiles of a clip, each from the clip's start a power of
    /// two of nanoseconds of output apart.
    public struct ThumbnailTile: Equatable, Sendable {
        /// The clip's index in the sequence, and the tile's number in the clip (from 0).
        public var clip: Int
        public var index: Int
        /// Where the tile is in the output, cut at the clip's end.
        public var output: Int64
        public var end: Int64
        /// The source instant at its left edge, whose frame it shows.
        public var source: HostTime

        public init(clip: Int, index: Int, output: Int64, end: Int64, source: HostTime) {
            self.clip = clip
            self.index = index
            self.output = output
            self.end = end
            self.source = source
        }
    }

    /// The thumbnail tiles of `sequence` (its time map, `map`) in the output range `visible`, at `scale`, for
    /// thumbnails `tileWidth` points wide: each clip's own grid, from its output start, a step apart that is the power of
    /// two of nanoseconds whose width is from half `tileWidth` to `tileWidth`. A tile shows the source instant at its
    /// left edge, in its own clip, and ends at the clip's end: so a tile keeps its frame while the scale changes within
    /// a power of two (and half of them across one), and while an edit moves its clip; a cut ahead changes nothing after
    /// it. A tile less than `minimumWidth` points wide (a clip narrower than that, or its last piece) has none: a sliver
    /// of a thumbnail shows nothing.
    public static func thumbnailTiles(
        sequence: [Clip], map: TimeMap, visible: Range<Int64>, scale: Double, tileWidth: Double, minimumWidth: Double
    ) -> [ThumbnailTile] {
        let period = tileWidth / scale * 1e9
        guard scale > 0, period.isFinite, period >= 1, period < 0x1p62, sequence.count == map.clipOutputStarts.count
        else { return [] }
        // The highest power of two at or under the period.
        let step = Int64(1) << Int64(63 - Int64(period).leadingZeroBitCount)
        // The last clip that starts at or before the range: the clips are in output order.
        var (low, high) = (0, sequence.count)
        while low < high {
            let middle = low + (high - low) / 2
            if map.clipOutputStarts[middle] <= visible.lowerBound { low = middle + 1 } else { high = middle }
        }
        var tiles: [ThumbnailTile] = []
        for k in max(low - 1, 0)..<sequence.count {
            let start = map.clipOutputStarts[k], clip = sequence[k]
            guard start < visible.upperBound else { break }
            let end = start + TimeMap.outputDuration(of: clip)
            guard end > visible.lowerBound, clip.start < clip.end else { continue }
            let speed = ClipSpeed.clamped(clip.speed)
            var index = max(visible.lowerBound - start, 0) / step
            while start + index * step < min(end, visible.upperBound) {
                let output = start + index * step, tileEnd = min(output + step, end)
                if Double(tileEnd - output) * scale / 1e9 >= minimumWidth {
                    let into = UInt64((Double(index * step) * speed).rounded())
                    let source = min(clip.start.nanoseconds + into, clip.end.nanoseconds - 1)
                    tiles.append(ThumbnailTile(
                        clip: k, index: Int(index), output: output, end: tileEnd, source: HostTime(nanoseconds: source)))
                }
                index += 1
            }
        }
        return tiles
    }

    /// Where the timeline scrolls to while playing, so the playhead stays in sight (design §5.5): page by page. `nil`
    /// while the playhead, at `playheadX` (from `x(ofOutput:scale:offset:)`), is within the tracks' area, `width` points
    /// from `headerWidth` on; once it reaches the area's right edge, the next page, `offset + width` (as many pages as
    /// it went past, after a jump). Out by the left (playing again from the start), the page it is on, never before 0.
    public static func autoscrollOffset(playheadX: Double, offset: Double, width: Double) -> Double? {
        guard width > 0, playheadX.isFinite, offset.isFinite else { return nil }
        let pages = ((playheadX - headerWidth) / width).rounded(.down)
        guard pages != 0 else { return nil }
        return max(offset + pages * width, 0)
    }
}
