// SPDX-License-Identifier: GPL-3.0-or-later
import Darwin
import Editing
import Export
import Foundation
import OSLog
import ProjectFormat
import Synchronization

private let logger = Logger(subsystem: "dev.toma.Toma", category: "Music")

/// What the mix reads for a document's music (phase 3 design §7.4 to §7.7; plan 3c decisions 4, 6, 8 and 18), made once
/// into the caches: the mix only reads (`AnalysisInputs.musicFiles` and `.voiceActivity`), so whoever mixes asks this
/// first, and the export waits for it.
///
/// - **The themes of the library** come from `MusicLibrary` (the app's cache, `Music/music-1/`). A theme macOS removed
///   from it is made again by `prepare`, the same bytes; one it removes between the library's making it and the check
///   that follows is asked for once more.
/// - **An imported sound** (`assets/<32 hex>.<ext>`, `AssetKind.audio`) is decoded once (`ImportedAudio`) into the
///   project's cache: `music/<asset's name>-importedAudio-1.caf`. The asset is content-addressed, so its name is enough.
/// - **The voice** (only when `needsVoice`): where each microphone and each iPhone's sound with segments of every take
///   the sequence shows (`LoadedProject.takesShown(by:)`) has a voice (`VoiceActivityFinder`), by
///   `AudioPlan.key(take:track:)`, kept whole per track in `ducking/<take>/<track>-ducking-1.json`:
///   `{"algorithm": "ducking-1", "segments": […], "spans": [[start, end], …]}`, with the `SegmentIdentity.name` of each
///   segment of the track there when it was found, and each span in host-time nanoseconds. One whose segments are not
///   the ones there now (a segment written again, one gone or back) is stale and is found again. Whether a track is
///   muted, or its gain, does not matter here: the mix decides which voices duck (plan 3c decision 8).
///
/// `cached(for:)` makes nothing: it reads what is there (`lstat`, a CAF's 68 bytes, a voice's JSON once per version of
/// it). `prepare` makes what is missing, each piece once: callers asking for the same file share one piece of work,
/// which is stopped once none of them waits. A source that cannot be read (not there, a link, no audio, a theme the
/// library does not have) is left out without stopping the others; nothing is ever written halfway (a temporary moved
/// into place, `ProjectCaches.temporaryFile(for:)` and `commit(_:to:)`), never on the main thread, and the decoding and
/// the reading of the audio never on Swift's cooperative pool (`ImportedAudio`, `TrackAudio`, `SilenceFinder`).
///
/// A file `prepare` gave can still go before the mix opens it (macOS emptying the cache): the mix finds that source
/// silent, and a `prepare` called again makes it again.
public actor MusicAnalysis {
    /// The file that plays each piece of music, by `MusicItem.source`, and where each voice track has a voice, by
    /// `AudioPlan.key(take:track:)`: what `AnalysisInputs.musicFiles` and `.voiceActivity` hold.
    public typealias Prepared = (musicFiles: [String: URL], voiceActivity: [String: VoiceActivity])

    /// Decodes an imported sound to a new file, reporting its progress: `ImportedAudio.decode`, unless a test decodes.
    typealias Decode = @Sendable (_ source: URL, _ destination: URL, _ progress: @escaping @Sendable (Double) -> Void) async throws -> Void
    /// Where a voice track of a take has a voice: `VoiceActivityFinder.voiced` of `TrackAudio.load`, unless a test finds it.
    typealias FindVoice = @Sendable (_ project: LoadedProject, _ track: TrackRecord) async throws -> VoiceActivity

    private let project: LoadedProject
    private let caches: ProjectCaches
    private let library: MusicLibrary
    private let decode: Decode
    private let findVoice: FindVoice
    /// Called each time the library gave a theme's file, before it is checked: for a test.
    private let themeMade: @Sendable (String) -> Void

    /// The work under way that a caller may still join, by the path of the file it makes.
    private var work: [String: Shared] = [:]
    /// Work every caller left, by its id, until it has returned (and removed its temporary).
    private var stopping: [Int: Shared] = [:]
    private var lastID = 0
    /// What was read of each voice's file, by its path, while it is the same file.
    private var voiceReads: [String: VoiceRead] = [:]

    /// The music of `project`'s package, its themes from `library`, its decodings and voices in `caches`.
    public init(project: LoadedProject, caches: ProjectCaches, library: MusicLibrary) {
        self.init(
            project: project, caches: caches, library: library,
            decode: { try await ImportedAudio.decode($0, to: $1, progress: $2) },
            findVoice: { try await VoiceActivityFinder.voiced(try await TrackAudio.load($0, track: $1.id)) })
    }

    /// With the decoding and the voice search a test gives, and what it does once the library gave a theme.
    init(
        project: LoadedProject, caches: ProjectCaches, library: MusicLibrary, decode: @escaping Decode,
        findVoice: @escaping FindVoice, themeMade: @escaping @Sendable (String) -> Void = { _ in }
    ) {
        self.project = project
        self.caches = caches
        self.library = library
        self.decode = decode
        self.findVoice = findVoice
        self.themeMade = themeMade
    }

    /// Whether `document` needs the voice: a piece of music and the ducking on.
    public nonisolated func needsVoice(_ document: EditDocument) -> Bool {
        !document.music.items.isEmpty && document.music.ducking.enabled
    }

    /// What the caches hold now for `document`, making nothing: each source whose file is there whole (a theme in the
    /// library, an imported sound decoded) and, when `needsVoice`, each voice found for the segments there now. Reads
    /// the disk (`lstat`, 68 bytes of a CAF, a small JSON): never on the main thread.
    public func cached(for document: EditDocument) -> Prepared {
        var result: Prepared = ([:], [:])
        for piece in pieces(document) {
            switch piece {
            case let .theme(source, id):
                if let url = library.cachedFile(for: id) { result.musicFiles[source] = url }
            case let .imported(source, _, file):
                if Self.isDecoded(file) { result.musicFiles[source] = file }
            case let .voice(key, _, _, file, segments):
                if let voice = storedVoice(file, segments: segments) { result.voiceActivity[key] = voice }
            }
        }
        return result
    }

    /// What the mix needs for `document`, made first where it is missing (see the type), the pieces side by side,
    /// reporting the fraction done to `progress` (never going down, 1 last).
    /// - Throws: `CancellationError` if the task is cancelled (once the work it alone waited for has stopped and left
    ///   nothing); the `JobError` of a file that could not be written (`.noSpace` for a full drive), which stops the
    ///   other pieces too.
    public func prepare(_ document: EditDocument, progress: @escaping @Sendable (Double) -> Void) async throws -> Prepared {
        let pieces = pieces(document)
        let report = RisingProgress(progress)
        let parts = PartsProgress(count: pieces.count, report: report)
        report(0)
        var result: Prepared = ([:], [:])
        try await withThrowingTaskGroup(of: Made?.self) { group in
            for (index, piece) in pieces.enumerated() {
                group.addTask { try await self.make(piece) { parts.set(index, $0) } }
            }
            for try await made in group {
                switch made {
                case let .file(source, url)?: result.musicFiles[source] = url
                case let .voice(key, voice)?: result.voiceActivity[key] = voice
                case nil: break
                }
            }
        }
        try Task.checkCancellation()
        report(1)
        return result
    }

    /// How many callers wait for the work that makes `file`, for the tests.
    func waiters(for file: URL) -> Int {
        work[file.path]?.waiters.count ?? 0
    }

    // MARK: - The pieces

    /// What `document` needs, each once: a theme, an imported sound or a voice.
    private enum Piece: Sendable {
        case theme(source: String, id: String)
        case imported(source: String, asset: URL, file: URL)
        case voice(key: String, project: LoadedProject, track: TrackRecord, file: URL, segments: [String])
    }

    /// What a piece gave.
    private enum Made: Sendable {
        case file(source: String, URL)
        case voice(key: String, VoiceActivity)
    }

    /// The pieces of `document`: each source of its music once, in order (a theme of `music-1` the library has, or a
    /// sound in `assets/` that `ProjectPackage.mediaAsset(_:as:)` gives; anything else is left out), then, when
    /// `needsVoice`, the voice tracks of each take shown.
    private func pieces(_ document: EditDocument) -> [Piece] {
        var pieces: [Piece] = []
        var seen: Set<String> = []
        for item in document.music.items where seen.insert(item.source).inserted {
            if let id = MusicThemes.id(ofSource: item.source) {
                pieces.append(.theme(source: item.source, id: id))
            } else if let asset = project.package.mediaAsset(item.source, as: .audio), let file = importedFile(asset) {
                pieces.append(.imported(source: item.source, asset: asset, file: file))
            }
        }
        guard needsVoice(document) else { return pieces }
        for shown in project.takesShown(by: document) {
            for track in shown.take.tracks where Self.isVoice(track) {
                guard let file = voiceFile(take: shown.take.id, track: track.id) else { continue }
                let segments = track.segments.compactMap { SegmentIdentity.of($0, in: shown.package)?.name }
                pieces.append(.voice(
                    key: AudioPlan.key(take: shown.take.id, track: track.id), project: shown, track: track, file: file,
                    segments: segments))
            }
        }
        return pieces
    }

    /// What `piece` gives, made if it is not there; `nil` for a source that cannot be read.
    private func make(_ piece: Piece, progress: @escaping @Sendable (Double) -> Void) async throws -> Made? {
        defer { progress(1) }
        switch piece {
        case let .theme(source, id):
            return try await themeFile(id).map { .file(source: source, $0) }
        case let .imported(source, asset, file):
            if Self.isDecoded(file) { return .file(source: source, file) }
            let decode = decode
            let outcome = try await shared(file, progress: progress) { hub in
                await Self.decoded(asset, into: file, decode: decode, hub: hub)
            }
            guard case .file(let url) = outcome else { return nil }
            return .file(source: source, url)
        case let .voice(key, project, track, file, segments):
            if let voice = storedVoice(file, segments: segments) { return .voice(key: key, voice) }
            let findVoice = findVoice
            let outcome = try await shared(file, progress: progress) { hub in
                await Self.voiced(project, track, into: file, segments: segments, findVoice: findVoice, hub: hub)
            }
            guard case .voice(let voice) = outcome else { return nil }
            return .voice(key: key, voice)
        }
    }

    /// The file of theme `id` from the library, made there if it is not; `nil` if the library does not have the theme.
    /// One the cache loses as soon as it is made is asked for once more.
    private func themeFile(_ id: String) async throws -> URL? {
        if let url = library.cachedFile(for: id) { return url }
        for _ in 0..<2 {
            let url: URL
            do {
                url = try await library.file(for: id)
            } catch is CancellationError {
                throw CancellationError()
            } catch MusicLibraryError.unknownTheme {
                return nil
            } catch {
                let room = Self.hasRoom(for: Int64(MusicFile.headerBytes + MusicFile.frameBytes * MusicThemes.loopFrames), at: library.url(for: id))
                throw JobError(room ? .failed("the theme \(id) could not be written to the music library") : .noSpace)
            }
            themeMade(id)
            if library.cachedFile(for: id) == url { return url }
            logger.error("Music theme \(id, privacy: .public) left the cache as soon as it was made; asking for it again")
        }
        throw JobError(.failed("the theme \(id) left the music library's cache as soon as it was made"))
    }

    // MARK: - The work

    /// What a piece of work made.
    private enum Outcome: Sendable {
        case file(URL)
        case voice(VoiceActivity)
        /// Its source cannot be read.
        case nothing
    }

    /// A piece of work and who waits for it.
    private struct Shared {
        var id: Int
        var task: Task<Void, Never>
        var hub: ProgressHub
        var waiters: [Int: CheckedContinuation<Result<Outcome, any Error>, Never>]
    }

    /// What `body` makes `file` into, on a task of its own at utility priority, shared with every caller asking for
    /// `file` while it runs. A caller whose task is cancelled stops waiting at once if another one still waits; the last
    /// one cancels the work and waits until it returned, so nothing of it is left once this throws.
    private func shared(
        _ file: URL, progress: @escaping @Sendable (Double) -> Void,
        body: @escaping @Sendable (ProgressHub) async -> Result<Outcome, any Error>
    ) async throws -> Outcome {
        let key = file.path
        lastID += 1
        let waiter = lastID
        let result = await withTaskCancellationHandler {
            await withCheckedContinuation { (continuation: CheckedContinuation<Result<Outcome, any Error>, Never>) in
                if Task.isCancelled {
                    continuation.resume(returning: .failure(CancellationError()))
                } else if var entry = work[key] {
                    entry.waiters[waiter] = continuation
                    work[key] = entry
                    entry.hub.listen(waiter, progress)
                } else {
                    lastID += 1
                    let id = lastID
                    let hub = ProgressHub()
                    hub.listen(waiter, progress)
                    // `finish` runs on this actor, after this.
                    let task = Task.detached(priority: .utility) {
                        let result = await body(hub)
                        await self.finish(key, id: id, result: result)
                    }
                    work[key] = Shared(id: id, task: task, hub: hub, waiters: [waiter: continuation])
                }
            }
        } onCancel: {
            Task { await self.leave(key, waiter: waiter) }
        }
        return try result.get()
    }

    /// `waiter` of the work on `key` was cancelled: it stops waiting now if another one waits; if it was the last, the
    /// work is cancelled (a new caller starts anew) and answers it once it returned.
    private func leave(_ key: String, waiter: Int) {
        guard var entry = work[key], let continuation = entry.waiters[waiter] else { return }
        entry.hub.stop(waiter)
        if entry.waiters.count > 1 {
            entry.waiters[waiter] = nil
            work[key] = entry
            continuation.resume(returning: .failure(CancellationError()))
        } else {
            work[key] = nil
            stopping[entry.id] = entry
            entry.task.cancel()
        }
    }

    /// The work `id` on `key` returned `result`: every caller still waiting gets it (a cancellation, if every one left).
    private func finish(_ key: String, id: Int, result: Result<Outcome, any Error>) {
        let entry: Shared, answer: Result<Outcome, any Error>
        if let found = work[key], found.id == id {
            work[key] = nil
            (entry, answer) = (found, result)
        } else if let found = stopping.removeValue(forKey: id) {
            (entry, answer) = (found, .failure(CancellationError()))
        } else {
            return
        }
        for continuation in entry.waiters.values { continuation.resume(returning: answer) }
    }

    /// Decodes `asset` into `file` through a temporary next to it; `.nothing` for a sound that cannot be read.
    private static func decoded(_ asset: URL, into file: URL, decode: Decode, hub: ProgressHub) async -> Result<Outcome, any Error> {
        // Another caller's work may have made it since this one looked.
        if isDecoded(file) { return .success(.file(file)) }
        let temporary: URL
        do {
            temporary = try ProjectCaches.temporaryFile(for: file)
        } catch {
            return .failure(VoiceJobs.jobError(error))
        }
        do {
            try await decode(asset, temporary) { hub.report($0) }
            guard try ProjectCaches.commit(temporary, to: file) else {
                return .failure(JobError(.failed("the sound \(asset.lastPathComponent) could not be kept in the cache")))
            }
            return .success(.file(file))
        } catch {
            unlink(temporary.path)
            if error is CancellationError || Task.isCancelled { return .failure(CancellationError()) }
            if let error = error as? ImportedAudioError {
                logger.error("Music \(asset.lastPathComponent, privacy: .public): \(String(describing: error), privacy: .public); left silent")
                return .success(.nothing)
            }
            return .failure(VoiceJobs.jobError(error))
        }
    }

    /// Finds the voice of `track` of `project` and keeps it in `file`; the voice even if the file cannot be written (it
    /// is found again next time), `.nothing` if the track's audio cannot be read.
    private static func voiced(
        _ project: LoadedProject, _ track: TrackRecord, into file: URL, segments: [String], findVoice: FindVoice,
        hub: ProgressHub
    ) async -> Result<Outcome, any Error> {
        do {
            let voice = try await findVoice(project, track)
            try Task.checkCancellation()
            hub.report(0.9)
            let stored = StoredVoice(
                algorithm: DuckingEnvelope.algorithm, segments: segments,
                spans: voice.spans.map { [$0.lowerBound.nanoseconds, $0.upperBound.nanoseconds] })
            if let data = try? ProjectJSON.encoder().encode(stored), !ProjectCaches.writeAnalysis(data, to: file) {
                try Task.checkCancellation()
                logger.error("The voice of \(project.take.id, privacy: .public)/\(track.id, privacy: .public) could not be kept in the cache")
            }
            return .success(.voice(voice))
        } catch {
            if error is CancellationError || Task.isCancelled { return .failure(CancellationError()) }
            logger.error("The voice of \(project.take.id, privacy: .public)/\(track.id, privacy: .public): \(String(describing: error), privacy: .public)")
            return .success(.nothing)
        }
    }

    // MARK: - The caches

    /// A voice's file as it is written.
    private struct StoredVoice: Codable, Equatable, Sendable {
        var algorithm: String
        var segments: [String]
        /// `[start, end]` of each span, host-time nanoseconds.
        var spans: [[UInt64]]

        /// The voice, if every span is two numbers, in order and apart from the one before (touching is allowed).
        var activity: VoiceActivity? {
            var spans: [Range<HostTime>] = []
            var last: UInt64 = 0
            for pair in self.spans {
                guard pair.count == 2, pair[0] <= pair[1], pair[0] >= last else { return nil }
                spans.append(HostTime(nanoseconds: pair[0])..<HostTime(nanoseconds: pair[1]))
                last = pair[1]
            }
            return VoiceActivity(spans: spans)
        }
    }

    /// What was read of a voice's file, and of which version of it.
    private struct VoiceRead {
        var stamp: FileStamp
        var stored: StoredVoice?
    }

    /// The voice kept in `file`, if it is the one of `segments` (and of `ducking-1`); read once per version of the file.
    private func storedVoice(_ file: URL, segments: [String]) -> VoiceActivity? {
        guard let stamp = FileStamp(file) else {
            voiceReads[file.path] = nil
            return nil
        }
        let stored: StoredVoice?
        if let read = voiceReads[file.path], read.stamp == stamp {
            stored = read.stored
        } else {
            stored = ProjectCaches.readAnalysis(file).flatMap { try? ProjectJSON.decoder().decode(StoredVoice.self, from: $0) }
            voiceReads[file.path] = VoiceRead(stamp: stamp, stored: stored)
        }
        guard let stored, stored.algorithm == DuckingEnvelope.algorithm, stored.segments == segments else { return nil }
        return stored.activity
    }

    /// `music/<asset's name>-importedAudio-1.caf` for the sound at `asset` (a name `PackageFileKind.audio` allows).
    private nonisolated func importedFile(_ asset: URL) -> URL? {
        let name = "\(asset.lastPathComponent)-\(ImportedAudio.algorithm).caf"
        guard Self.isOneName(name) else { return nil }
        return caches.folder(.music).appending(path: name, directoryHint: .notDirectory)
    }

    /// `ducking/<take>/<track>-ducking-1.json`; `nil` unless each is one name.
    private nonisolated func voiceFile(take: String, track: String) -> URL? {
        let name = "\(track)-\(DuckingEnvelope.algorithm).json"
        guard Self.isOneName(take), Self.isOneName(name) else { return nil }
        return caches.folder(.ducking).appending(path: take, directoryHint: .isDirectory)
            .appending(path: name, directoryHint: .notDirectory)
    }

    /// Whether `url` holds a decoded sound whole: a regular file (a link is not followed) that is our CAF for the frames
    /// its size says, at least one.
    private static func isDecoded(_ url: URL) -> Bool {
        var info = stat()
        guard lstat(url.path, &info) == 0, info.st_mode & S_IFMT == S_IFREG else { return false }
        let size = Int(info.st_size)
        guard size > MusicFile.headerBytes, (size - MusicFile.headerBytes) % MusicFile.frameBytes == 0 else { return false }
        return MusicFile.isOurs(at: url, frames: (size - MusicFile.headerBytes) / MusicFile.frameBytes)
    }

    /// A microphone or an iPhone's sound with segments.
    private static func isVoice(_ track: TrackRecord) -> Bool {
        (track.kind == .microphone || track.kind == .deviceAudio) && !track.segments.isEmpty
    }

    /// Not empty, `.` or `..`, and without `/` or NUL.
    private static func isOneName(_ name: String) -> Bool {
        !name.isEmpty && name != "." && name != ".." && !name.utf8.contains(UInt8(ascii: "/")) && !name.utf8.contains(0)
    }

    /// Whether the volume of `url` has room for `bytes` more, and some to spare; true when it cannot tell.
    private static func hasRoom(for bytes: Int64, at url: URL) -> Bool {
        var folder = url.deletingLastPathComponent()
        while !FileManager.default.fileExists(atPath: folder.path), folder.pathComponents.count > 1 {
            folder = folder.deletingLastPathComponent()
        }
        guard let available = try? folder.resourceValues(forKeys: [.volumeAvailableCapacityKey]).volumeAvailableCapacity else {
            return true
        }
        return Int64(available) > bytes + 1_048_576
    }
}

