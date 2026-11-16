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
    /// The camera's changes.
    case camera
    /// The waveform of audio track `id` of the take (`TrackRecord.id`).
    case audio(id: String)
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
    /// The ruler's height, which the design does not give: the timeline is 236 pt (§5.1), and with the track bar's
    /// 32 pt a take with a camera and two audio tracks fills it exactly.
    public static let rulerHeight = 24.0
    static let videoHeight = 56.0
    static let screenHeight = 24.0
    static let zoomHeight = 28.0
    static let cameraHeight = 24.0
    static let audioHeight = 36.0

    /// Top to bottom: the ruler, Video, Screen (with two or more screen tracks that recorded something), Zoom, Camera
    /// (with a camera that recorded something) and one row for each audio track that recorded something, the
    /// microphones before the system audio, each in the take's order.
    public var tracks: [TimelineRow]
    /// What the output lasts, in nanoseconds (`TimeMap.duration` of the document's sequence).
    public var duration: Int64

    /// The tracks of `take`, the take of `document`'s sequence, and the output of `document`.
    public init(take: TakeRecord, document: EditDocument) {
        let recorded = take.tracks.filter { !$0.segments.isEmpty }
        var tracks = [TimelineRow(track: .ruler, height: Self.rulerHeight), TimelineRow(track: .video, height: Self.videoHeight)]
        if recorded.filter(\.kind.isScreen).count >= 2 { tracks.append(TimelineRow(track: .screen, height: Self.screenHeight)) }
        tracks.append(TimelineRow(track: .zoom, height: Self.zoomHeight))
        if recorded.contains(where: { $0.kind == .camera }) { tracks.append(TimelineRow(track: .camera, height: Self.cameraHeight)) }
        for kind in [TrackKind.microphone, .systemAudio] {
            tracks += recorded.filter { $0.kind == kind }.map { TimelineRow(track: .audio(id: $0.id), height: Self.audioHeight) }
        }
        self.tracks = tracks
        duration = TimeMap(sequence: document.sequence).duration
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
