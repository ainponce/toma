// SPDX-License-Identifier: GPL-3.0-or-later
import Analysis
import Foundation
import ProjectFormat
import Synchronization
import os

/// Where a share is: exporting the video, or uploading. `fraction` is of the whole share, from 0 to 1, and only rises.
public struct ShareProgress: Equatable, Sendable {
    public enum Phase: Equatable, Sendable { case exporting, uploading }
    public var phase: Phase
    public var fraction: Double

    public init(phase: Phase, fraction: Double) {
        self.phase = phase
        self.fraction = fraction
    }
}

/// A whole share of a project, as the app and `toma` run it (plan 5a): check the settings and the secret, export the
/// video (each its own way, `MakeVideo`), make the poster, upload the three objects (`ShareService`) and remember the link
/// in the package's `shares.json`. Nothing is uploaded that `shares.json` cannot remember: it must be readable before the
/// export, and a link it then cannot record is removed from the storage.
public enum ShareJob {
    /// What the video to share is: H.264 of `outputSize` at `framesPerSecond`, the whole video, with `chapters` in the
    /// file; `documentHash` says whether an export already made can be reused.
    public struct VideoRequest: Equatable, Sendable {
        public var outputSize: SIMD2<Int>
        public var framesPerSecond: Int
        public var chapters: [Chapter]
        public var documentHash: String

        public init(outputSize: SIMD2<Int>, framesPerSecond: Int, chapters: [Chapter], documentHash: String) {
            self.outputSize = outputSize
            self.framesPerSecond = framesPerSecond
            self.chapters = chapters
            self.documentHash = documentHash
        }
    }

    /// Writes the video in `suggested` and returns it, or returns an export there already was (which is not removed).
    /// `progress` takes the export's fraction, 0 to 1.
    public typealias MakeVideo = @Sendable (
        VideoRequest, _ suggested: URL, _ progress: @escaping @Sendable (Double) -> Void
    ) async throws -> URL

    /// Exporting is the first half of the progress; with an export reused, the whole of it is the upload.
    public static let exportShare = 0.5

    private static let logger = Logger(subsystem: "dev.toma.Toma", category: "Share")

    /// Shares `inputs` of `package`: 1) the secret and the configuration, before anything (without a secret,
    /// `.notConfigured(.missingSecret)`), and `shares.json` must be readable (`.historyUnreadable`); 2) a temporary folder
    /// `Toma-share-<UUID>`; 3) `makeVideo`; 4) the poster; 5) the upload; 6) the record with `inputs.documentHash`; 7) the
    /// record added to `shares.json`, and if that fails the three objects are removed and it throws `.notSaved`. The
    /// temporary folder is always removed; a reused export, never.
    /// - Throws: a `ShareError` (`.cancelled` when the task is cancelled), a `SecretStoreError`, or what exporting or
    ///   making the poster throws.
    public static func run(
        package: ProjectPackage, inputs: ShareInputs, preferences: SharePreferences, secrets: any SecretStore,
        service: ShareService, makeVideo: MakeVideo,
        progress: @escaping @Sendable (ShareProgress) -> Void
    ) async throws -> ShareRecord {
        let secret = try configuredSecret(preferences, secrets: secrets)
        let history = ShareHistory(package: package)
        _ = try history.records()

        let folder = FileManager.default.temporaryDirectory.appending(
            path: "Toma-share-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let reporter = ProgressReporter(progress)

        let suggested = folder.appending(path: "video.mp4", directoryHint: .notDirectory)
        let poster = folder.appending(path: "poster.jpg", directoryHint: .notDirectory)
        let request = VideoRequest(
            outputSize: inputs.outputSize, framesPerSecond: inputs.framesPerSecond, chapters: inputs.chapters,
            documentHash: inputs.documentHash)
        let video: URL
        do {
            video = try await makeVideo(request, suggested) { fraction in
                reporter.report(.exporting, exportShare * fraction)
            }
            try Task.checkCancellation()
            _ = try await SharePoster.write(from: video, atOutput: inputs.posterTime, to: poster)
        } catch {
            throw ShareService.cancelledOr(error)
        }

        let reused = video.standardizedFileURL.path(percentEncoded: false)
            != suggested.standardizedFileURL.path(percentEncoded: false)
        let start = reused ? 0 : exportShare
        reporter.report(.uploading, start)
        var record = try await service.share(
            video: video, poster: poster, title: inputs.title, summary: inputs.summary, chapters: inputs.chapters,
            preferences: preferences, secret: secret,
            progress: { fraction in reporter.report(.uploading, start + (1 - start) * fraction) })
        record.documentHash = inputs.documentHash

        do {
            try history.append(record)
        } catch {
            // A link the project cannot list could never be deleted from it: it is removed, out of the cancellation's
            // reach.
            logger.error("Share \(record.folder, privacy: .public) not recorded; removing it")
            let removal = Task {
                try? await service.delete(record, preferences: preferences, secret: secret)
            }
            _ = await removal.value
            throw ShareError.notSaved
        }
        reporter.report(.uploading, 1)
        return record
    }

    /// Removes `record`'s objects from the storage and then its row from `shares.json`; if the storage fails, the row
    /// stays.
    /// - Throws: a `ShareError` (`.otherStorage` for a record of another storage, without connecting), a
    ///   `SecretStoreError`, or what removing the row throws.
    public static func delete(
        _ record: ShareRecord, package: ProjectPackage, preferences: SharePreferences, secrets: any SecretStore,
        service: ShareService
    ) async throws {
        let secret = try configuredSecret(preferences, secrets: secrets)
        try await service.delete(record, preferences: preferences, secret: secret)
        try ShareHistory(package: package).remove(id: record.id)
    }

    /// The secret of `preferences` (`SharePreferences.secretAccount`), once they make a configuration with it.
    /// - Throws: `.notConfigured` with the first problem of the settings, `.missingSecret` without a secret; a
    ///   `SecretStoreError`.
    static func configuredSecret(_ preferences: SharePreferences, secrets: any SecretStore) throws -> String {
        let account = preferences.secretAccount
        let secret = account.isEmpty ? nil : try secrets.secret(for: account)
        let problems = ShareConfiguration.problems(in: preferences, hasSecret: !(secret ?? "").isEmpty)
        if let problem = problems.first { throw ShareError.notConfigured(problem) }
        guard let secret, !secret.isEmpty else { throw ShareError.notConfigured(.missingSecret) }
        return secret
    }
}

/// Reports a share's progress only rising, and never back from uploading to exporting (an export's late report).
private final class ProgressReporter: Sendable {
    private let callback: @Sendable (ShareProgress) -> Void
    private let last = Mutex<ShareProgress?>(nil)

    init(_ callback: @escaping @Sendable (ShareProgress) -> Void) { self.callback = callback }

    /// Called under the lock so two reports never arrive out of order.
    func report(_ phase: ShareProgress.Phase, _ fraction: Double) {
        last.withLock { last in
            if last?.phase == .uploading && phase == .exporting { return }
            let fraction = max(min(fraction.isFinite ? fraction : 0, 1), last?.fraction ?? 0)
            if let last, last.phase == phase && fraction <= last.fraction { return }
            let progress = ShareProgress(phase: phase, fraction: fraction)
            last = progress
            callback(progress)
        }
    }
}