/// Which file is at a path, by `lstat` (a link is not followed): a file replaced or rewritten is another stamp.
private struct FileStamp: Equatable {
    var device: Int32
    var inode: UInt64
    var bytes: Int64
    var modified: Int64

    /// The stamp of the regular file at `url`; `nil` if there is none.
    init?(_ url: URL) {
        var info = stat()
        guard lstat(url.path, &info) == 0, info.st_mode & S_IFMT == S_IFREG else { return nil }
        device = info.st_dev
        inode = info.st_ino
        bytes = Int64(info.st_size)
        modified = Int64(info.st_mtimespec.tv_sec) * 1_000_000_000 + Int64(info.st_mtimespec.tv_nsec)
    }
}

/// The progress of one piece of work, sent to every caller waiting for it: never down.
private final class ProgressHub: Sendable {
    private struct State {
        var last = 0.0
        var listeners: [Int: @Sendable (Double) -> Void] = [:]
    }

    private let state = Mutex(State())

    func report(_ fraction: Double) {
        guard !fraction.isNaN else { return }
        let listeners = state.withLock { state -> [@Sendable (Double) -> Void] in
            guard fraction > state.last else { return [] }
            state.last = fraction
            return Array(state.listeners.values)
        }
        for listener in listeners { listener(fraction) }
    }

