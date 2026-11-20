// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import ProjectFormat

/// `<name>.toma-metadata.json`, `metadata-1` (phases 4 and 5 design §7.2, plan 4c decision 10): what each frame of an
/// export draws and what its output holds, in output seconds and in the video's pixels, for After Effects, DaVinci, Motion
/// or a script. One compact JSON object with its keys sorted (`[.sortedKeys, .withoutEscapingSlashes]`), pixels to 0.01
/// and seconds to 10⁻⁶; the schema is frozen with its id (`docs/format/README.md`):
///
/// ```
/// {"chapters":[{"frame","time","title"}],
///  "clicks":[{"frame","time","x","y"}],                  x and y null where the frame does not show the cursor
///  "cuts":[{"content","end","sourceEnd","sourceStart","speed","start","take"}],
///  "format":"metadata-1",
///  "frames":[{"cursor":{"pressed","visible","x","y"}|null,"zoom":{"depth","x","y"}}],
///  "markers":[{"frame","id","name","time"}],
///  "video":{"alpha","duration","file","frameRate","frames","height","width"},
///  "zoomBlocks":[{"depth","end","endFrame","id","mode","origin","start","startFrame"}]}
/// ```
enum EditorMetadataFile {
    /// The file of `timeline`, the export of the video `video` describes.
    /// - Throws: what `JSONEncoder` throws (nothing it is given here can fail).
    static func data(_ timeline: EditorTimeline, video: VideoFacts) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(File(timeline, video: video))
    }

    /// Pixels to 0.01; 0 for a value that is not a finite number.
    static func pixels(_ value: Double) -> Double {
        value.isFinite ? (value * 100).rounded() / 100 : 0
    }

    /// Output nanoseconds as seconds to 10⁻⁶.
    static func seconds(_ nanoseconds: Int64) -> Double {
        (Double(nanoseconds) / 1_000).rounded() / 1_000_000
    }

    /// A depth to 10⁻⁶; 1 for one that is not a finite number.
    static func depth(_ value: Double) -> Double {
        value.isFinite ? (value * 1_000_000).rounded() / 1_000_000 : 1
    }

    private struct File: Encodable {
        var format = ExternalEditorExport.metadataID
        var video: Video
        var cuts: [Cut]
        var markers: [Mark]
        var chapters: [Chapter]
        var clicks: [Click]
        var zoomBlocks: [ZoomBlock]
        var frames: [Frame]

        init(_ timeline: EditorTimeline, video facts: VideoFacts) {
            let fps = timeline.frameRate
            video = Video(
                file: facts.url.lastPathComponent, width: facts.size.x, height: facts.size.y, frameRate: fps,
                frames: timeline.frameCount, duration: seconds(TimeMap.frameTime(timeline.frameCount, frameRate: fps)),
                alpha: facts.hasAlpha)
            cuts = timeline.cuts.map { cut in
                Cut(
                    take: cut.take, sourceStart: cut.sourceStart.nanoseconds, sourceEnd: cut.sourceEnd.nanoseconds,
                    start: seconds(cut.output.lowerBound), end: seconds(cut.output.upperBound), speed: cut.speed,
                    content: cut.content?.rawValue)
            }
            markers = timeline.markers.map { Mark(id: $0.id, name: $0.name, time: seconds($0.output), frame: $0.frame) }
            chapters = timeline.chapters.map { Chapter(title: $0.title, time: seconds($0.output), frame: $0.frame) }
            clicks = timeline.clicks.map { click in
                Click(
                    time: seconds(click.output), frame: click.frame, x: click.point.map { pixels($0.x) },
                    y: click.point.map { pixels($0.y) })
            }
            zoomBlocks = timeline.zoomBlocks.map { block in
                ZoomBlock(
                    id: block.id, start: seconds(block.output.lowerBound), end: seconds(block.output.upperBound),
                    startFrame: block.frames.lowerBound, endFrame: block.frames.upperBound, depth: depth(block.depth),
                    mode: block.mode.rawValue, origin: block.origin.rawValue)
            }
            frames = timeline.frames.map { frame in
                Frame(
                    cursor: frame.cursor.map { cursor in
                        Cursor(x: pixels(cursor.point.x), y: pixels(cursor.point.y), visible: cursor.visible, pressed: cursor.pressed)
                    },
                    zoom: Zoom(depth: depth(frame.zoom.depth), x: pixels(frame.zoom.center.x), y: pixels(frame.zoom.center.y)))
            }
        }
    }

    private struct Video: Encodable {
        var file: String
        var width: Int
        var height: Int
        var frameRate: Int
        var frames: Int
        var duration: Double
        var alpha: Bool
    }

    private struct Cut: Encodable {
        var take: String
        var sourceStart: UInt64
        var sourceEnd: UInt64
        var start: Double
        var end: Double
        var speed: Double
        /// `null` for a stretch of the take: `freeze`, `titleCard` or `media` otherwise.
        var content: String?

        private enum CodingKeys: String, CodingKey {
            case take, sourceStart, sourceEnd, start, end, speed, content
        }

        func encode(to encoder: any Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode(take, forKey: .take)
            try container.encode(sourceStart, forKey: .sourceStart)
            try container.encode(sourceEnd, forKey: .sourceEnd)
            try container.encode(start, forKey: .start)
            try container.encode(end, forKey: .end)
            try container.encode(speed, forKey: .speed)
            try container.encode(content, forKey: .content)
        }
    }

    private struct Mark: Encodable {
        var id: String
        var name: String
        var time: Double
        var frame: Int
    }

    private struct Chapter: Encodable {
        var title: String
        var time: Double
        var frame: Int
    }

    private struct Click: Encodable {
        var time: Double
        var frame: Int
        var x: Double?
        var y: Double?

        private enum CodingKeys: String, CodingKey {
            case time, frame, x, y
        }

        func encode(to encoder: any Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode(time, forKey: .time)
            try container.encode(frame, forKey: .frame)
            try container.encode(x, forKey: .x)
            try container.encode(y, forKey: .y)
        }
    }

    private struct ZoomBlock: Encodable {
        var id: String
        var start: Double
        var end: Double
        var startFrame: Int
        var endFrame: Int
        var depth: Double
        var mode: String
        var origin: String
    }

    private struct Cursor: Encodable {
        var x: Double
        var y: Double
        var visible: Bool
        var pressed: Bool
    }

    private struct Zoom: Encodable {
        var depth: Double
        var x: Double
        var y: Double
    }

    private struct Frame: Encodable {
        var cursor: Cursor?
        var zoom: Zoom

        private enum CodingKeys: String, CodingKey {
            case cursor, zoom
        }

        func encode(to encoder: any Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode(cursor, forKey: .cursor)
            try container.encode(zoom, forKey: .zoom)
        }
    }
}
