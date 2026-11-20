// SPDX-License-Identifier: GPL-3.0-or-later
import Editing
import Foundation
import ImageAnalysis
import ProjectFormat

/// The analysis job of `sensitiveScan-1` on a take (`AnalysisJobKind.sensitiveScan(take:)`, design §7.2 and §10): its
/// cache (`ProjectCaches.scanFile`, plan decision 7) and the work that makes it.
///
/// The cache holds while what a scan would look at is what it looked at: the same algorithm and version, the same take,
/// the same bytes of every screen segment of the take (`segmentNames`) and the same frames of them (the document picks
/// which screen is shown when: `SensitiveScan.fingerprint`). Its texts are masked; the found text is never written.
public enum SensitiveScanJob {
    /// The take of each job of a search of `document` (phase 3 design §8.1): `project` focused on each take its sequence
    /// shows (`LoadedProject.takesShown(by:)`), each once, in the order the sequence first shows them; none for an empty
    /// sequence. Each is scanned on its own (`work`, `cached`), as the take it is.
    public static func projects(of project: LoadedProject, shownBy document: EditDocument) -> [LoadedProject] {
        guard !document.sequence.isEmpty else { return [] }
        return project.takesShown(by: document)
    }

    /// The cached result for `project`'s take as `document` shows it, if it holds (see above); `nil` otherwise, and when
    /// there is none or it cannot be read. Reads the cache file, the segments' identities and the take's events: never on
    /// the main thread.
    public static func cached(project: LoadedProject, document: EditDocument, caches: ProjectCaches) -> ScanResult? {
        guard let url = file(for: project, in: caches), let data = ProjectCaches.readAnalysis(url),
              let result = try? ProjectJSON.decoder().decode(ScanResult.self, from: data),
              result.algorithm == SensitiveScan.algorithm, result.version == ScanResult.currentVersion,
              result.take == project.take.id,
              result.segments == segmentNames(of: project.take, in: project.package),
              result.samples == SensitiveScan.fingerprint(project: project, document: document)
        else { return nil }
        return result
    }

    /// The work of the job: with a cache that holds, `.cached(url)` without looking at a frame; otherwise the scan, its
    /// result written whole to the cache (`ProjectCaches.writeAnalysis`), and `.cached(url)`.
    ///
    /// `recognizer` is Vision's (`VisionRecognizer`) unless a test hands in another. Throws `JobError(.notOnThisMac,
    /// unavailable: true)` when it cannot look on this Mac, `JobError(.sourceUnreadable(file:))` for a segment that is
    /// there but cannot be decoded, `CancellationError` once cancelled (nothing written), and `JobError(.failed)` when the
    /// cache cannot be written.
    public static func work(
        project: LoadedProject, document: EditDocument, caches: ProjectCaches, recognizer: (any ScreenRecognizer)? = nil
    ) -> JobWork {
        { progress in
            guard let url = file(for: project, in: caches) else {
                throw JobError(.failed("The take's name cannot name a cache file"))
            }
            // Off Swift's pool: it reads the take's events, which can take a while for a long take.
            let holds = await offThePool { cached(project: project, document: document, caches: caches) != nil }
            if holds {
                progress.report(1)
                return .cached(url)
            }
            let recognizer = recognizer ?? VisionRecognizer()
            guard recognizer.isAvailable else { throw JobError(.notOnThisMac, unavailable: true) }
            // Before the first frame is read: a segment written again meanwhile makes the result stale.
            let segments = segmentNames(of: project.take, in: project.package)
            let result: ScanResult
            do {
                result = try await SensitiveScan.run(
                    project: project, document: document, recognizer: recognizer, segments: segments,
                    progress: { progress.report($0) })
            } catch SensitiveScanError.unreadable(let file) {
                throw JobError(.sourceUnreadable(file: file))
            }
            try Task.checkCancellation()
            let data = try ProjectJSON.encoder().encode(result)
            guard ProjectCaches.writeAnalysis(data, to: url) else {
                try Task.checkCancellation()
                throw JobError(.failed("The scan's cache could not be written"))
            }
            return .cached(url)
        }
    }

    /// The identity of every segment of the take's screen tracks (`TrackKind.isScreen`), in the manifest's order:
    /// `<track>/<SegmentIdentity.name>`, or `<track>/<file name>` for one with no identity (no file, a link): what a
    /// cached result was made from. Reads each segment's `lstat`.
    public static func segmentNames(of take: TakeRecord, in package: ProjectPackage) -> [String] {
        take.tracks.filter(\.kind.isScreen).flatMap { track in
            track.segments.map { segment in
                let name = SegmentIdentity.of(segment, in: package)?.name
                    ?? URL(filePath: segment.file).deletingPathExtension().lastPathComponent
                return "\(track.id)/\(name)"
            }
        }
    }

    /// `body`'s value, made on a utility queue.
    private static func offThePool<T: Sendable>(_ body: @escaping @Sendable () -> T) async -> T {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .utility).async { continuation.resume(returning: body()) }
        }
    }

    private static func file(for project: LoadedProject, in caches: ProjectCaches) -> URL? {
        caches.scanFile(take: project.take.id, algorithm: SensitiveScan.algorithm)
    }
}
