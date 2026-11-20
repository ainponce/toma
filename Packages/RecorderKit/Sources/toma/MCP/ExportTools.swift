// SPDX-License-Identifier: GPL-3.0-or-later
import Export
import Foundation
import ProjectAPI
import ProjectFormat

/// `export_video{project, output, codec?, size?, fps?, quality?, gif?, background?}`: the project as it is on disk,
/// exported as the app exports it (`ProjectRunner.export`, plan 4b decision 12), never into a package. Its progress goes
/// as `notifications/progress` when the client asked for it; cancelling the call stops the export and leaves no file.
/// With `background: true` it answers at once with a job (`ExportJobs`) that `export_status` tells of: a client that
/// gives up on a call after 60 s (Claude Desktop) can still export minutes of video.
struct ExportVideoTool: MCPTool {
    let name = "export_video"
    var description: String {
        """
        Exports the project as it is now, as Toma's Export does (the same clean voice, loudness, camera masks and \
        music): an MP4 (codec h264, the default, or hevc), a QuickTime movie (prores422, prores422hq, and prores4444 or \
        hevc-alpha with a transparent background), or an animated GIF of the whole output (gif: true). The output is \
        a file path outside any .toma package; without an extension the format's is added, and a file already there is \
        replaced once the export is whole. The result has the file's path, size, duration and chapters. An export takes \
        about as long as the video or more: with background: true the call answers at once with a jobId, and \
        export_status {jobId} tells how it goes (use it when the client gives up on calls after a minute, as Claude \
        Desktop does, or for anything longer than a minute or two of video). Otherwise the call waits: it sends \
        notifications/progress when it has a progressToken, and cancelling it leaves no file.
        """
    }
    var inputSchema: JSONValue {
        ExportArguments.schema(gif: true, background: true)
    }
    var annotations: JSONValue? { MCPSchema.annotations("Export a Toma project", readOnly: false, destructive: true) }

    func call(_ arguments: JSONValue, context: MCPContext) async throws -> MCPToolResult {
        let export = try ExportArguments(arguments, tool: name, gif: true, background: true, context: context)
        let kind: ExportRequest.Kind = export.gif ? .gif : .video
        if export.background { return try .json(export.start(kind: kind, context: context)) }
        return try .json(try await export.run(kind: kind, context: context))
    }
}

/// The arguments the export tools share (`export_video` and, from Task A6, `export_fcpxml`) and the export they ask for.
struct ExportArguments: Sendable {
    var project: URL
    /// The output as given.
    var output: URL
    /// The file the export writes: the output with its format's extension.
    var destination: URL
    var codec: String?
    var size: Int?
    var fps: Int?
    var quality: String?
    var gif: Bool
    var background: Bool

    /// The arguments of `tool`; `gif` and `background` are among them only when the tool takes them.
    /// `invalidCommand` for a codec, a quality, a size or a frame rate it does not take, a codec with a GIF, or an
    /// output whose extension is not the format's.
    init(
        _ arguments: JSONValue, tool: String, gif takesGIF: Bool, background takesBackground: Bool = false,
        context: MCPContext
    ) throws {
        var keys: Set<String> = ["project", "output", "codec", "size", "fps", "quality"]
        if takesGIF { keys.insert("gif") }
        if takesBackground { keys.insert("background") }
        let arguments = try MCPArguments(arguments, tool: tool, keys: keys)
        project = try context.packageURL(try arguments.string("project"))
        output = try context.outputURL(try arguments.string("output"))
        codec = try arguments.optionalString("codec")
        size = try arguments.optionalInt("size")
        fps = try arguments.optionalInt("fps")
        quality = try arguments.optionalString("quality")
        gif = try arguments.optionalBool("gif") ?? false
        background = try arguments.optionalBool("background") ?? false
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
        // What `TomaProject.format(for:)` refuses, before an export in the background starts.
        let sizes = gif ? GIFSettings.longSides : ExportResolution.allCases.map(\.rawValue)
        if let size, !sizes.contains(size) {
            throw APIError(
                .invalidCommand, "\(tool): size is \(gif ? "a GIF's longer" : "a video's shorter") side, one of \(Self.list(sizes))")
        }
        let rates = gif ? GIFSettings.framesPerSecond : EditDocument.frameRates
        if let fps, !rates.contains(fps) {
            throw APIError(.invalidCommand, "\(tool): fps is one of \(Self.list(rates))")
        }
        let fileExtension = gif ? "gif" : (ExportRequest.codecs[codec ?? "h264"] ?? .h264).fileExtension
        if output.pathExtension.isEmpty {
            destination = output.appendingPathExtension(fileExtension)
        } else if output.pathExtension.lowercased() == fileExtension {
            destination = output
        } else {
            let what = gif ? "a GIF is" : "\(codec ?? "h264") is written in"
            throw APIError(.invalidCommand, "\(tool): \(what) a .\(fileExtension) file, not a .\(output.pathExtension) one")
        }
    }

    /// The export of `kind`, with the call's progress: once no call before it works on the package (which it holds only
    /// until the export has read the project) and no other export writes the same file.
    func run(kind: ExportRequest.Kind, context: MCPContext) async throws -> ExportResult {
        let progress = context.progress
        do {
            return try await exporting(kind: kind, place: context.place(for: project), context: context) { fraction in
                progress?(fraction, nil)
            }
        } catch is CancellationError where !Task.isCancelled {
            throw APIError(.exportFailed, "the export was cancelled: nothing was written")
        }
    }

    /// The export of `kind` as a job in the background (`ExportJobs`): its place in the package's line is taken now, so
    /// it comes after the calls before it, and its first status is given at once.
    func start(kind: ExportRequest.Kind, context: MCPContext) throws -> ExportJobs.Status {
        var id = context.environment.makeID("export-")
        while context.jobs.contains(id) { id = context.environment.makeID("export-") }
        // Taken last: nothing can throw between it and the job, which releases it.
        let place = context.place(for: project)
        let arguments = self
        return context.jobs.start(id: id, project: project, output: destination) { progress in
            try await arguments.exporting(kind: kind, place: place, context: context, progress: progress)
        }
    }

    /// The export, holding `place` in the package's line until the project is read (the first progress comes once it
    /// is), and the output's line until the file is written.
    private func exporting(
        kind: ExportRequest.Kind, place: PackageLocks.Ticket, context: MCPContext,
        progress: @escaping @Sendable (Double) -> Void
    ) async throws -> ExportResult {
        let request = ExportRequest(kind: kind, codec: codec ?? "h264", size: size, fps: fps, quality: quality ?? "standard")
        let project = project, destination = destination, environment = context.environment, locks = context.locks
        return try await locks.holding(place) { () async throws -> ExportResult in
            try await locks.holding(locks.reserve(.output(destination))) { () async throws -> ExportResult in
                try await ProjectRunner.export(project, to: destination, request: request, environment: environment) { fraction in
                    // The project is read: the calls after this one on it go on.
                    locks.release(place)
                    progress(fraction)
                }
            }
        }
    }

    private static func list(_ values: [Int]) -> String {
        values.map(String.init).joined(separator: ", ")
    }

    /// The input schema: `gif` and `background` only when the tool takes them.
    static func schema(gif: Bool, background: Bool = false) -> JSONValue {
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
        if background {
            properties["background"] = MCPSchema.boolean(
                "Answer at once with {jobId, status: \"running\", …} and export in the background; export_status {jobId} "
                    + "tells how it goes. For clients that give up on a call after a minute (Claude Desktop) and long videos.")
        }
        return MCPSchema.object(properties, required: ["project", "output"])
    }
}
