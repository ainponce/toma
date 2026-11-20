// SPDX-License-Identifier: GPL-3.0-or-later
import Analysis
import Editing
import Export
import Foundation
import ProjectFormat
import ProjectJobs
import RecorderKitTestSupport
import Synchronization
import Transcription
@testable import ProjectAPI

/// What the tests of the project API share: a project of 10 s of a screen and a microphone with two recorded markers
/// (at 3 s and 7 s), its made-up transcript (`FakeTranscript`), and an `APIEnvironment` of temporary folders, a clock
/// that moves 2 s each time it is read (every step its own undo group) and ids that count.
enum APIFixtures {
    static let base = HostTime(nanoseconds: 5_000_000_000_000)
    static let seconds = 10.0
    /// Where the take recorded its markers, in seconds from its start.
    static let markerSeconds = [3.0, 7.0]
    static let app = AppInfo(name: "toma", version: ProjectAPI.version)

    /// A clock that moves 2 s each time it is read.
    final class Clock: Sendable {
        private let date = Mutex(Date(timeIntervalSince1970: 1_794_780_000))

        func now() -> Date {
            date.withLock { date in
                defer { date += 2 }
                return date
            }
        }
    }

    /// Ids that count: `makeID("z-")` is `z-00000001`, then `z-00000002`…
    final class IDs: Sendable {
        private let count = Mutex(0)

        func make(_ prefix: String) -> String {
            count.withLock { count in
                count += 1
                return prefix + String(format: "%08x", count)
            }
        }
    }

    /// No voice isolation: the tests never run one.
    struct NoIsolation: VoiceIsolating {
        var isAvailable: Bool { false }

        func clean(_ audio: TrackAudio, span: TrackAudioSpan, to url: URL, progress: @escaping @Sendable (Double) -> Void) async throws {
            throw CancellationError()
        }
    }

    /// The journal's calls to the disk, whose writes fail with a code while one is set.
    final class FailingIO: Sendable {
        private let failure = Mutex<POSIXErrorCode?>(nil)

        func failWrites(with code: POSIXErrorCode?) { failure.withLock { $0 = code } }

        var io: EditJournalIO {
            EditJournalIO(
                open: { try EditJournalIO.system.open($0, $1, $2) },
                write: { [self] descriptor, bytes in
                    if let code = failure.withLock({ $0 }) { throw POSIXError(code) }
                    return try EditJournalIO.system.write(descriptor, bytes)
                },
                fullSync: { try EditJournalIO.system.fullSync($0) },
                fsync: { try EditJournalIO.system.fsync($0) },
                syncDirectory: { try EditJournalIO.system.syncDirectory($0) })
        }
    }

    /// An environment of folders inside `dir`, none of the user's.
    static func environment(in dir: URL, journalIO: EditJournalIO = .system) -> APIEnvironment {
        let clock = Clock(), ids = IDs()
        var environment = APIEnvironment(
            app: app, cachesRoot: dir.appending(path: "Caches"), musicRoot: dir.appending(path: "Music"),
            stylesFolder: dir.appending(path: "Styles"), projectsFolder: dir.appending(path: "Projects"),
            controlSocket: dir.appending(path: "control.sock"), now: { clock.now() }, makeID: { ids.make($0) }, speech: nil,
            isolator: NoIsolation())
        environment.journalIO = journalIO
        return environment
    }

    /// A take of `seconds` of one display (10 fps) and a microphone, with `marker` events at `markerSeconds`, in a new
    /// package `<name>.toma` of `formatVersion`. Written off the main actor.
    @concurrent static func package(
        in dir: URL, name: String = "Fixture", formatVersion: Int = Manifest.currentFormatVersion
    ) async throws -> LoadedProject {
        let builder = try TakeBuilder(in: dir, name: name, formatVersion: formatVersion)
        let frame = Rect(x: 0, y: 0, width: 640, height: 360)
        try await builder.addVideoTrack(
            id: "display-1", source: TrackSource(name: "Synthetic Display", displayID: 1, globalFrame: frame, pixelScale: 1),
            segments: [VideoSegmentSpec(start: base, seconds: seconds, framesPerSecond: 10, width: 320, height: 180)])
        try await builder.addAudioTrack(
            id: "mic", source: TrackSource(name: "Synthetic Microphone", deviceUniqueID: "mic"),
            segments: [AudioSegmentSpec(start: base, seconds: seconds)])
        try builder.addEvents(
            [InputEvent(t: base.adding(seconds: -0.01), kind: .displayGeometry(displayID: 1, frame: frame, scale: 1))]
                + markerSeconds.map { InputEvent(t: base.adding(seconds: $0), kind: .marker) })
        return try builder.write()
    }

