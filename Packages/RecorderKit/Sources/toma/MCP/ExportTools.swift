// SPDX-License-Identifier: GPL-3.0-or-later
import Export
import Foundation
import ProjectAPI
import ProjectFormat

/// `export_video{project, output, codec?, size?, fps?, quality?, gif?}`: the project as it is on disk, exported as the
/// app exports it (`ProjectRunner.export`, plan 4b decision 12), never into a package. Its progress goes as
/// `notifications/progress` when the client asked for it; cancelling the call stops the export and leaves no file.
struct ExportVideoTool: MCPTool {
    let name = "export_video"
    var description: String {
        """
        Exports the project as it is now, as Toma's Export does (the same clean voice, loudness, camera masks and \
        music): an MP4 (codec h264, the default, or hevc), a QuickTime movie (prores422, prores422hq, and prores4444 or \
        hevc-alpha with a transparent background), or an animated GIF of the whole output (gif: true). The output is \
        a file path outside any .toma package; without an extension the format's is added, and a file already there is \
        replaced once the export is whole. It can take minutes: it sends notifications/progress when the call has a \
        progressToken, and cancelling it leaves no file. The result has the file's path, size, duration and chapters.
        """
    }
    var inputSchema: JSONValue {
        ExportArguments.schema(gif: true)
    }
    var annotations: JSONValue? { MCPSchema.annotations("Export a Toma project", readOnly: false, destructive: true) }

    func call(_ arguments: JSONValue, context: MCPContext) async throws -> MCPToolResult {
        let export = try ExportArguments(arguments, tool: name, gif: true, context: context)
        return try .json(try await export.run(kind: export.gif ? .gif : .video, context: context))
    }
}

/// The arguments the export tools share (`export_video` and, from Task A6, `export_fcpxml`) and the export they ask for.
struct ExportArguments {
    var project: URL
    var output: URL
    var codec: String?
    var size: Int?
    var fps: Int?
    var quality: String?
    var gif: Bool

    /// The arguments of `tool`; `gif` is one of them only when the tool takes it. `invalidCommand` for a codec or a
    /// quality it does not know, or a codec with a GIF.
    init(_ arguments: JSONValue, tool: String, gif takesGIF: Bool, context: MCPContext) throws {
        var keys: Set<String> = ["project", "output", "codec", "size", "fps", "quality"]
        if takesGIF { keys.insert("gif") }
        let arguments = try MCPArguments(arguments, tool: tool, keys: keys)
        project = try context.packageURL(try arguments.string("project"))
        output = try context.outputURL(try arguments.string("output"))
        codec = try arguments.optionalString("codec")
        size = try arguments.optionalInt("size")
        fps = try arguments.optionalInt("fps")
        quality = try arguments.optionalString("quality")
        gif = try arguments.optionalBool("gif") ?? false
        if let codec {
            guard !gif else { throw APIError(.invalidCommand, "\(tool): a GIF has no codec; leave “codec” out with “gif”") }
            guard ExportRequest.codecs[codec] != nil else {
                let codecs = ExportRequest.codecs.keys.sorted().joined(separator: ", ")
                throw APIError(.invalidCommand, "\(tool): codec is one of \(codecs)")
            }
        }
        if let quality, !ExportRequest.qualities.contains(quality) {
            throw APIError(.invalidCommand, "\(tool): quality is one of \(ExportRequest.qualities.joined(separator: ", "))")
        }
    }

    /// The export of `kind`, with the call's progress, once no other call works on the package.
    func run(kind: ExportRequest.Kind, context: MCPContext) async throws -> ExportResult {
        let request = ExportRequest(kind: kind, codec: codec ?? "h264", size: size, fps: fps, quality: quality ?? "standard")
        let project = project, output = output, environment = context.environment
        var progress: (@Sendable (Double) -> Void)?
        if let report = context.progress { progress = { report($0, nil) } }
        let reporting = progress
        do {
            return try await context.serialized(project) { () async throws -> ExportResult in
                try await ProjectRunner.export(
                    project, to: output, request: request, environment: environment, progress: reporting)
            }
        } catch is CancellationError where !Task.isCancelled {
            throw APIError(.exportFailed, "the export was cancelled: nothing was written")
        }
    }

    /// The input schema: `gif` only when the tool takes it.
    static func schema(gif: Bool) -> JSONValue {
        let codecs = ExportRequest.codecs.keys.sorted()
        let sizes = ExportResolution.allCases.map { String($0.rawValue) }.joined(separator: ", ")
        let gifSizes = GIFSettings.longSides.map(String.init).joined(separator: ", ")
        let rates = EditDocument.frameRates.map(String.init).joined(separator: ", ")
        let gifRates = GIFSettings.framesPerSecond.map(String.init).joined(separator: ", ")
        var properties: [String: JSONValue] = [
            "project": MCPSchema.project,
            "output": MCPSchema.string(
                "Where the file goes: an absolute path (~ is the home folder, ~/Desktop/demo.mp4), or one from the server's "
                    + "working directory. Never inside a .toma package. Without an extension the format's is added; "
                    + "another extension than the format's is refused."),
            "codec": MCPSchema.string(
                "The video's codec: h264 by default and hevc write an .mp4; prores422, prores422hq, prores4444 and "
                    + "hevc-alpha a .mov (the last two with a transparent background).",
                choices: codecs),
            "size": MCPSchema.integer(
                "In pixels: the shorter side of a video, one of \(sizes) (1080 by default)"
                    + (gif ? "; the longer side of a GIF, one of \(gifSizes) (800 by default)." : ".")),
            "fps": MCPSchema.integer(
                "Frames per second: the project's by default, one of \(rates)"
                    + (gif ? "; for a GIF one of \(gifRates) (15 by default)." : ".")),
            "quality": MCPSchema.string(
                "standard (the default) or high: a video's bitrate" + (gif ? ", a GIF's colours." : "."),
                choices: ExportRequest.qualities),
        ]
        if gif { properties["gif"] = MCPSchema.boolean("Export an animated GIF of the whole output instead of a video.") }
        return MCPSchema.object(properties, required: ["project", "output"])
    }
}
