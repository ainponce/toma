// SPDX-License-Identifier: GPL-3.0-or-later
import Darwin
import Foundation
import ProjectFormat
import os

/// The files for external editors (phases 4 and 5 design §7.2, plan 4c decisions 8 to 11), next to an exported video:
/// `<name>.fcpxml`, FCPXML 1.11 for Final Cut Pro or DaVinci Resolve (`FCPXMLWriter`), and `<name>.toma-metadata.json`,
/// `metadata-1` for After Effects, Motion or a script (`EditorMetadataFile`). Both come from one `EditorTimeline`: the
/// frames as the renderer draws them (the cursor and the zoom camera in the video's pixels), the clicks, the zoom blocks,
/// the markers, the chapters and the kept source ranges, every time on the video's frames.
///
/// They describe the export of the whole document: a video of a range, of another size or frame rate, is refused
/// (`ExportError.writerFailed`), so the files never describe another video than the one they name. Nothing here writes
/// into a project (`MP4Exporter.canonicalDestination`).
public enum ExternalEditorExport {
    public static let fcpxmlVersion = "1.11"
    public static let metadataID = "metadata-1"

    private static let logger = Logger(subsystem: "dev.toma.Toma", category: "ExternalEditorExport")

    /// `<base>.fcpxml` and `<base>.toma-metadata.json` next to `video`, `<base>` its name without its extension.
    public static func sidecarURLs(of video: URL) -> (fcpxml: URL, metadata: URL) {
        let folder = video.deletingLastPathComponent(), base = video.deletingPathExtension().lastPathComponent
        return (
            folder.appendingPathComponent(base + ".fcpxml", isDirectory: false),
            folder.appendingPathComponent(base + ".toma-metadata.json", isDirectory: false)
        )
    }

    /// Writes the FCPXML to `fcpxml` and `metadata-1` to `metadata` for `video`, the export of the whole of `document` of
    /// `project` with `settings` (its size, frames per second, chapters and their language), reading the video's size,
    /// frame rate, frames and audio from the file (`VideoFacts.read`). Each file is replaced atomically
    /// (`DurableFile.writeAtomically`), the FCPXML first; if the metadata cannot be written, the FCPXML just written is
    /// removed, so it is both files or neither (one already there before is gone then).
    ///
    /// Samples every frame of the video (`EditorTimeline`) and waits for AVFoundation to load the video: never on the main
    /// thread, nor on a Swift concurrency thread (hop off it, as `MP4Exporter` does with its own queue). The task it runs
    /// in, if any, cancels it between two frames.
    /// - Throws: `ExportError`, before anything is written: `destinationNotAllowed` for a destination inside a `.toma`
    ///   package, a folder, or one of the other two files (the video included); `nothingToExport` for a document that lasts
    ///   no time; `writerFailed` for a video AVFoundation cannot read, or that is not this export's (another size or frame
    ///   rate, or frames that differ by more than one from `TimeMap.frameCount(frameRate:)`: the video of a range);
    ///   `cancelled`. Then `diskFull` or `writerFailed` from writing a file.
    public static func write(
        project: LoadedProject, document: EditDocument, video: URL, settings: ExportSettings, fcpxml: URL, metadata: URL
    ) throws {
        guard let fcpxml = MP4Exporter.canonicalDestination(fcpxml, project: project.package),
              let metadata = MP4Exporter.canonicalDestination(metadata, project: project.package)
        else { throw ExportError.destinationNotAllowed }
        // Never one file twice, nor the video (compared without case, as APFS usually does).
        let movie = (MP4Exporter.canonicalDestination(video, project: project.package) ?? video.standardizedFileURL).path.lowercased()
        let paths = [fcpxml.path.lowercased(), metadata.path.lowercased(), movie]
        guard Set(paths).count == paths.count else { throw ExportError.destinationNotAllowed }
        guard TimeMap(sequence: document.sequence).duration > 0 else { throw ExportError.nothingToExport }
        let facts = try VideoFacts.read(video)
        let written = try files(project: project, document: document, video: facts, settings: settings) { Task.isCancelled }
        try store(written, fcpxml: fcpxml, metadata: metadata)
    }

    /// Replaces `fcpxml` and `metadata` (canonical paths) with `written`'s bytes, each atomically, the FCPXML first; if the
    /// metadata cannot be written, the FCPXML just written is removed, so it is both files or neither. `write` and
    /// `MP4Exporter` (with `ExportSettings.editorMetadata`) store them this way.
    /// - Throws: `ExportError.diskFull` when the disk is full, `writerFailed` for any other failure.
    static func store(_ written: (fcpxml: Data, metadata: Data), fcpxml: URL, metadata: URL) throws {
        try store(written.fcpxml, at: fcpxml)
        do {
            try store(written.metadata, at: metadata)
        } catch {
            if unlink(fcpxml.path) != 0 {
                logger.error("Cannot remove \(fcpxml.path, privacy: .public): \(String(cString: strerror(errno)), privacy: .public)")
            }
            throw error
        }
    }

    /// Both files' bytes, for a video `video` describes (X3 passes what it wrote; `write` reads the file): the FCPXML in
    /// an event named after the project's package and a project named after the video, its labels in
    /// `settings.chapterLanguage`; `metadata-1` with the video's name, size, frame rate, frames and alpha.
    /// - Throws: `ExportError.nothingToExport` for a document that lasts no time; `writerFailed` for a frame rate that is not
    ///   positive and a video that is not the whole export of `document` with `settings` (`write`); `cancelled` once
    ///   `isCancelled` says so, looked at every `EditorTimeline.cancelCheckEvery` frames.
    static func files(
        project: LoadedProject, document: EditDocument, video: VideoFacts, settings: ExportSettings,
        isCancelled: () -> Bool = { false }
    ) throws -> (fcpxml: Data, metadata: Data) {
        let timeMap = TimeMap(sequence: document.sequence)
        guard timeMap.duration > 0 else { throw ExportError.nothingToExport }
        let fps = settings.framesPerSecond
        guard fps > 0 else { throw ExportError.writerFailed("the frame rate must be positive, not \(fps)") }
        let expected = timeMap.frameCount(frameRate: fps)
        guard video.size == settings.outputSize, video.frameRate == fps, abs(video.frameCount - expected) <= 1 else {
            throw ExportError.writerFailed(
                "\(video.url.lastPathComponent) (\(video.size.x)×\(video.size.y), \(video.frameRate) fps, \(video.frameCount) frames) "
                    + "is not the whole export (\(settings.outputSize.x)×\(settings.outputSize.y), \(fps) fps, \(expected) frames)")
        }
        let timeline = try EditorTimeline.make(
            project: project, document: document, settings: settings, frameCount: video.frameCount, isCancelled: isCancelled)
        let fcpxml = FCPXMLWriter.document(
            timeline, video: video, event: project.package.url.deletingPathExtension().lastPathComponent,
            project: video.url.deletingPathExtension().lastPathComponent, language: settings.chapterLanguage)
        do {
            return (fcpxml, try EditorMetadataFile.data(timeline, video: video))
        } catch {
            throw ExportError.writerFailed("cannot encode \(metadataID): \(error)")
        }
    }

    /// Replaces `url` with `data` atomically: `diskFull` when the disk is, `writerFailed` for any other failure.
    private static func store(_ data: Data, at url: URL) throws {
        do {
            try DurableFile.writeAtomically(data, to: url)
        } catch {
            if ExportError.isDiskFull(error) { throw ExportError.diskFull }
            throw ExportError.writerFailed("cannot write \(url.path): \(error)")
        }
    }
}
