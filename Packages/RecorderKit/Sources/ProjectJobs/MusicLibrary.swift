// SPDX-License-Identifier: GPL-3.0-or-later
import Darwin
import Dispatch
import Editing
import Export
import Foundation
import Synchronization

/// What `MusicLibrary.file(for:)` throws besides `CancellationError`.
public enum MusicLibraryError: Error, Equatable, Sendable {
    /// The id is not one of the library's themes (`MusicThemes.ids`).
    case unknownTheme(String)
    /// The theme was made but its file could not be written (a full disk, a folder that cannot be made).
    case couldNotWrite
}

/// The themes of the music library on disk (design §7.6, plan decision 4): `<root>/music-1/<id>.caf`, in the app's cache
/// (`~/Library/Caches/dev.toma.Toma/Music`), made the first time they are asked for and kept. A theme always comes out
/// the same bytes (`MusicSynth`), so if macOS empties the cache it is made again, the same, and whoever needs it waits.
///
/// - A file is the theme only if it is our CAF (`MusicFile`) with exactly the theme's frames, by its size and its 68
///   bytes; anything else at its name (cut short, another file, a link, never followed) is not, and is replaced.
/// - Making one renders its score (about half a second, more for a dense theme), writes a temporary next to it and moves
///   it into place (`ProjectCaches.temporaryFile(for:)` and `commit(_:to:)`), so its name holds the whole file or none.
///   It runs on a dispatch queue of the library's own, one theme at a time: never on the main thread, never on a thread
///   of Swift's cooperative pool (the voices of a block render on Dispatch's threads, `MusicSynth`).
/// - Callers asking for the same theme while it is made share the one piece of work, which is cancelled (leaving no
///   file and no temporary) once every one of them is.
///
/// The app keeps one library (`shared`), so two editors asking for a theme at once wait for one synthesis; two libraries
/// on the same folder would each make it, and the last to finish would put the same bytes in place.
public actor MusicLibrary {
    /// `~/Library/Caches/dev.toma.Toma/Music`. Computed: a stored `static var` is not concurrency-safe.
    public static var defaultRoot: URL {
        URL.cachesDirectory.appending(path: "dev.toma.Toma", directoryHint: .isDirectory)
            .appending(path: "Music", directoryHint: .isDirectory)
    }

    /// The app's library, in `defaultRoot`.
    public static let shared = MusicLibrary()

    private let root: URL
    private let themes: [String]
    private let score: @Sendable (String) -> MusicScore?
    private let synthesize: @Sendable (MusicScore, () -> Bool) -> [Float]?
    /// The frames of each theme, worked out once from its score.
    private let knownFrames = Mutex<[String: Int]>([:])
    private let queue = DispatchQueue(label: "dev.toma.Toma.MusicLibrary", qos: .utility)
    private var work: [String: (task: Task<Result<URL, any Error>, Never>, waiters: Int)] = [:]
    /// How many themes were rendered, and how many pieces of work have not returned yet, for tests.
    private(set) var syntheses = 0
    private(set) var inFlight = 0

    public init(root: URL = MusicLibrary.defaultRoot) {
        self.init(root: root, themes: MusicThemes.ids, score: MusicThemes.score)
    }

    /// A library of the themes `themes` whose scores `score` gives, made by `synthesize` (which gets a function that says
    /// whether to stop): for tests.
    init(
        root: URL, themes: [String], score: @escaping @Sendable (String) -> MusicScore?,
        synthesize: @escaping @Sendable (MusicScore, () -> Bool) -> [Float]? = { MusicSynth.render($0, until: $1) }
    ) {
        self.root = root
        self.themes = themes
        self.score = score
        self.synthesize = synthesize
    }

    /// `<root>/music-1/<id>.caf`, where theme `id` is kept. An id that is not a theme still names a file in that folder
    /// (every character but a–z, 0–9 and `-` becomes `_`), never one elsewhere.
    public nonisolated func url(for id: String) -> URL {
        let name = String(id.map { $0.isASCII && ($0.isLowercase || $0.isNumber || $0 == "-") ? $0 : "_" })
        return root.appending(path: MusicThemes.algorithm, directoryHint: .isDirectory)
            .appending(path: "\(name.isEmpty ? "_" : name).caf", directoryHint: .notDirectory)
    }

    /// The file of theme `id` if it is there and is the theme (our CAF with its frames, by its size and its first 68
    /// bytes; a link is not followed and is not); `nil` otherwise, and for an id that is not a theme. Reads 68 bytes
    /// (and, the first time for each id, builds its score to learn its length): what the preview asks before it plays a
    /// theme, which it leaves silent while this is `nil`.
    public nonisolated func cachedFile(for id: String) -> URL? {
        guard let frames = frames(of: id) else { return nil }
        let url = url(for: id)
        return MusicFile.isOurs(at: url, frames: frames) ? url : nil
    }

    /// The file of theme `id`, made first if it is not there or is not the theme (see the type). Throws
    /// `MusicLibraryError.unknownTheme` for an id that is not a theme, `.couldNotWrite` when its file cannot be written,
    /// and `CancellationError` if the caller is cancelled (at once when it was the last one waiting, which stops the
    /// work; once the work returns when another caller still waits for it).
    public func file(for id: String) async throws -> URL {
        guard let frames = frames(of: id) else { throw MusicLibraryError.unknownTheme(id) }
        let url = url(for: id)
        if MusicFile.isOurs(at: url, frames: frames) { return url }
        let task = join(id, url: url, frames: frames)
        let result = await withTaskCancellationHandler {
            await task.value
        } onCancel: {
            Task { await self.leave(id, task) }
        }
        if work[id]?.task == task { work[id] = nil }
        try Task.checkCancellation()
        if case .failure(let error) = result, error is CancellationError { throw CancellationError() }
        return try result.get()
    }

    /// How many callers wait for the work on `id`, for tests.
    func waiters(for id: String) -> Int {
        work[id]?.waiters ?? 0
    }

    // MARK: The work

    private func join(_ id: String, url: URL, frames: Int) -> Task<Result<URL, any Error>, Never> {
        if var entry = work[id] {
            entry.waiters += 1
            work[id] = entry
            return entry.task
        }
        let task = Task { await self.make(id, url: url, frames: frames) }
        work[id] = (task, 1)
        return task
    }

    /// A caller of `task` was cancelled: once none waits for it, it is cancelled, and the next caller starts anew.
    private func leave(_ id: String, _ task: Task<Result<URL, any Error>, Never>) {
        guard var entry = work[id], entry.task == task else { return }
        entry.waiters -= 1
        if entry.waiters > 0 {
            work[id] = entry
        } else {
            work[id] = nil
            task.cancel()
        }
    }

    private func make(_ id: String, url: URL, frames: Int) async -> Result<URL, any Error> {
        inFlight += 1
        defer { inFlight -= 1 }
        let stop = StopFlag()
        let score = self.score, synthesize = self.synthesize
        let (result, rendered) = await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                queue.async {
                    continuation.resume(returning: Self.produce(
                        id, url: url, frames: frames, score: score, synthesize: synthesize, stop: stop))
                }
            }
        } onCancel: {
            stop.set()
        }
        if rendered { syntheses += 1 }
        return result
    }

    /// Makes theme `id` at `url` unless it is already there (another library may have made it), on the library's queue.
    /// The result, and whether it rendered.
    private static func produce(
        _ id: String, url: URL, frames: Int, score: @Sendable (String) -> MusicScore?,
        synthesize: @Sendable (MusicScore, () -> Bool) -> [Float]?, stop: StopFlag
    ) -> (Result<URL, any Error>, rendered: Bool) {
        if MusicFile.isOurs(at: url, frames: frames) { return (.success(url), false) }
        guard let score = score(id) else { return (.failure(MusicLibraryError.unknownTheme(id)), false) }
        guard let samples = synthesize(score, { stop.isSet }), !stop.isSet else { return (.failure(CancellationError()), true) }
        guard samples.count == MusicFile.channels * frames, let temporary = try? ProjectCaches.temporaryFile(for: url) else {
            return (.failure(MusicLibraryError.couldNotWrite), true)
        }
        do {
            try MusicFile.write(interleaved: samples, to: temporary)
        } catch {
            return (.failure(MusicLibraryError.couldNotWrite), true)
        }
        // Nothing is moved into place once every caller left. (`commit` checks the current task, and there is none here.)
        if stop.isSet {
            unlink(temporary.path)
            return (.failure(CancellationError()), true)
        }
        guard (try? ProjectCaches.commit(temporary, to: url)) == true else {
            return (.failure(MusicLibraryError.couldNotWrite), true)
        }
        return (.success(url), true)
    }

    /// The frames of theme `id`, from its score the first time; `nil` if it is not one of the themes or its loop is not a
    /// whole number of frames.
    private nonisolated func frames(of id: String) -> Int? {
        guard themes.contains(id) else { return nil }
        if let known = knownFrames.withLock({ $0[id] }) { return known }
        guard let count = score(id)?.loopFrames else { return nil }
        knownFrames.withLock { $0[id] = count }
        return count
    }
}

/// Set once every caller of a piece of work left; read by the synthesis between blocks.
private final class StopFlag: Sendable {
    private let flag = Atomic(false)
    var isSet: Bool { flag.load(ordering: .relaxed) }
    func set() { flag.store(true, ordering: .relaxed) }
}
