// SPDX-License-Identifier: GPL-3.0-or-later
import Analysis
import Darwin
import Editing
import Export
import Foundation
import ProjectFormat
import ProjectJobs
import Render

extension TomaProject {
    /// The `ExportFormat` `request` asks for of this project as it is now (plan 4b decisions 10 and 12): a video of the
    /// document's aspect at the size, frame rate, quality and codec asked for, with the chapters of the markers with a
    /// name (`Chapters.list`, its intro "Introducción" for a transcript in Spanish and "Intro" otherwise, in the
    /// transcript's language); a GIF of the whole output; for an external editor, the video's settings with its files for
    /// editors (`ExportSettings.editorMetadata`, replacing those there only with `replacesEditorFiles`). `invalidCommand`
    /// for a codec, a size, a frame rate or a quality it does not take.
    public func format(for request: ExportRequest) async throws -> ExportFormat {
        let document = self.document, project = self.project
        guard ExportRequest.qualities.contains(request.quality) else {
            throw APIError(.invalidCommand, "quality is one of \(ExportRequest.qualities.joined(separator: ", "))")
        }
        let high = request.quality == "high"
        switch request.kind {
        case .gif:
            let longSide = request.size ?? 800
            guard GIFSettings.longSides.contains(longSide) else {
                throw APIError(.invalidCommand, "the size of a GIF is its longer side, one of \(Self.list(GIFSettings.longSides))")
            }
            let fps = request.fps ?? 15
            guard GIFSettings.framesPerSecond.contains(fps) else {
                throw APIError(.invalidCommand, "the frame rate of a GIF is one of \(Self.list(GIFSettings.framesPerSecond))")
            }
            return .gif(GIFSettings(
                longSide: longSide, fps: fps, quality: high ? .high : .balanced,
                range: ExportRange.whole(TimeMap(sequence: document.sequence))))
        case .video, .externalEditor:
            guard let codec = ExportRequest.codecs[request.codec] else {
                throw APIError(.invalidCommand, "codec is one of \(ExportRequest.codecs.keys.sorted().joined(separator: ", "))")
            }
            let shortSide = request.size ?? ExportResolution.p1080.rawValue
            guard let resolution = ExportResolution(rawValue: shortSide) else {
                throw APIError(
                    .invalidCommand,
                    "the size of a video is its shorter side, one of \(Self.list(ExportResolution.allCases.map(\.rawValue)))")
            }
            let fps = request.fps ?? document.frameRate
            guard EditDocument.frameRates.contains(fps) else {
                throw APIError(.invalidCommand, "the frame rate of a video is one of \(Self.list(EditDocument.frameRates))")
            }
            let chapters = Reports.chapters(await markers, document: document)
            let editor = request.kind == .externalEditor
            let settings = ExportSettings(
                aspect: document.aspect, resolution: resolution, framesPerSecond: fps, quality: high ? .high : .standard,
                contentRatio: StageLayout.contentRatio(project: project, document: document), codec: codec, chapters: chapters,
                chapterLanguage: chapters.isEmpty ? nil : Self.chapterLanguage(of: document), editorMetadata: editor,
                replacesEditorFiles: editor && request.replacesEditorFiles)
            return editor ? .externalEditor(settings) : .video(settings)
        }
    }

