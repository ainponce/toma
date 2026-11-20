// SPDX-License-Identifier: GPL-3.0-or-later
import Analysis
import Foundation
import ProjectFormat
import RecorderKitTestSupport
@testable import Sharing
import Synchronization
import Testing

// The whole share (plan 5a): the settings and the secret before exporting, the export (or one reused), the poster, the
// upload and the row in `shares.json`; nothing stays shared that the project cannot list; deleting removes the objects
// and then the row.

private let hash = String(repeating: "cd", count: 32)
private let inputs = ShareInputs(
    title: "Demo", summary: nil, chapters: [Chapter(start: 0, title: "Intro")], posterTime: 1_000_000_000,
    outputSize: [320, 180], framesPerSecond: 30, documentHash: hash)

/// A project's folder, a package's `shares.json` and a clip that stands for the export.
private struct Project {
    let package: ProjectPackage
    let clip: URL
    var shares: URL { package.url.appending(path: ShareHistory.fileName) }

    init(in dir: URL) throws {
        let url = dir.appending(path: "Demo.toma", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false)
        package = ProjectPackage(url: url)
        clip = try MediaFixtures.clip(in: dir, seconds: 2, size: [320, 180], pattern: 0)
    }
}

/// A `MakeVideo` that exports by copying the clip to `suggested`, reporting a quarter, a half and all of it; what it was
/// asked and where, kept.
private final class FakeExport: Sendable {
    let clip: URL
    let reuse: Bool
    let requests = Mutex<[(ShareJob.VideoRequest, URL)]>([])
    let before: @Sendable () throws -> Void

    init(clip: URL, reuse: Bool = false, before: @escaping @Sendable () throws -> Void = {}) {
        self.clip = clip
        self.reuse = reuse
        self.before = before
    }

    var calls: Int { requests.withLock { $0.count } }
    var suggested: URL? { requests.withLock { $0.first?.1 } }

    var makeVideo: ShareJob.MakeVideo {
        { request, suggested, progress in
            self.requests.withLock { $0.append((request, suggested)) }
            try self.before()
            if self.reuse { return self.clip }
            for fraction in [0.25, 0.5, 1] { progress(fraction) }
            try FileManager.default.copyItem(at: self.clip, to: suggested)
            return suggested
        }
    }
}

private func service(_ fake: FakeS3, ids: [String] = ["k3m7q2x4za"]) -> ShareService {
    let next = Mutex(0)
    return ShareService(
        session: fake.session, now: { Date(timeIntervalSince1970: 1_795_000_000) },
        makeID: { next.withLock { n in defer { n += 1 }; return ids[min(n, ids.count - 1)] } }, pause: { _ in })
}

private let secrets = InMemorySecretStore([FakeS3.accessKeyID: FakeS3.secret])

private func run(
    _ project: Project, _ fake: FakeS3, _ export: FakeExport, preferences: SharePreferences? = nil,
    secrets store: any SecretStore = secrets, ids: [String] = ["k3m7q2x4za"],
    progress: @escaping @Sendable (ShareProgress) -> Void = { _ in }
) async throws -> ShareRecord {
    try await ShareJob.run(
        package: project.package, inputs: inputs, preferences: preferences ?? fake.preferences(), secrets: store,
        service: service(fake, ids: ids), makeVideo: export.makeVideo, progress: progress)
}

private func shareError(_ body: () async throws -> Void) async -> ShareError? {
    do {
        try await body()
        return nil
    } catch let error as ShareError {
        return error
    } catch {
        Issue.record("Not a ShareError: \(error)")
        return nil
    }
}

