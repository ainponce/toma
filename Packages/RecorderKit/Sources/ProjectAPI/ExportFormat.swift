// SPDX-License-Identifier: GPL-3.0-or-later
import Export
import Foundation

/// What `TomaProject.export(to:format:progress:)` writes: a video (an MP4, or a QuickTime movie for ProRes and the
/// transparent codecs), a GIF, or a video with the files an external editor opens (milestone 4c's FCPXML and metadata).
public enum ExportFormat: Sendable {
    case video(ExportSettings)
    case gif(GIFSettings)
    case externalEditor(ExportSettings)
}

/// An export as the command line and the MCP server ask for it (plan 4b decision 12), which
/// `TomaProject.format(for:)` turns into an `ExportFormat` of the project: the codec by its name, the size as the
/// shorter side of a video (720, 1080, 1440 or 2160) or the longer side of a GIF, the frame rate (the document's, or
/// 15 for a GIF) and the quality. A key it does not have is its default.
public struct ExportRequest: Codable, Equatable, Sendable {
    public enum Kind: String, Codable, Sendable { case video, gif, externalEditor }

    public var kind: Kind = .video
    /// One of `codecs`' names: `h264` by default. A GIF has none.
    public var codec: String = "h264"
    /// The shorter side of a video (`ExportResolution`, 1080 by default), the longer side of a GIF
    /// (`GIFSettings.longSides`, 800 by default).
    public var size: Int?
    /// The frames per second: one of `EditDocument.frameRates` (the document's by default) for a video, one of
    /// `GIFSettings.framesPerSecond` (15 by default) for a GIF.
    public var fps: Int?
    /// `standard` or `high`: a video's bitrate, a GIF's colours (`balanced` or `high`).
    public var quality: String = "standard"
    /// For an export for an external editor: whether its `.fcpxml` and `.toma-metadata.json` may replace files of their
    /// names next to the video (`ExportSettings.replacesEditorFiles`); otherwise such files are `refused`, and nothing is
    /// written.
    public var replacesEditorFiles: Bool = false

    /// The codecs by the names the command line and the MCP server give them.
    public static let codecs: [String: ExportCodec] = [
        "h264": .h264, "hevc": .hevc, "hevc-alpha": .hevcAlpha, "prores422": .proRes422, "prores422hq": .proRes422HQ,
        "prores4444": .proRes4444,
    ]
    /// The qualities by their names.
    public static let qualities = ["standard", "high"]

    public init(
        kind: Kind = .video, codec: String = "h264", size: Int? = nil, fps: Int? = nil, quality: String = "standard",
        replacesEditorFiles: Bool = false
    ) {
        self.kind = kind
        self.codec = codec
        self.size = size
        self.fps = fps
        self.quality = quality
        self.replacesEditorFiles = replacesEditorFiles
    }

    /// The name of `codec` in `codecs`.
    public static func name(of codec: ExportCodec) -> String {
        codecs.first { $0.value == codec }?.key ?? codec.rawValue
    }

    private enum CodingKeys: String, CodingKey { case kind, codec, size, fps, quality, replacesEditorFiles }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        kind = try container.decodeIfPresent(Kind.self, forKey: .kind) ?? .video
        codec = try container.decodeIfPresent(String.self, forKey: .codec) ?? "h264"
        size = try container.decodeIfPresent(Int.self, forKey: .size)
        fps = try container.decodeIfPresent(Int.self, forKey: .fps)
        quality = try container.decodeIfPresent(String.self, forKey: .quality) ?? "standard"
        replacesEditorFiles = try container.decodeIfPresent(Bool.self, forKey: .replacesEditorFiles) ?? false
    }
}

/// What an export wrote.
public struct ExportResult: Codable, Equatable, Sendable {
    /// Where the file is: the destination asked for, with the extension of its format added if it had none.
    public var path: String
    /// The file's format, by its extension: `mp4`, `mov` or `gif`.
    public var format: String
    /// The video's codec by its name in `ExportRequest.codecs`; `nil` for a GIF.
    public var codec: String?
    public var width: Int
    public var height: Int
    public var framesPerSecond: Int
    /// What it lasts, in seconds of output.
    public var duration: Double
    /// Its size on disk.
    public var bytes: Int64
    /// The chapters its chapter track has (a video's, from the markers with a name).
    public var chapters: Int
    /// What the export had to leave out or do otherwise, in English: a cleanup skipped, sound or video that could not be
    /// read.
    public var warnings: [String]
    /// The FCPXML written next to it (an export for an external editor); `nil` otherwise.
    public var fcpxml: String?
    /// The metadata JSON written next to it (an export for an external editor); `nil` otherwise.
    public var metadata: String?

    public init(
        path: String, format: String, codec: String?, width: Int, height: Int, framesPerSecond: Int, duration: Double,
        bytes: Int64, chapters: Int, warnings: [String], fcpxml: String?, metadata: String?
    ) {
        self.path = path
        self.format = format
        self.codec = codec
        self.width = width
        self.height = height
        self.framesPerSecond = framesPerSecond
        self.duration = duration
        self.bytes = bytes
        self.chapters = chapters
        self.warnings = warnings
        self.fcpxml = fcpxml
        self.metadata = metadata
    }
}