    /// Exports the project as it is now to `destination`, as the app exports it (fases 4 y 5 design §6.2): first the
    /// same preparation (`ExportPreparation.prepared`: the camera's masks and faces, the clean voice and the loudness,
    /// the music), with workers of its own, the caches and the music library of `environment` and its voice isolation;
    /// then `MP4Exporter` or `GIFExporter` with what it prepared. `progress` from 0 to 1, never down: the preparation is
    /// its first fifth. Nothing is ever written into a package; a file at `destination` is replaced once the export is
    /// whole. A destination without an extension gets its format's; another extension is `invalidCommand`.
    ///
    /// For an external editor (design §7.2), the video as `.video` exports it, and next to it `<name>.fcpxml` and
    /// `<name>.toma-metadata.json` of that video, as the export sheet's switch writes them (`MP4Exporter` with
    /// `ExportSettings.editorMetadata`, in the same pass: the sidecars describe the frames just encoded): their paths are
    /// in the result. Files of their names already there are replaced only with `ExportSettings.replacesEditorFiles`;
    /// otherwise the export is `refused` before anything is written.
    /// - Throws: `APIError` (`refused` for a destination inside a package or where it cannot be written, or files for an
    ///   external editor already there, `outOfRange` for an output that lasts less than a frame, `exportFailed` for the
    ///   rest, with the stage of the preparation that failed);
    ///   `CancellationError` if the task is cancelled, leaving nothing.
    public func export(
        to destination: URL, format: ExportFormat, progress: (@Sendable (Double) -> Void)?
    ) async throws -> ExportResult {
        guard !closed else { throw APIError(.refused, "the project is closed") }
        // Only what was recorded so far: the export would be cut where the recording is now.
        guard recordingTakes.isEmpty else { throw Self.beingRecorded(recordingTakes) }
        let (fileExtension, codec): (String, ExportCodec?) =
            switch format {
            case let .video(settings), let .externalEditor(settings): (settings.codec.fileExtension, settings.codec)
            case .gif: ("gif", nil)
            }
        let destination = try Self.destination(destination, fileExtension: fileExtension, codec: codec)
        let project = self.project, document = self.document, environment = self.environment
        let caches = ProjectCaches(root: environment.cachesRoot, projectID: project.manifest.resolvedProjectID)
        let workers = ExportWorkers.standalone(
            project: project, caches: caches, isolator: environment.isolator, library: MusicLibrary(root: environment.musicRoot))
        let report = progress ?? { _ in }
        do {
            // The exporters end with exactly 1, once the file is in place.
            return try await Self.export(
                project: project, document: document, format: format, caches: caches, workers: workers, to: destination,
                progress: report)
        } catch {
            // Nobody else waits for the jobs of these workers.
            await workers.jobs.cancelAll()
            if Self.isCancellation(error) || Task.isCancelled { throw CancellationError() }
            throw Self.exportError(error, codec: codec)
        }
    }

    // MARK: - Private

    /// What the preparation's part of the progress is: its first fifth.
    private nonisolated static let preparationShare = 0.2

    /// The preparation and the export, off the main actor.
    @concurrent private nonisolated static func export(
        project: LoadedProject, document: EditDocument, format: ExportFormat, caches: ProjectCaches, workers: ExportWorkers,
        to destination: URL, progress: @escaping @Sendable (Double) -> Void
    ) async throws -> ExportResult {
        let needs: ExportNeeds = if case .gif = format { .gif } else { .video }
        let prepared = try await ExportPreparation.prepared(
            project: project, document: document, caches: caches, needs: needs, workers: workers
        ) { progress(preparationShare * $0) }
        let exporting: @Sendable (Double) -> Void = { progress(preparationShare + (1 - preparationShare) * $0) }
        var warnings: [String] = []
        if prepared.cleanupSkipped {
            warnings.append("exported without noise cleanup: this Mac does not have the system's voice isolation")
        }
        switch format {
        case .video(var settings), .externalEditor(var settings):
            // The files for an external editor only for `.externalEditor`, whatever its settings say.
            let editor: Bool = if case .externalEditor = format { true } else { false }
            settings.editorMetadata = editor
            settings.replacesEditorFiles = editor && settings.replacesEditorFiles
            let summary = try await MP4Exporter(
                project: project, document: document, settings: settings, analysis: prepared.analysis,
                remakeMusic: prepared.remakeMusic
            ).export(to: destination, progress: exporting)
            warnings += leftOut(summary)
            let sidecars = editor ? ExternalEditorExport.sidecarURLs(of: destination) : nil
            return ExportResult(
                path: destination.path, format: settings.codec.fileExtension, codec: ExportRequest.name(of: settings.codec),
                width: settings.outputSize.x, height: settings.outputSize.y, framesPerSecond: settings.framesPerSecond,
                duration: TimeMap(sequence: document.sequence).durationSeconds, bytes: size(of: destination),
                chapters: settings.chapters.count, warnings: warnings, fcpxml: sidecars?.fcpxml.path,
                metadata: sidecars?.metadata.path)
        case let .gif(settings):
            let size = settings.outputSize(project: project, document: document)
            let summary = try await GIFExporter(project: project, document: document, settings: settings, analysis: prepared.analysis)
                .export(to: destination, progress: exporting)
            return ExportResult(
                path: destination.path, format: "gif", codec: nil, width: size.x, height: size.y, framesPerSecond: settings.fps,
                duration: Double(settings.range.end - settings.range.start) / 1e9, bytes: summary.bytes, chapters: 0,
                warnings: warnings, fcpxml: nil, metadata: nil)
        }
    }

