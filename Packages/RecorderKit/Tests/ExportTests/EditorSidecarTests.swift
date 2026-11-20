// SPDX-License-Identifier: GPL-3.0-or-later
import AVFoundation
@testable import Export
import Foundation
import ProjectFormat
import RecorderKitTestSupport
import Render
import Synchronization
import Testing

// The files for external editors next to the exported video (phases 4 and 5 design §7.2, plan 4c decision 8): with
// `ExportSettings.editorMetadata`, the export of the whole video writes `<name>.fcpxml` and `<name>.toma-metadata.json`
// next to it, the bytes `ExternalEditorExport.write` makes of the finished video, worked out before the video is moved
// into place and written once it is there; never for a range, never unless asked, and nothing left when cancelled.

private func at(_ seconds: Double) -> HostTime { base.adding(seconds: seconds) }

/// A take of 2 s in `dir/Demo.toma`: display 1 (640 × 360) and the microphone, the cursor moving across the display, a
/// click at 0.8 s and a recorded marker at 0.5 s.
private func sidecarTake(in dir: URL) async throws -> LoadedProject {
    let builder = try TakeBuilder(in: dir, name: "Demo")
    try await builder.addVideoTrack(id: displayID, source: displaySource, segments: [VideoSegmentSpec(start: base, seconds: 2)])
    try await builder.addAudioTrack(id: micID, source: micSource, segments: [AudioSegmentSpec(start: base, seconds: 2)])
    try builder.addEvents((0..<240).map { i in
        InputEvent(t: at(Double(i) / 120), kind: .cursor(x: 40 + 2.4 * Double(i), y: 60 + Double(i)))
    })
    try builder.addEvents([
        InputEvent(t: at(0.8), kind: .mouseDown(.left, x: 200, y: 100)), InputEvent(t: at(0.9), kind: .mouseUp(.left, x: 200, y: 100)),
        InputEvent(t: at(0.5), kind: .marker),
    ])
    return try builder.write()
}

/// 320 × 180 at 30 fps with `codec`, asking for the files for editors unless `editorMetadata` is `false`.
private func settings(_ codec: ExportCodec = .h264, editorMetadata: Bool = true) -> ExportSettings {
    ExportSettings(outputSize: [320, 180], framesPerSecond: 30, codec: codec, editorMetadata: editorMetadata)
}

private func exists(_ url: URL) -> Bool { FileManager.default.fileExists(atPath: url.path) }

/// The names `ExportError.editorFilesExist` gives, if `error` is it.
private func namesThere(_ error: ExportError?) -> [String]? {
    guard case let .editorFilesExist(urls)? = error else { return nil }
    return urls.map(\.lastPathComponent)
}

/// The names in `dir`, without the project's package.
private func files(in dir: URL) throws -> Set<String> {
    Set(try FileManager.default.contentsOfDirectory(atPath: dir.path).filter { !$0.hasSuffix(".toma") })
}

