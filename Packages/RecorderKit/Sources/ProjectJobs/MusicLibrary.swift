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

/// The themes of the music library on disk (design §7.6, plan decision 4): `<root>/music-1/<id>-<fingerprint>.caf`, in
/// the app's cache (`~/Library/Caches/dev.toma.Toma/Music`), made the first time they are asked for and kept. A theme
/// always comes out the same bytes (`MusicSynth`), so if macOS empties the cache it is made again, the same, and whoever
/// needs it waits.
///
/// - The name carries the theme's `MusicScore.fingerprint` (its score and the engine's version), so a file made from
///   another score — a placeholder, an earlier tuning of the theme, an older engine — is never taken for it: the theme
///   is made again under its new name, and the files of its other versions are removed.
/// - A file is the theme only if it is our CAF (`MusicFile`) with exactly the theme's frames, by its size and its 68
///   bytes; anything else at its name (cut short, another file, a link, never followed) is not, and is replaced.
/// - A theme still marked `isPlaceholder` is never cached: it is made once per library, in a folder of its own under
///   the system's temporary folder that the library removes when it goes, and made again by the next one.
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

    /// What the library knows of a theme from its score, worked out once.
    private struct Theme: Sendable {
        var frames: Int
        var fingerprint: String
        var isPlaceholder: Bool
    }

    private let root: URL
    /// Where placeholders go: never the cache.
    private let scratch: URL
    private let themes: [String]
    private let score: @Sendable (String) -> MusicScore?
    private let synthesize: @Sendable (MusicScore, () -> Bool) -> [Float]?
    private let known = Mutex<[String: Theme]>([:])
    private let queue = DispatchQueue(label: "dev.toma.Toma.MusicLibrary", qos: .utility)
    private var work: [String: (task: Task<Result<URL, any Error>, Never>, waiters: Int)] = [:]
    /// How many themes were rendered to the end (a cancelled synthesis does not count), and how many pieces of work have
    /// not returned yet, for tests.
    private(set) var syntheses = 0
    private(set) var inFlight = 0

    public init(root: URL = MusicLibrary.defaultRoot) {
        self.init(root: root, themes: MusicThemes.ids, score: MusicThemes.score)
    }

    /// A library of the themes `themes` whose scores `score` gives, made by `synthesize` (which gets a function that says
    /// whether to stop), with its placeholders in `scratch`: for tests.
    init(
        root: URL, themes: [String], score: @escaping @Sendable (String) -> MusicScore?,
        synthesize: @escaping @Sendable (MusicScore, () -> Bool) -> [Float]? = { MusicSynth.render($0, until: $1) },
        scratch: URL? = nil
    ) {
        self.root = root
        self.scratch = scratch ?? FileManager.default.temporaryDirectory
            .appending(path: "dev.toma.Toma.music-\(UUID().uuidString)", directoryHint: .isDirectory)
        self.themes = themes
        self.score = score
        self.synthesize = synthesize
    }

    deinit {
        try? FileManager.default.removeItem(at: scratch)
    }

    /// Where theme `id` is kept: `<root>/music-1/<id>-<fingerprint>.caf`, or the same name in the library's own temporary
    /// folder for a placeholder. Builds the theme's score the first time for each id. An id that is not a theme names
    /// `<root>/music-1/<id>.caf` (every character but a–z, 0–9 and `-` becomes `_`), never a file elsewhere.
    public nonisolated func url(for id: String) -> URL {
        let name = Self.safeName(id)
        guard let theme = theme(id) else { return folder(placeholder: false).appending(path: "\(name).caf", directoryHint: .notDirectory) }
        return folder(placeholder: theme.isPlaceholder)
            .appending(path: "\(name)-\(theme.fingerprint).caf", directoryHint: .notDirectory)
    }

    /// The file of theme `id` if it is there and is the theme (our CAF with its frames, under its fingerprint, by its size
    /// and its first 68 bytes; a link is not followed and is not); `nil` otherwise, and for an id that is not a theme.
    /// Reads 68 bytes (and, the first time for each id, builds its score): what the preview asks before it plays a
    /// theme, which it leaves silent while this is `nil`.
    public nonisolated func cachedFile(for id: String) -> URL? {
        guard let theme = theme(id) else { return nil }
        let url = url(for: id)
        return MusicFile.isOurs(at: url, frames: theme.frames) ? url : nil
    }

    /// The file of theme `id`, made first if it is not there or is not the theme (see the type). Throws
    /// `MusicLibraryError.unknownTheme` for an id that is not a theme, `.couldNotWrite` when its file cannot be written,
    /// and `CancellationError` if the caller is cancelled (at once when it was the last one waiting, which stops the
    /// work; once the work returns when another caller still waits for it).
    public func file(for id: String) async throws -> URL {
        guard let theme = theme(id) else { throw MusicLibraryError.unknownTheme(id) }
        let url = url(for: id)
        if MusicFile.isOurs(at: url, frames: theme.frames) { return url }
        let task = join(id, url: url, theme: theme)
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

    private func join(_ id: String, url: URL, theme: Theme) -> Task<Result<URL, any Error>, Never> {
        if var entry = work[id] {
            entry.waiters += 1
            work[id] = entry
            return entry.task
        }
        let task = Task { await self.make(id, url: url, theme: theme) }
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

    private func make(_ id: String, url: URL, theme: Theme) async -> Result<URL, any Error> {
        inFlight += 1
        defer { inFlight -= 1 }
        let stop = StopFlag()
        let score = self.score, synthesize = self.synthesize
        let (result, rendered) = await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                queue.async {
                    continuation.resume(returning: Self.produce(
                        id, url: url, theme: theme, score: score, synthesize: synthesize, stop: stop))
                }
            }
        } onCancel: {
            stop.set()
        }
        if rendered { syntheses += 1 }
        return result
    }

    /// Makes theme `id` at `url` unless it is already there (another library may have made it), on the library's queue,
    /// and removes the files of its other versions next to it. The result, and whether it rendered to the end.
    private static func produce(
        _ id: String, url: URL, theme: Theme, score: @Sendable (String) -> MusicScore?,
        synthesize: @Sendable (MusicScore, () -> Bool) -> [Float]?, stop: StopFlag
    ) -> (Result<URL, any Error>, rendered: Bool) {
        if MusicFile.isOurs(at: url, frames: theme.frames) { return (.success(url), false) }
        guard let score = score(id) else { return (.failure(MusicLibraryError.unknownTheme(id)), false) }
        guard let samples = synthesize(score, { stop.isSet }), !stop.isSet else { return (.failure(CancellationError()), false) }
        guard samples.count == MusicFile.channels * theme.frames, let temporary = try? ProjectCaches.temporaryFile(for: url) else {
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
        removeOtherVersions(of: safeName(id), keeping: url)
        return (.success(url), true)
    }

    /// Removes from `url`'s folder the files `<name>-<16 hex digits>.caf` but `url`: the theme as other scores or engines
    /// made it. A link is removed itself, never what it points to.
    private static func removeOtherVersions(of name: String, keeping url: URL) {
        let folder = url.deletingLastPathComponent()
        guard let entries = try? FileManager.default.contentsOfDirectory(atPath: folder.path) else { return }
        let prefix = "\(name)-", suffix = ".caf"
        for entry in entries where entry != url.lastPathComponent && entry.hasPrefix(prefix) && entry.hasSuffix(suffix) {
            let digits = entry.dropFirst(prefix.count).dropLast(suffix.count)
            guard digits.count == 16, digits.allSatisfy({ $0.isHexDigit && !$0.isUppercase }) else { continue }
            unlink(folder.appending(path: entry, directoryHint: .notDirectory).path)
        }
    }

    // MARK: Names

    /// What the library knows of theme `id`, from its score the first time; `nil` if it is not one of the themes or its
    /// loop is not a whole number of frames.
    private nonisolated func theme(_ id: String) -> Theme? {
        guard themes.contains(id) else { return nil }
        if let theme = known.withLock({ $0[id] }) { return theme }
        guard let score = score(id), let frames = score.loopFrames else { return nil }
        let theme = Theme(frames: frames, fingerprint: score.fingerprint, isPlaceholder: score.isPlaceholder)
        known.withLock { $0[id] = theme }
        return theme
    }

    /// `<root>/music-1/`, or `<scratch>/music-1/` for a placeholder.
    private nonisolated func folder(placeholder: Bool) -> URL {
        (placeholder ? scratch : root).appending(path: MusicThemes.algorithm, directoryHint: .isDirectory)
    }

    /// `id` with every character but a–z, 0–9 and `-` as `_`: always one name.
    private static func safeName(_ id: String) -> String {
        let name = String(id.map { $0.isASCII && ($0.isLowercase || $0.isNumber || $0 == "-") ? $0 : "_" })
        return name.isEmpty ? "_" : name
    }
}

/// Set once every caller of a piece of work left; read by the synthesis between blocks.
private final class StopFlag: Sendable {
    private let flag = Atomic(false)
    var isSet: Bool { flag.load(ordering: .relaxed) }
    func set() { flag.store(true, ordering: .relaxed) }
}