@Suite struct ShareJobTests {
    @Test func jobExportsUploadsAndRemembers() async throws {
        let fake = FakeS3()
        let reported = Mutex<[ShareProgress]>([])
        try await withTemporaryDirectory { dir in
            let project = try Project(in: dir)
            let export = FakeExport(clip: project.clip)
            let record = try await run(project, fake, export, progress: { p in reported.withLock { $0.append(p) } })

            #expect(record.documentHash == hash)
            #expect(try ShareHistory(package: project.package).records() == [record])
            let request = try #require(export.requests.withLock { $0.first?.0 })
            #expect(request == ShareJob.VideoRequest(
                outputSize: [320, 180], framesPerSecond: 30, chapters: inputs.chapters, documentHash: hash))
            // The export, uploaded; its temporary folder, gone.
            #expect(fake.object(at: "/bucket/toma/k3m7q2x4za/video.mp4")?.data == (try Data(contentsOf: project.clip)))
            let poster = try #require(fake.object(at: "/bucket/toma/k3m7q2x4za/poster.jpg"))
            #expect(poster.data.prefix(2) == Data([0xFF, 0xD8]))
            let folder = try #require(export.suggested).deletingLastPathComponent()
            #expect(folder.lastPathComponent.hasPrefix("Toma-share-"))
            #expect(!FileManager.default.fileExists(atPath: folder.path))
            // `shares.json` never holds the secret.
            #expect((try Data(contentsOf: project.shares)).range(of: Data(FakeS3.secret.utf8)) == nil)
        }
        let progress = reported.withLock { $0 }
        #expect(progress.first?.phase == .exporting)
        #expect(progress.contains(ShareProgress(phase: .exporting, fraction: ShareJob.exportShare)))
        let firstUpload = try #require(progress.firstIndex { $0.phase == .uploading })
        #expect(progress[firstUpload...].allSatisfy { $0.phase == .uploading })
        #expect(zip(progress, progress.dropFirst()).allSatisfy { $0.fraction <= $1.fraction })
        #expect(progress.last == ShareProgress(phase: .uploading, fraction: 1))
    }

    @Test func aReusedExportIsUploadedAndKept() async throws {
        let fake = FakeS3()
        let reported = Mutex<[ShareProgress]>([])
        try await withTemporaryDirectory { dir in
            let project = try Project(in: dir)
            let export = FakeExport(clip: project.clip, reuse: true)
            let record = try await run(project, fake, export, progress: { p in reported.withLock { $0.append(p) } })
            #expect(fake.object(at: "/bucket/toma/k3m7q2x4za/video.mp4")?.data == (try Data(contentsOf: project.clip)))
            #expect(FileManager.default.fileExists(atPath: project.clip.path))
            #expect(try ShareHistory(package: project.package).records() == [record])
            let folder = try #require(export.suggested).deletingLastPathComponent()
            #expect(!FileManager.default.fileExists(atPath: folder.path))
        }
        let progress = reported.withLock { $0 }
        #expect(!progress.contains { $0.phase == .exporting })
        #expect(progress.first == ShareProgress(phase: .uploading, fraction: 0))
        #expect(zip(progress, progress.dropFirst()).allSatisfy { $0.fraction < $1.fraction })
        #expect(progress.last == ShareProgress(phase: .uploading, fraction: 1))
    }

    @Test func misconfiguredFailsBeforeExporting() async throws {
        let fake = FakeS3()
        try await withTemporaryDirectory { dir in
            let project = try Project(in: dir)
            let export = FakeExport(clip: project.clip)
            var noBucket = fake.preferences()
            noBucket.bucket = ""
            #expect(await shareError { _ = try await run(project, fake, export, preferences: noBucket) }
                == .notConfigured(.missingBucket))
            #expect(await shareError { _ = try await run(project, fake, export, secrets: InMemorySecretStore()) }
                == .notConfigured(.missingSecret))
            #expect(await shareError {
                _ = try await run(project, fake, export, secrets: InMemorySecretStore([FakeS3.accessKeyID: ""]))
            } == .notConfigured(.missingSecret))
            var noKey = fake.preferences()
            noKey.accessKeyID = "  "
            #expect(await shareError { _ = try await run(project, fake, export, preferences: noKey) }
                == .notConfigured(.missingAccessKey))
            // The secret is found under the Access Key ID without spaces at its ends.
            var spaced = fake.preferences()
            spaced.accessKeyID = " \(FakeS3.accessKeyID)\n"
            #expect(spaced.secretAccount == FakeS3.accessKeyID)
            #expect(export.calls == 0)
            #expect(fake.requests.isEmpty)
            #expect(!FileManager.default.fileExists(atPath: project.shares.path))
        }
    }

    @Test func historyFailureLeavesNothingShared() async throws {
        let fake = FakeS3()
        try await withTemporaryDirectory { dir in
            let project = try Project(in: dir)
            // Unreadable before: nothing is exported or uploaded.
            let garbage = Data("not json".utf8)
            try garbage.write(to: project.shares)
            let export = FakeExport(clip: project.clip)
            #expect(await shareError { _ = try await run(project, fake, export) } == .historyUnreadable)
            #expect(export.calls == 0 && fake.requests.isEmpty)

            // Unreadable once the link is uploaded: its three objects are removed and it says so.
            try FileManager.default.removeItem(at: project.shares)
            let shares = project.shares
            let breaking = FakeExport(clip: project.clip, before: { try garbage.write(to: shares) })
            #expect(await shareError { _ = try await run(project, fake, breaking) } == .notSaved)
            let requests = fake.requests
            #expect(requests.filter { $0.method == "PUT" }.count == 3)
            #expect(requests.filter { $0.method == "DELETE" }.map(\.objectPath) == [
                "/bucket/toma/k3m7q2x4za/index.html", "/bucket/toma/k3m7q2x4za/poster.jpg",
                "/bucket/toma/k3m7q2x4za/video.mp4",
            ])
            for name in ShareRecord.objectNames { #expect(fake.object(at: "/bucket/toma/k3m7q2x4za/\(name)") == nil) }
            // The file it could not read is left as it was.
            #expect(try Data(contentsOf: project.shares) == garbage)
            let folder = try #require(breaking.suggested).deletingLastPathComponent()
            #expect(!FileManager.default.fileExists(atPath: folder.path))
        }
    }

    /// `shares.json` cannot record the link and the storage then refuses to remove it: it is never said to be removed,
    /// but where its objects are, to remove them by hand.
    @Test func aRemovalThatFailsSaysTheLinkMayStillBeOnline() async throws {
        let fake = FakeS3()
        try await withTemporaryDirectory { dir in
            let project = try Project(in: dir)
            let garbage = Data("not json".utf8)
            let shares = project.shares
            let breaking = FakeExport(clip: project.clip, before: { try garbage.write(to: shares) })
            fake.script(when: { request, _ in request.method == "DELETE" }, .error(403, code: "AccessDenied"))
            let error = await shareError { _ = try await run(project, fake, breaking) }
            #expect(error == .notSavedNorRemoved(bucket: "bucket", folder: "toma/k3m7q2x4za/"))
            // The page was the first to be removed and the storage refused it: all three are still there.
            for name in ShareRecord.objectNames { #expect(fake.object(at: "/bucket/toma/k3m7q2x4za/\(name)") != nil) }
            #expect(try Data(contentsOf: project.shares) == garbage)
        }
    }

    @Test func deleteRemovesFromStorageThenHistory() async throws {
        let fake = FakeS3()
        try await withTemporaryDirectory { dir in
            let project = try Project(in: dir)
            let export = FakeExport(clip: project.clip, reuse: true)
            let first = try await run(project, fake, export, ids: ["aaaaaaaaaa"])
            let second = try await run(project, fake, export, ids: ["bbbbbbbbbb"])
            let history = ShareHistory(package: project.package)
            #expect(try history.records().map(\.id) == ["bbbbbbbbbb", "aaaaaaaaaa"])

            try await ShareJob.delete(
                first, package: project.package, preferences: fake.preferences(), secrets: secrets, service: service(fake))
            for name in ShareRecord.objectNames { #expect(fake.object(at: "/bucket/toma/aaaaaaaaaa/\(name)") == nil) }
            #expect(fake.object(at: "/bucket/toma/bbbbbbbbbb/video.mp4") != nil)
            #expect(try history.records() == [second])

            // The storage refuses: the row stays.
            fake.script(when: { request, _ in request.method == "DELETE" }, .error(403, code: "AccessDenied"))
            let error = await shareError {
                try await ShareJob.delete(
                    second, package: project.package, preferences: fake.preferences(), secrets: secrets,
                    service: service(fake))
            }
            #expect(error == .authentication(code: "AccessDenied"))
            #expect(try history.records() == [second])
            // Without the secret, nothing is asked of the storage.
            let before = fake.requests.count
            let missing = await shareError {
                try await ShareJob.delete(
                    second, package: project.package, preferences: fake.preferences(), secrets: InMemorySecretStore(),
                    service: service(fake))
            }
            #expect(missing == .notConfigured(.missingSecret) && fake.requests.count == before)
        }
    }
}