@Suite(.enabled(if: MetalCondition.isAvailable || MetalCondition.isRequired))
struct EditorSidecarTests {
    /// With `editorMetadata`, the export leaves `<name>.fcpxml` and `<name>.toma-metadata.json` next to the video: the
    /// bytes `ExternalEditorExport.write` makes of the finished video (so the facts the exporter knows are the ones the
    /// file says, its alpha among them), naming the destination and never the partial file.
    @Test(arguments: [ExportCodec.h264, .hevcAlpha, .proRes4444])
    func editorMetadataWritesBothFilesNextToTheVideo(codec: ExportCodec) async throws {
        try await withTemporaryDirectory { dir in
            let project = try await sidecarTake(in: dir)
            let document = EditDocument.legacy(for: project)
            let destination = dir.appending(path: "Demo export.\(codec.fileExtension)")
            let progress = Mutex<[Double]>([])
            try await MP4Exporter(project: project, document: document, settings: settings(codec)).export(to: destination) { value in
                progress.withLock { $0.append(value) }
            }
            #expect(progress.withLock { $0.last } == 1)
            let sidecars = ExternalEditorExport.sidecarURLs(of: destination)
            #expect(sidecars.fcpxml.lastPathComponent == "Demo export.fcpxml")
            #expect(sidecars.metadata.lastPathComponent == "Demo export.toma-metadata.json")
            #expect(try files(in: dir) == ["Demo export.\(codec.fileExtension)", "Demo export.fcpxml", "Demo export.toma-metadata.json"])
            let fcpxml = try Data(contentsOf: sidecars.fcpxml), metadata = try Data(contentsOf: sidecars.metadata)

            // What `write` makes of the finished video, written elsewhere.
            let again = (fcpxml: dir.appending(path: "again.fcpxml"), metadata: dir.appending(path: "again.json"))
            try await offThePool { [settings = settings(codec)] in
                try ExternalEditorExport.write(
                    project: project, document: document, video: destination, settings: settings, fcpxml: again.fcpxml,
                    metadata: again.metadata)
            }
            #expect(try Data(contentsOf: again.fcpxml) == fcpxml)
            #expect(try Data(contentsOf: again.metadata) == metadata)

            let xml = String(decoding: fcpxml, as: UTF8.self), json = String(decoding: metadata, as: UTF8.self)
            #expect(xml.contains("src=\"\(destination.absoluteString)\""), "the FCPXML names the destination")
            #expect(!xml.contains("partial") && !json.contains("partial"))
            #expect(json.contains("\"file\":\"Demo export.\(codec.fileExtension)\""))
            #expect(json.contains("\"alpha\":\(codec.hasAlpha)"))
            #expect(json.contains("\"frames\":60"))
            #expect(try partialFiles(in: dir).isEmpty)
        }
    }

    /// The files describe the whole video only: with a range of the output, `editorMetadata` is ignored and nothing but
    /// the video is written; the range of all of it is the whole video, and has them.
    @Test func editorMetadataIsOnlyForTheWholeVideo() async throws {
        try await withTemporaryDirectory { dir in
            let project = try await sidecarTake(in: dir)
            let document = EditDocument.legacy(for: project)
            let part = dir.appending(path: "part.mp4")
            try await MP4Exporter(
                project: project, document: document, settings: settings(), range: ExportRange(start: 500_000_000, end: 1_500_000_000)
            ).export(to: part) { _ in }
            #expect(try files(in: dir) == ["part.mp4"])

            let whole = dir.appending(path: "whole.mp4")
            try await MP4Exporter(
                project: project, document: document, settings: settings(), range: .whole(TimeMap(sequence: document.sequence))
            ).export(to: whole) { _ in }
            #expect(try files(in: dir) == ["part.mp4", "whole.mp4", "whole.fcpxml", "whole.toma-metadata.json"])
        }
    }

    /// Unless asked, an export writes the video alone, as before 4c: `editorMetadata` is `false` by default.
    @Test func opaqueExportWritesNoSidecarsByDefault() async throws {
        #expect(!ExportSettings().editorMetadata)
        #expect(!ExportSettings(aspect: .landscape, resolution: .p720, framesPerSecond: 30, quality: .standard).editorMetadata)
        try await withTemporaryDirectory { dir in
            let project = try await sidecarTake(in: dir)
            let destination = dir.appending(path: "out.mp4")
            try await MP4Exporter(project: project, settings: ExportSettings(outputSize: [320, 180], framesPerSecond: 30))
                .export(to: destination) { _ in }
            #expect(try files(in: dir) == ["out.mp4"])
        }
    }