    /// `listener` gets every fraction from now on, and the last one at once.
    func listen(_ id: Int, _ listener: @escaping @Sendable (Double) -> Void) {
        let last = state.withLock { state in
            state.listeners[id] = listener
            return state.last
        }
        if last > 0 { listener(last) }
    }

    func stop(_ id: Int) {
        state.withLock { _ = $0.listeners.removeValue(forKey: id) }
    }
}

/// The progress of `prepare`: the mean of its pieces', each never down.
private final class PartsProgress: Sendable {
    private let parts: Mutex<[Double]>
    private let report: RisingProgress

    init(count: Int, report: RisingProgress) {
        parts = Mutex([Double](repeating: 0, count: count))
        self.report = report
    }

    func set(_ index: Int, _ fraction: Double) {
        guard !fraction.isNaN else { return }
        let total = parts.withLock { parts -> Double in
            parts[index] = max(parts[index], min(max(fraction, 0), 1))
            return parts.reduce(0, +) / Double(parts.count)
        }
        report(total)
    }
}

/// Reports a fraction only when it is past the last one reported: from 0 to 1, never down.
private final class RisingProgress: Sendable {
    private let last = Mutex(-1.0)
    private let report: @Sendable (Double) -> Void

    init(_ report: @escaping @Sendable (Double) -> Void) {
        self.report = report
    }

    func callAsFunction(_ fraction: Double) {
        guard !fraction.isNaN else { return }
        let value = min(max(fraction, 0), 1)
        last.withLock { last in
            guard value > last else { return }
            last = value
            report(value)
        }
    }
}