    /// `destination` with `fileExtension` added if it has none (`ProjectPaths.output`'s rules: never inside a package).
    private nonisolated static func destination(_ destination: URL, fileExtension: String, codec: ExportCodec?) throws -> URL {
        var url = try ProjectPaths.output(destination.path, relativeTo: URL(fileURLWithPath: "/"))
        if url.pathExtension.isEmpty {
            url = url.appendingPathExtension(fileExtension)
        } else if url.pathExtension.lowercased() != fileExtension {
            let what = codec.map { "\(ExportRequest.name(of: $0)) is written in" } ?? "a GIF is"
            throw APIError(.invalidCommand, "\(what) a .\(fileExtension) file, not a .\(url.pathExtension) one")
        }
        return url
    }

    /// What the export had to leave out, a sentence for each track.
    private nonisolated static func leftOut(_ summary: ExportSummary) -> [String] {
        var warnings: [String] = []
        for track in Set(summary.missingAudio.map(\.track)).sorted() {
            let parts = summary.missingAudio.filter { $0.track == track }.count
            warnings.append("\(parts) part\(parts == 1 ? "" : "s") of the track \(track) have no sound: its audio could not be read")
        }
        for track in Set(summary.missingVideo.map(\.track)).sorted() {
            let parts = summary.missingVideo.filter { $0.track == track }.count
            warnings.append(
                "\(parts) part\(parts == 1 ? "" : "s") of the track \(track) show the frame before: its video could not be read")
        }
        return warnings
    }

    /// The size of the file at `url`; 0 if it cannot be read.
    private nonisolated static func size(of url: URL) -> Int64 {
        var info = stat()
        return lstat(url.path, &info) == 0 ? Int64(info.st_size) : 0
    }

    /// The language of the chapters' titles: the transcript's (its language alone, `es` of `es-MX`); `nil` without one.
    private nonisolated static func chapterLanguage(of document: EditDocument) -> String? {
        guard let language = document.transcript?.language, !language.isEmpty else { return nil }
        return Locale.Language(identifier: language).languageCode?.identifier ?? language
    }

    private nonisolated static func list(_ values: [Int]) -> String {
        values.map(String.init).joined(separator: ", ")
    }

    private nonisolated static func isCancellation(_ error: any Error) -> Bool {
        switch error {
        case is CancellationError, ExportError.cancelled, GIFExportError.cancelled: true
        default: false
        }
    }

    /// What an export threw, as the API's error.
    private nonisolated static func exportError(_ error: any Error, codec: ExportCodec?) -> APIError {
        switch error {
        case let error as APIError:
            return error
        case let error as ExportPreparationError:
            return APIError(.exportFailed, "the \(error.stage.rawValue) could not be prepared: \(reason(error.underlying))")
        case ExportError.destinationNotAllowed:
            return APIError(.refused, "the export cannot be written there: a folder, a link, or inside a project")
        case let ExportError.editorFilesExist(files):
            let names = files.map(\.lastPathComponent).joined(separator: " and ")
            return APIError(
                .refused,
                "\(names) \(files.count == 1 ? "is" : "are") already next to the video and would be replaced: export again "
                    + "asking to replace them (toma export --fcpxml --replace, or export_fcpxml with replace: true), or "
                    + "choose another output; nothing was written")
        case ExportError.nothingToExport, GIFExportError.rangeShorterThanAFrame:
            return APIError(.outOfRange, "the output lasts less than a frame: there is nothing to export")
        case ExportError.unsupportedCodec:
            // No exporter throws it since milestone 4c (the alpha codecs are written); a codec a later one refuses.
            let name = codec.map(ExportRequest.name(of:)) ?? "the codec"
            return APIError(.notAvailable, "this version of Toma does not export \(name) yet")
        case ExportError.diskFull, GIFExportError.diskFull:
            return APIError(.exportFailed, "the disk is full")
        case ExportError.noDisplayTrack:
            return APIError(.exportFailed, "the take recorded no screen: there is nothing to show")
        case let ExportError.writerFailed(why):
            return APIError(.exportFailed, "the file could not be written: \(why)")
        case let GIFExportError.write(code):
            return APIError(.exportFailed, "the GIF could not be written: \(String(cString: strerror(code.rawValue)))")
        case let error as RenderError:
            return APIError(.exportFailed, "a frame could not be drawn: \(error)")
        default:
            return APIError(.exportFailed, "the export failed: \(error)")
        }
    }

    /// Why a stage of the preparation failed, in words.
    private nonisolated static func reason(_ error: any Error) -> String {
        guard let error = error as? JobError else { return String(describing: error) }
        return switch error.problem {
        case .needsMacOS26: "it needs macOS 26"
        case let .modelNotInstalled(locale): "the model of \(locale) is not on this Mac"
        case .notOnThisMac: "this Mac cannot do it"
        case let .sourceUnreadable(file): "\(file) cannot be read"
        case .noSpace: "the disk is full"
        case let .failed(why): why
        }
    }
}