    /// A file for editors that could not be written where it goes (a folder there, or the video's own name) refuses the
    /// export before anything is written, as a destination that cannot be does.
    @Test func sidecarsThatCannotBeWrittenAreRefusedFirst() async throws {
        try await withTemporaryDirectory { dir in
            let project = try await sidecarTake(in: dir)
            try FileManager.default.createDirectory(at: dir.appending(path: "out.fcpxml"), withIntermediateDirectories: false)
            for name in ["out.mp4", "clash.fcpxml"] {
                let destination = dir.appending(path: name)
                await #expect(throws: ExportError.destinationNotAllowed, "\(name)") {
                    try await MP4Exporter(project: project, document: .legacy(for: project), settings: settings())
                        .export(to: destination) { _ in }
                }
            }
            #expect(try files(in: dir) == ["out.fcpxml"])
            // Without asking for them, the same export writes.
            try await MP4Exporter(project: project, document: .legacy(for: project), settings: settings(editorMetadata: false))
                .export(to: dir.appending(path: "out.mp4")) { _ in }
            #expect(try files(in: dir) == ["out.fcpxml", "out.mp4"])
        }
    }

    /// Files of the names of the files for editors already next to the video are never replaced unless the export is told
    /// it may (`replacesEditorFiles`, the sheet's Replace): otherwise it throws `editorFilesExist` naming them, before it
    /// writes anything. Told, it replaces them; without `editorMetadata`, they are not touched.
    @Test func existingEditorFilesAreNotReplacedUnlessAsked() async throws {
        try await withTemporaryDirectory { dir in
            let project = try await sidecarTake(in: dir)
            let destination = dir.appending(path: "out.mp4")
            let sidecars = ExternalEditorExport.sidecarURLs(of: destination)
            let mine = Data("<fcpxml version=\"1.10\"/> from Final Cut".utf8)
            try mine.write(to: sidecars.fcpxml)
            let refused = await #expect(throws: ExportError.self) {
                try await MP4Exporter(project: project, document: .legacy(for: project), settings: settings())
                    .export(to: destination) { _ in }
            }
            #expect(namesThere(refused) == ["out.fcpxml"], "\(String(describing: refused))")
            #expect(try files(in: dir) == ["out.fcpxml"])
            #expect(try Data(contentsOf: sidecars.fcpxml) == mine)
            // Only the JSON there: it alone is named.
            try FileManager.default.removeItem(at: sidecars.fcpxml)
            try Data("{}".utf8).write(to: sidecars.metadata)
            let json = await #expect(throws: ExportError.self) {
                try await MP4Exporter(project: project, document: .legacy(for: project), settings: settings())
                    .export(to: destination) { _ in }
            }
            #expect(namesThere(json) == ["out.toma-metadata.json"], "\(String(describing: json))")
            #expect(try files(in: dir) == ["out.toma-metadata.json"])
            try mine.write(to: sidecars.fcpxml)

            // Without the files for editors, the video alone, and they stay as they are.
            try await MP4Exporter(project: project, document: .legacy(for: project), settings: settings(editorMetadata: false))
                .export(to: destination) { _ in }
            #expect(try Data(contentsOf: sidecars.fcpxml) == mine && Data(contentsOf: sidecars.metadata) == Data("{}".utf8))

            // Told it may, it replaces both.
            var replacing = settings()
            replacing.replacesEditorFiles = true
            try await MP4Exporter(project: project, document: .legacy(for: project), settings: replacing).export(to: destination) { _ in }
            #expect(try Data(contentsOf: sidecars.fcpxml) != mine)
            #expect(String(decoding: try Data(contentsOf: sidecars.fcpxml), as: UTF8.self).contains("<fcpxml version=\"1.11\">"))
            #expect(String(decoding: try Data(contentsOf: sidecars.metadata), as: UTF8.self).contains("\"format\":\"metadata-1\""))
            #expect(try files(in: dir) == ["out.mp4", "out.fcpxml", "out.toma-metadata.json"])
            #expect(!ExportSettings().replacesEditorFiles)
            #expect(!ExportSettings(aspect: .landscape, resolution: .p720, framesPerSecond: 30, quality: .standard).replacesEditorFiles)
        }
    }

    /// A file of their names that appears while the video is encoded is not replaced either: the export looks again right
    /// before the video goes into place, throws `editorFilesExist`, and leaves the destination as it was.
    @Test func editorFilesThatAppearMeanwhileAreNotReplaced() async throws {
        try await withTemporaryDirectory { dir in
            let project = try await sidecarTake(in: dir)
            let destination = dir.appending(path: "out.mp4")
            try Data("before".utf8).write(to: destination)
            let sidecars = ExternalEditorExport.sidecarURLs(of: destination)
            let mine = Data("made meanwhile".utf8)
            let exporter = MP4Exporter(
                project: project, document: .legacy(for: project), settings: settings(), frameSink: nil,
                whileSampling: { try? mine.write(to: sidecars.metadata) })
            let appeared = await #expect(throws: ExportError.self) { try await exporter.export(to: destination) { _ in } }
            #expect(namesThere(appeared) == ["out.toma-metadata.json"], "\(String(describing: appeared))")
            #expect(try Data(contentsOf: destination) == Data("before".utf8))
            #expect(try Data(contentsOf: sidecars.metadata) == mine)
            #expect(try files(in: dir) == ["out.mp4", "out.toma-metadata.json"])
        }
    }

    /// `ExternalEditorExport.write` from async code runs off the cooperative pool and is cancelled with its task: nothing
    /// is written; not cancelled, it writes what the synchronous `write` does.
    @Test func asyncWriteIsCancelledWithItsTask() async throws {
        try await withTemporaryDirectory { dir in
            let project = try await sidecarTake(in: dir)
            let document = EditDocument.legacy(for: project)
            let video = dir.appending(path: "out.mp4")
            try await MP4Exporter(project: project, document: document, settings: settings(editorMetadata: false))
                .export(to: video) { _ in }
            let (fcpxml, metadata) = ExternalEditorExport.sidecarURLs(of: video)
            let task = Task {
                withUnsafeCurrentTask { $0?.cancel() }
                try await ExternalEditorExport.write(
                    project: project, document: document, video: video, settings: settings(), fcpxml: fcpxml, metadata: metadata)
            }
            await #expect(throws: ExportError.cancelled) { try await task.value }
            #expect(try files(in: dir) == ["out.mp4"])

            try await ExternalEditorExport.write(
                project: project, document: document, video: video, settings: settings(), fcpxml: fcpxml, metadata: metadata)
            let again = (fcpxml: dir.appending(path: "again.fcpxml"), metadata: dir.appending(path: "again.json"))
            try await offThePool {
                try ExternalEditorExport.write(
                    project: project, document: document, video: video, settings: settings(), fcpxml: again.fcpxml,
                    metadata: again.metadata)
            }
            #expect(try Data(contentsOf: fcpxml) == Data(contentsOf: again.fcpxml))
            #expect(try Data(contentsOf: metadata) == Data(contentsOf: again.metadata))
        }
    }

    /// Cancelled while it samples the frames for the files (after the video is encoded, before it is moved into place),
    /// the export throws `cancelled` and leaves the destination as it was: no partial file and neither file for editors.
    @Test(.timeLimit(.minutes(5)))
    func cancelledWhileTheFilesAreMadeLeavesNothing() async throws {
        try await withTemporaryDirectory { dir in
            let project = try await sidecarTake(in: dir)
            let destination = dir.appending(path: "out.mp4")
            try Data("before".utf8).write(to: destination)
            let (reached, reachedContinuation) = AsyncStream.makeStream(of: Void.self)
            let cancelled = DispatchSemaphore(value: 0)
            let looks = Mutex(0)
            let encoded = Mutex(0)
            let exporter = MP4Exporter(
                project: project, document: .legacy(for: project), settings: settings(),
                frameSink: { _, _ in encoded.withLock { $0 += 1 } },
                whileSampling: {
                    // The sampling looks at the cancellation first: it waits there until the task is cancelled.
                    let first = looks.withLock { looks in
                        defer { looks += 1 }
                        return looks == 0
                    }
                    if first {
                        reachedContinuation.yield()
                        cancelled.wait()
                    }
                })
            let task = Task {
                defer { reachedContinuation.finish() }
                try await exporter.export(to: destination) { _ in }
            }
            for await _ in reached { break }
            #expect(encoded.withLock { $0 } == 60, "the video was encoded before the files are made")
            task.cancel()
            cancelled.signal()
            await #expect(throws: ExportError.cancelled) { try await task.value }
            #expect(looks.withLock { $0 } == 1, "the sampling stopped at the first look")
            #expect(try Data(contentsOf: destination) == Data("before".utf8))
            #expect(try files(in: dir) == ["out.mp4"])
        }
    }
}
