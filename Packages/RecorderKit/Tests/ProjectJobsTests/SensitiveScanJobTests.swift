// SPDX-License-Identifier: GPL-3.0-or-later
import CoreVideo
import Editing
import Foundation
import ImageAnalysis
import ProjectFormat
import RecorderKitTestSupport
import Synchronization
import Testing
// @testable only for `ProjectJobs.isRunning`, which tells when a cancelled work has returned.
@testable import ProjectJobs

// Every test here runs in `make tsan`.

private let base = HostTime(nanoseconds: 5_000_000_000_000)

private let email = "ana.perez@gmail.com"
private let key = "sk_live_\u{34}eC39HqLyjWDarjtT1zdp7dc"

/// Hands out what `respond` says for each call (counted from 0), and counts them.
private final class FakeRecognizer: ScreenRecognizer {
    private let calls = Mutex(0)
    private let respond: @Sendable (Int) -> [FrameObservation]
    private let available: Bool

    init(available: Bool = true, respond: @escaping @Sendable (Int) -> [FrameObservation] = { _ in [] }) {
        self.available = available
        self.respond = respond
    }

    var isAvailable: Bool { available }

    func observe(_ frame: CVPixelBuffer, crop: Rect) throws -> [FrameObservation] {
        let number = calls.withLock { calls in
            defer { calls += 1 }
            return calls
        }
        return respond(number)
    }

    var count: Int { calls.withLock { $0 } }
}

/// Sees an address and a key on every frame.
private func seeingSecrets() -> FakeRecognizer {
    FakeRecognizer { _ in
        [
            FrameObservation(kind: .email, text: email, rect: NormalizedRect(x: 0.1, y: 0.1, width: 0.3, height: 0.05)),
            FrameObservation(kind: .secret, text: key, rect: NormalizedRect(x: 0.1, y: 0.5, width: 0.5, height: 0.05)),
        ]
    }
}

/// A package with one take of 2 s of `SampleFactory` frames (which change at every sample) on each display of
/// `displays`, and the caches of its project in `directory`.
private func project(in directory: URL, displays: [String] = ["display-1"]) async throws -> (LoadedProject, ProjectCaches) {
    let builder = try TakeBuilder(in: directory)
    for (k, id) in displays.enumerated() {
        let source = TrackSource(
            name: id, displayID: UInt32(k + 1), globalFrame: Rect(x: Double(k) * 320, y: 0, width: 320, height: 180), pixelScale: 1)
        try await builder.addVideoTrack(
            id: id, source: source, segments: [VideoSegmentSpec(start: base, seconds: 2, width: 320, height: 180)])
    }
    let project = try builder.write()
    let caches = ProjectCaches(
        root: directory.appending(path: "Caches", directoryHint: .isDirectory), projectID: project.manifest.resolvedProjectID)
    return (project, caches)
}

private func scan(
    _ project: LoadedProject, document: EditDocument? = nil, caches: ProjectCaches, recognizer: any ScreenRecognizer,
    jobs: ProjectJobs = ProjectJobs()
) async throws -> JobOutput {
    try await jobs.result(
        of: .sensitiveScan(take: project.take.id),
        work: SensitiveScanJob.work(
            project: project, document: document ?? .legacy(for: project), caches: caches, recognizer: recognizer))
}

/// Every file under `folder`, hidden ones included, relative to it.
private func files(in folder: URL) -> [String] {
    guard let names = FileManager.default.enumerator(atPath: folder.path) else { return [] }
    return names.compactMap { $0 as? String }.sorted()
}

@Suite("SensitiveScanJob")
struct SensitiveScanJobTests {
    @Test func cacheHoldsNoPlainText() async throws {
        try await withTemporaryDirectory { directory in
            let (project, caches) = try await project(in: directory)
            let output = try await scan(project, caches: caches, recognizer: seeingSecrets())
            let url = try #require(caches.scanFile(take: project.take.id, algorithm: "sensitiveScan-1"))
            #expect(output == .cached(url))
            #expect(url.lastPathComponent == "take-001-sensitiveScan-1.json")
            let bytes = try Data(contentsOf: url)
            let text = try #require(String(data: bytes, encoding: .utf8))
            #expect(!text.contains(email) && !text.contains("ana.perez") && !text.contains("gmail"))
            #expect(!text.contains(key) && !text.contains("4eC39"))
            // What it does keep: the masked forms, and what tells when it is stale.
            let result = try #require(SensitiveScanJob.cached(project: project, document: .legacy(for: project), caches: caches))
            #expect(Set(result.findings.map(\.masked)) == ["an•••@g•••.com", "sk_live_•••"])
            #expect(result.segments == SensitiveScanJob.segmentNames(of: project.take, in: project.package))
            #expect(result.segments.count == 1)
            // Nothing else in the folder: no temporary left behind.
            #expect(files(in: caches.folder(.scan)) == ["take-001-sensitiveScan-1.json"])
        }
    }

    @Test func cachedResultIsInstant() async throws {
        try await withTemporaryDirectory { directory in
            let (project, caches) = try await project(in: directory)
            let fake = seeingSecrets()
            let jobs = ProjectJobs()
            let first = try await scan(project, caches: caches, recognizer: fake, jobs: jobs)
            let looked = fake.count
            #expect(looked == 8)
            let second = try await scan(project, caches: caches, recognizer: fake, jobs: jobs)
            #expect(second == first)
            #expect(fake.count == looked)
            // Without Vision too: the cache needs none.
            let blind = FakeRecognizer(available: false)
            #expect(try await scan(project, caches: caches, recognizer: blind) == first)
        }
    }

