// SPDX-License-Identifier: GPL-3.0-or-later
import Editing
import Foundation
import ProjectFormat

/// What the timeline's Video track does with a clip with content (phase 3 design §5.2–§5.4, plan 3a Task A15): a frozen
/// frame, a title card or an imported clip in the sequence. A frozen frame's or a title card's right edge sets its length
/// (`ContentClipCommands.setDuration`), its left edge does nothing; an imported clip's two edges trim its file
/// (`ContentClipCommands.trimMedia`); a stretch of a take is trimmed as in 1b (`SequenceCommands.trim`).
public enum ContentClipTrackRules {
    /// What a drag of an edge of a clip with content does.
    public enum Drag: Equatable, Sendable {
        /// The right edge of a frozen frame or a title card: its length.
        case duration
        /// The left or the right edge of an imported clip: where its file starts or ends.
        case mediaStart, mediaEnd
    }

    /// The extensions a file dropped on the Video track is taken with, lowercased: a clip (`AssetKind.video`).
    public static let videoExtensions: Set<String> = ["mov", "mp4", "m4v"]

    /// What dragging `edge` of `clip` does; `nil` for a stretch of a take (trimmed as in 1b) and for the left edge of a
    /// frozen frame or a title card, which is where the clip before it ends.
    public static func drag(for edge: ClipEdge, of clip: Clip) -> Drag? {
        switch (clip.content, edge) {
        case (nil, _): nil
        case (.freeze?, .end), (.card?, .end): .duration
        case (.freeze?, .start), (.card?, .start): nil
        case (.media?, .start): .mediaStart
        case (.media?, .end): .mediaEnd
        }
    }

    /// The length of the frozen frame or the title card `clip`, which starts at output instant `start`, with its right edge
    /// dragged to `toOutputEnd`: `toOutputEnd − start` (saturating) held to `ClipContent.durationRange` (0.1 to 60 s). For
    /// any other clip, what it lasts in the output as it is (`TimeMap.outputDuration(of:)`): its edges set no length.
    public static func duration(dragging clip: Clip, toOutputEnd: Int64, start: Int64) -> Int64 {
        guard drag(for: .end, of: clip) == .duration else { return TimeMap.outputDuration(of: clip) }
        let (difference, overflow) = toOutputEnd.subtractingReportingOverflow(start)
        let length = overflow ? (toOutputEnd > start ? Int64.max : Int64.min) : difference
        return held(length)
    }

    /// What a title card's block says: its title on one line (its lines joined by a space, without the spaces around
    /// it). `nil` for a title of nothing but spaces (the app names it "Title Card"), and for any other clip.
    public static func label(of clip: Clip) -> String? {
        guard case let .card(card, _)? = clip.content else { return nil }
        let line = card.title.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }.joined(separator: " ")
        return line.isEmpty ? nil : line
    }

    /// The length "Duration…" asks for, typed in seconds ("2,5", "2.5", "2,5 s"), held to `ClipContent.durationRange`;
    /// `nil` when it is not a number of seconds above 0.
    public static func duration(fromTyped text: String) -> Int64? {
        var typed = text.trimmingCharacters(in: .whitespaces).lowercased()
        if typed.hasSuffix("s") { typed = String(typed.dropLast()).trimmingCharacters(in: .whitespaces) }
        typed = typed.replacingOccurrences(of: ",", with: ".")
        guard let seconds = Double(typed), seconds.isFinite, seconds > 0 else { return nil }
        // Past the range it is held anyway: no need to reach `Int64`'s limits.
        return held(Int64((min(seconds, 1e6) * 1e9).rounded()))
    }

    /// A thumbnail of a frozen frame or an imported clip on the Video track: where it is in the output, cut at the clip's
    /// end, and the frame it shows.
    public struct Tile: Equatable, Sendable {
        /// Its number in the clip, from 0.
        public var index: Int
        public var output: Int64
        public var end: Int64
        /// The frame it shows: of a frozen frame, the take's at its point (host nanoseconds); of an imported clip, the
        /// file's at the tile's left edge (nanoseconds of the file).
        public var frame: UInt64

        public init(index: Int, output: Int64, end: Int64, frame: UInt64) {
            self.index = index
            self.output = output
            self.end = end
            self.frame = frame
        }
    }

    /// The thumbnails of `clip`, which starts at output instant `outputStart`, in the output range `visible`, on the
    /// grid of a take's clips (`TimelineLayout.thumbnailTiles`, with its `scale`, `tileWidth` and `minimumWidth`): a
    /// frozen frame's all show the frame of its point, so it reads as still; an imported clip's each show its file at
    /// their left edge, `start + round(offset × v)` held to `end − 1`, as a clip of the take does. None for a title card,
    /// a stretch of a take (whose are the take's), or an imported clip that shows nothing of its file.
    public static func tiles(
        of clip: Clip, outputStart: Int64, visible: Range<Int64>, scale: Double, tileWidth: Double, minimumWidth: Double
    ) -> [Tile] {
        // The clip as a stretch whose source is what its tiles show, from output 0: the take's grid lays it out.
        let stretch: Clip
        switch clip.content {
        case .freeze?:
            let length = TimeMap.outputDuration(of: clip)
            stretch = Clip(id: clip.id, take: clip.take, start: HostTime(nanoseconds: 0), end: HostTime(nanoseconds: UInt64(length)), speed: 1)
        case let .media(media)?:
            guard media.start >= 0, media.end > media.start else { return [] }
            stretch = Clip(
                id: clip.id, take: clip.take, start: HostTime(nanoseconds: UInt64(media.start)),
                end: HostTime(nanoseconds: UInt64(media.end)), speed: media.speed)
        case .card?, nil:
            return []
        }
        func shifted(_ τ: Int64) -> Int64 {
            let (difference, overflow) = τ.subtractingReportingOverflow(outputStart)
            return overflow ? (τ > outputStart ? .max : .min) : difference
        }
        let lower = shifted(visible.lowerBound), upper = max(shifted(visible.upperBound), lower)
        let tiles = TimelineLayout.thumbnailTiles(
            sequence: [stretch], map: TimeMap(sequence: [stretch]), visible: lower..<upper, scale: scale, tileWidth: tileWidth,
            minimumWidth: minimumWidth)
        let still: UInt64? = if case .freeze? = clip.content { clip.start.nanoseconds } else { nil }
        return tiles.map { tile in
            Tile(index: tile.index, output: outputStart &+ tile.output, end: outputStart &+ tile.end, frame: still ?? tile.source.nanoseconds)
        }
    }

    /// Whether `url` is a file the Video track takes when it is dropped there: a local file named as a clip
    /// (`videoExtensions`). Whether it plays is judged when it is imported (`EditSession.importAsset`).
    public static func isVideoFile(_ url: URL) -> Bool {
        url.isFileURL && videoExtensions.contains(url.pathExtension.lowercased())
    }

    private static func held(_ length: Int64) -> Int64 {
        min(max(length, ClipContent.durationRange.lowerBound), ClipContent.durationRange.upperBound)
    }
}