    /// `package(in:name:)` with its transcript in the document, added as the app adds one (a `transcript.create` step of
    /// an edit session), and closed.
    @MainActor static func transcribed(in dir: URL, name: String = "Fixture", environment: APIEnvironment) async throws -> URL {
        let project = try await package(in: dir, name: name)
        let session = try await EditSession.open(project.package.url, take: nil, context: environment.editContext)
        let step = try unwrap(TranscriptCommands.create(session.document, FakeTranscript.make(for: project.take)), "transcript step")
        guard session.perform(step) == .applied else { throw TestSupportError.failed("the transcript was not applied") }
        _ = await session.flushed()
        await session.close()
        return project.package.url
    }

    /// A project of phase 3 never edited since: `package(in:name:)` with a log of one `create` and its snapshot, both
    /// written in `documentVersion` 4, as the app of phase 3 left it.
    @concurrent static func version4(in dir: URL, name: String = "Phase3") async throws -> URL {
        let project = try await package(in: dir, name: name)
        let ids = IDs()
        var document = NewDocument.make(project: project, defaultStyle: .toma, makeID: { ids.make($0) })
        document.logSequence = 1
        let line = try EditLogEntry.create(seq: 1, document: document, app: AppInfo(name: "Toma", version: "0.6.0"))
            .jsonLine(writingDocumentAt: 4)
        try DurableFile.writeAtomically(Data((line + "\n").utf8), to: project.package.editLogURL)
        let written = try unwrap(DocumentMigration.reverted(try JSONValue(encoding: document), to: 4), "version 4")
        try DurableFile.writeAtomically(try ProjectJSON.encoder().encode(written), to: project.package.editURL)
        return project.package.url
    }

    /// The scope of the document `NewDocument` makes for `project`, with its transcript, as `CommandScope.reading` reads it.
    static func scope(of project: LoadedProject, transcript: Bool = true, makeID: @escaping @Sendable (String) -> String) throws
        -> CommandScope
    {
        let ids = IDs()
        var document = NewDocument.make(project: project, defaultStyle: .toma, makeID: { ids.make("n" + $0) })
        if transcript { document.transcript = FakeTranscript.make(for: project.take) }
        return try CommandScope.reading(project: project, document: document, makeID: makeID)
    }

    /// The editable bounds of every take of `project`, as the app's mix has them (`EditedMix.takeBounds`).
    static func takeBounds(of project: LoadedProject) -> [String: ClosedRange<HostTime>] {
        var bounds: [String: ClosedRange<HostTime>] = [:]
        for take in project.takes {
            let editable = TakeTimeline.editableBounds(take: take, events: project.events(ofTake: take.id))
            bounds[take.id] = editable.start...editable.end
        }
        return bounds
    }

    /// `seconds` of output in ns.
    static func ns(_ seconds: Double) -> Int64 { TimeMap.outputNanoseconds(seconds: seconds) }

    /// The `APIError` `body` throws; `nil` if it throws none or another error.
    @MainActor static func apiError(_ body: () async throws -> Void) async -> APIError? {
        do {
            try await body()
            return nil
        } catch {
            return error as? APIError
        }
    }

    /// The entries of the package's edit log.
    static func logEntries(_ url: URL) throws -> [EditLogEntry] {
        try EditLogReader.read(ProjectPackage(url: url).editLogURL).entries
    }
}

/// The step of a `CommandStep`, for the tests.
extension CommandStep {
    var editStep: EditStep? {
        if case let .step(step, _) = self { step } else { nil }
    }

    var created: String? {
        if case let .step(_, created) = self { created } else { nil }
    }

    var isUnchanged: Bool {
        if case .unchanged = self { true } else { false }
    }
}