    @Test func staleCacheIsScannedAgain() async throws {
        try await withTemporaryDirectory { directory in
            let (project, caches) = try await project(in: directory)
            let fake = seeingSecrets()
            _ = try await scan(project, caches: caches, recognizer: fake)
            #expect(fake.count == 8)
            // The segment is written again: another date, so another identity.
            let segment = project.package.fileURL(project.take.tracks[0].segments[0].file)
            try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSince1970: 1_700_000_000)], ofItemAtPath: segment.path)
            #expect(SensitiveScanJob.cached(project: project, document: .legacy(for: project), caches: caches) == nil)
            _ = try await scan(project, caches: caches, recognizer: fake)
            #expect(fake.count == 16)
            #expect(SensitiveScanJob.cached(project: project, document: .legacy(for: project), caches: caches) != nil)
        }
    }

    @Test func anotherShownScreenIsScannedAgain() async throws {
        try await withTemporaryDirectory { directory in
            let (project, caches) = try await project(in: directory, displays: ["display-1", "display-2"])
            let fake = seeingSecrets()
            let document = EditDocument.legacy(for: project)
            _ = try await scan(project, document: document, caches: caches, recognizer: fake)
            #expect(fake.count == 8)
            // Display 2 from 1 s on: what was found on display 1 there says nothing of it.
            var changed = document
            changed.screens.changes = [
                ScreenChange(id: "s-00000001", take: project.take.id, t: base.adding(seconds: 1), track: "display-2", origin: .user)
            ]
            #expect(SensitiveScanJob.cached(project: project, document: changed, caches: caches) == nil)
            _ = try await scan(project, document: changed, caches: caches, recognizer: fake)
            #expect(fake.count == 16)
        }
    }

    @Test func cancellingWritesNothing() async throws {
        let gate = DispatchSemaphore(value: 0)
        let fake = FakeRecognizer { call in
            if call == 0 { gate.wait() }
            return []
        }
        try await withTemporaryDirectory { directory in
            let (project, caches) = try await project(in: directory)
            let jobs = ProjectJobs()
            let kind = AnalysisJobKind.sensitiveScan(take: project.take.id)
            await jobs.enqueue(
                kind, work: SensitiveScanJob.work(project: project, document: .legacy(for: project), caches: caches, recognizer: fake))
            #expect(await eventually { fake.count == 1 })
            await jobs.cancel(kind)
            gate.signal()
            #expect(await eventually { await !jobs.isRunning })
            #expect(fake.count == 1)
            #expect(files(in: caches.folder(.scan)).isEmpty)
            #expect(await jobs.state(of: kind) == nil)
        }
    }

    @Test func withoutVisionItIsUnavailable() async throws {
        try await withTemporaryDirectory { directory in
            let (project, caches) = try await project(in: directory)
            let jobs = ProjectJobs()
            let blind = FakeRecognizer(available: false)
            await #expect(throws: JobError(.notOnThisMac, unavailable: true)) {
                try await scan(project, caches: caches, recognizer: blind, jobs: jobs)
            }
            #expect(await jobs.state(of: .sensitiveScan(take: project.take.id)) == .unavailable(.notOnThisMac))
            #expect(blind.count == 0)
            #expect(files(in: caches.folder(.scan)).isEmpty)
        }
    }

    @Test func anUnreadableSegmentFailsWithItsFile() async throws {
        try await withTemporaryDirectory { directory in
            let builder = try TakeBuilder(in: directory)
            let source = TrackSource(
                name: "Display", displayID: 1, globalFrame: Rect(x: 0, y: 0, width: 320, height: 180), pixelScale: 1)
            try await builder.addVideoTrack(
                id: "display-1", source: source,
                segments: [VideoSegmentSpec(start: base, seconds: 1, width: 320, height: 180, endReason: .paused)])
            try builder.addEmptySegment(
                track: "display-1", index: 2, start: base.adding(seconds: 1.5), end: base.adding(seconds: 2.5),
                endReason: .stopped, file: .garbage())
            let project = try builder.write()
            let caches = ProjectCaches(
                root: directory.appending(path: "Caches", directoryHint: .isDirectory), projectID: project.manifest.resolvedProjectID)
            let jobs = ProjectJobs()
            let file = "takes/take-001/display-1/seg-0002.mov"
            await #expect(throws: JobError(.sourceUnreadable(file: file))) {
                try await scan(project, caches: caches, recognizer: FakeRecognizer(), jobs: jobs)
            }
            #expect(await jobs.state(of: .sensitiveScan(take: project.take.id)) == .failed(.sourceUnreadable(file: file)))
            #expect(files(in: caches.folder(.scan)).isEmpty)
        }
    }

    @Test func segmentNamesAreEveryScreenSegment() async throws {
        try await withTemporaryDirectory { directory in
            let (project, _) = try await project(in: directory, displays: ["display-1", "display-2"])
            let names = SensitiveScanJob.segmentNames(of: project.take, in: project.package)
            let identities = project.take.tracks.flatMap { track in
                track.segments.map { "\(track.id)/\(SegmentIdentity.of($0, in: project.package)?.name ?? "-")" }
            }
            #expect(names == identities)
            #expect(names.count == 2 && names.allSatisfy { $0.contains("/seg-0001-") })
        }
    }
}
