// SPDX-License-Identifier: GPL-3.0-or-later
import ProjectFormat

/// The imported clip a frame of the sequence shows (phase 3 design §5.4 and §12, step 2; plan 3a decision 12), drawn where
/// the screens are: the frame of its file at `fileTime`, read by its reader (`AssetFrameReader.readerID(of:)`), fitted
/// whole into `room` with the proportion of the frame as the renderer decodes it, turned upright
/// (`rect(fitting:)`), with corners of `cornerRadius` and the screen's shadow of weight `shadow`. No window or device
/// frame, cursor, camera nor zoom.
public struct MediaClipLayer: Equatable, Sendable {
    /// The clip's file, as the document names it (`assets/<sha>.<mov|mp4|m4v>`).
    public var asset: String
    /// The instant of the file shown, in ns from its start: `start + round(offset × v)`, held to `[start, end − 1]`.
    public var fileTime: Int64
    /// Where the screens go: the whole room inside the margin (`StageLayout.screenRect(contentAspect: nil, …)`), in output
    /// pixels.
    public var room: Rect
    /// In output pixels: the style's corners, `style.cornerRadius × W`, as the screen's.
    public var cornerRadius: Double
    /// The style's shadow, 0 to 1: the screen's, cast by the clip.
    public var shadow: Double

    public init(asset: String, fileTime: Int64, room: Rect, cornerRadius: Double, shadow: Double) {
        self.asset = asset
        self.fileTime = fileTime
        self.room = room
        self.cornerRadius = cornerRadius
        self.shadow = shadow
    }

    /// `fileTime` as the reader reads it: host time from 0, the file's own time (none before it).
    var sourceTime: HostTime {
        HostTime(nanoseconds: UInt64(max(fileTime, 0)))
    }

    /// Where a picture of `size` (upright, `MediaOrientation.uprightSize(of:)`) is drawn: the largest rect of its
    /// proportion centred in `room`; an empty rect at its centre for a size that is not positive and finite, or an empty
    /// room.
    func rect(fitting size: SIMD2<Double>) -> Rect {
        let room = room
        guard room.width > 0, room.height > 0, size.x > 0, size.y > 0, size.x.isFinite, size.y.isFinite else {
            return Rect(x: room.x + max(room.width, 0) / 2, y: room.y + max(room.height, 0) / 2, width: 0, height: 0)
        }
        let aspect = size.x / size.y
        let fitted = room.width / room.height > aspect
            ? SIMD2(room.height * aspect, room.height)
            : SIMD2(room.width, room.width / aspect)
        return Rect(
            x: room.x + (room.width - fitted.x) / 2, y: room.y + (room.height - fitted.y) / 2, width: fitted.x, height: fitted.y)
    }
}

/// The imported clips of a document's sequence (`ClipContent.media`) as the frames draw them, worked out once for the
/// scene and again for each size (`FrameEvaluator.init` and `resized(to:)`): a frame of one is the frame with the
/// background alone with the clip's layer on it (`MediaClipLayer`), in the style's room, corners and shadow.
struct MediaClipScene: Sendable {
    /// The imported clip of each clip of the sequence that is one, by its index.
    private let clips: [Int: MediaClip]
    private let room: Rect
    private let cornerRadius: Double
    private let shadow: Double

    init(document: EditDocument, timeMap: TimeMap, outputSize: SIMD2<Int>) {
        var clips: [Int: MediaClip] = [:]
        for (k, clip) in document.sequence.enumerated() {
            if case let .media(media)? = clip.content { clips[k] = media }
        }
        self.clips = clips
        let style = document.style, size = SIMD2(Double(outputSize.x), Double(outputSize.y))
        room = StageLayout.screenRect(contentAspect: nil, padding: style.padding, outputSize: size)
        // The screen's corners and shadow (`FrameEvaluator.takeFrame`), read the same way.
        cornerRadius = style.cornerRadius * size.x
        shadow = style.shadow.isNaN ? 0 : min(max(style.shadow, 0), 1)
    }

    /// The frame at `offset` ns into clip `k` of the sequence, an imported clip (`TimeMap.contentOffset(atOutput:)`), over
    /// `background`, the frame with the background alone: `background` with the clip's layer (`MediaClipLayer`) at its
    /// file's instant of the offset (`fileTime(of:atOffset:)`); `background` itself for any other clip, and for one that
    /// lasts nothing (never shown).
    func frame(clip k: Int, offset: Int64, background: RenderFrame) -> RenderFrame {
        guard let media = clips[k], media.end > media.start else { return background }
        var frame = background
        frame.media = MediaClipLayer(
            asset: media.asset, fileTime: Self.fileTime(of: media, atOffset: offset), room: room, cornerRadius: cornerRadius,
            shadow: shadow)
        return frame
    }

    /// The instant of `media`'s file shown `offset` ns of output into it: `start + round(offset × v)` (halves away from
    /// zero, as `TimeMap` rounds a clip's), with its speed read by `ClipSpeed.clamped(_:)`, held to `[start, end − 1]`.
    static func fileTime(of media: MediaClip, atOffset offset: Int64) -> Int64 {
        let last = media.end &- 1
        guard media.end > media.start else { return media.start }
        let into = (Double(max(offset, 0)) * ClipSpeed.clamped(media.speed)).rounded()
        // `Double(Int64.max)` is 2⁶³, one past it: an offset that far is past the end.
        guard into < Double(Int64.max) else { return last }
        let (sum, overflow) = media.start.addingReportingOverflow(Int64(into))
        return overflow ? last : min(max(sum, media.start), last)
    }
}
