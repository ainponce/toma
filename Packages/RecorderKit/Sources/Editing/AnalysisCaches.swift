// SPDX-License-Identifier: GPL-3.0-or-later
import Darwin
import Foundation
import ProjectFormat
import Synchronization

/// The folders of the project's cache folder that hold what phase 2's analysis makes (design of phase 2, §10), each
/// written by the job of the same name and read by the render, the mix or the editor.
public enum AnalysisCacheFolder: String, Sendable, CaseIterable {
    /// The camera's person masks (`personMask-1`), one movie per segment.
    case masks
    /// The camera's face tracks (`faceTrack-1`), one JSON per segment.
    case faces
    /// The microphone's sound without noise (`soundIsolation-2`), one CAF per segment.
    case clean
    /// The loudness of an audio track (`loudness-1`), one JSON per segment.
    case loudness
    /// The sensitive data found on the screen of a take (`sensitiveScan-1`), one JSON per take.
    case scan
}

/// Which bytes a segment file holds, as far as a cache cares: the root of its name (`seg-0001` for `seg-0001.mov`), its
/// size and its modification date in nanoseconds since 1970, by `lstat`, which never follows a link. A cache made from
/// a segment carries its identity in its name (plan decision 17), so a segment that is written again (crash recovery
/// closing it, a copy of the package that kept its bytes but not its date) is analysed again, and nothing compares
/// contents.
public struct SegmentIdentity: Equatable, Sendable {
    public var stem: String
    public var bytes: Int64
    public var modified: Int64

    public init(stem: String, bytes: Int64, modified: Int64) {
        self.stem = stem
        self.bytes = bytes
        self.modified = modified
    }

    /// The identity of the file of `segment` where `package` is now; `nil` if nothing is there, if it is a symlink
    /// (never followed) or anything else that is not a regular file, or if it cannot be examined.
    public static func of(_ segment: SegmentRecord, in package: ProjectPackage) -> SegmentIdentity? {
        let url = package.fileURL(segment.file)
        var info = stat()
        guard lstat(url.path, &info) == 0, info.st_mode & S_IFMT == S_IFREG else { return nil }
        let modified = Int64(info.st_mtimespec.tv_sec) * 1_000_000_000 + Int64(info.st_mtimespec.tv_nsec)
        return SegmentIdentity(stem: url.deletingPathExtension().lastPathComponent, bytes: Int64(info.st_size), modified: modified)
    }

    /// `<stem>-<bytes>-<modified>`: `seg-0001-48213377-1763561234123456789`.
    public var name: String { "\(stem)-\(bytes)-\(modified)" }
}

// MARK: - The analysis caches

extension ProjectCaches {
    /// `<directory>/<folder>/`.
    public func folder(_ folder: AnalysisCacheFolder) -> URL {
        directory.appending(path: folder.rawValue, directoryHint: .isDirectory)
    }

    /// The cache file of `algorithm` (with its version: `personMask-1`) for `segment` of track `track` of take `take`:
    /// `<folder>/<take>/<track>/<segment.name>-<algorithm>.<extension>` (plan decision 17). `nil` unless `take`, `track`
    /// and the file's name are each one name (not empty, `.` or `..`, without `/` or NUL), so no id read from a package
    /// can name a file outside `folder`.
    public func analysisFile(
        _ folder: AnalysisCacheFolder, take: String, track: String, segment: SegmentIdentity, algorithm: String,
        extension: String
    ) -> URL? {
        let name = "\(segment.name)-\(algorithm).\(`extension`)"
        guard Self.isOneName(take), Self.isOneName(track), Self.isOneName(name) else { return nil }
        return self.folder(folder).appending(path: take, directoryHint: .isDirectory)
            .appending(path: track, directoryHint: .isDirectory)
            .appending(path: name, directoryHint: .notDirectory)
    }

    /// The sensitive data found in take `take` by `algorithm` (`sensitiveScan-1`): `scan/<take>-<algorithm>.json`. A
    /// scan looks at every screen track of the take, so it is one file per take, whose name carries no segment's
    /// identity: the job that makes it decides when it is stale. `nil` unless the name is one name.
    public func scanFile(take: String, algorithm: String) -> URL? {
        let name = "\(take)-\(algorithm).json"
        guard Self.isOneName(take), Self.isOneName(name) else { return nil }
        return folder(.scan).appending(path: name, directoryHint: .notDirectory)
    }

    /// A path to write the cache file `url` to before `commit(_:to:)` moves it there: in the same folder, made if macOS
    /// emptied it, hidden, and with `url`'s extension last, so a writer that goes by it (`AVAudioFile`) writes the right
    /// kind of file: `.<name>.<UUID>.tmp.<extension>`. Nothing is at that path yet. A reader never looks there. The
    /// first time a folder is used in a session, temporaries a crash left in it that are over an hour old are removed.
    /// The temporary's whole name is at most 255 bytes (a file system's limit): a long `name` is cut in the temporary's
    /// name only, never in `url`'s. Throws if the folder cannot be made.
    public static func temporaryFile(for url: URL) throws -> URL {
        let folder = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        if swept.withLock({ $0.insert(folder.path).inserted }) { removeStaleTemporaries(in: folder) }
        let stem = url.deletingPathExtension().lastPathComponent
        let suffix = url.pathExtension.isEmpty ? "tmp" : "tmp.\(url.pathExtension)"
        let id = UUID().uuidString
        // ".", the stem, ".", the id, ".", the suffix.
        let room = max(0, maxNameBytes - (1 + 1 + id.utf8.count + 1 + suffix.utf8.count))
        return folder.appending(path: ".\(cut(stem, toBytes: room)).\(id).\(suffix)", directoryHint: .notDirectory)
    }

    /// The longest name of a file the cache's volumes take, in bytes.
    private static let maxNameBytes = 255
    /// The folders whose old temporaries were looked for in this session.
    private static let swept = Mutex<Set<String>>([])

    /// `text` cut to at most `bytes` bytes of UTF-8, at a character's end.
    private static func cut(_ text: String, toBytes bytes: Int) -> String {
        var used = 0
        var result = ""
        for character in text {
            used += String(character).utf8.count
            if used > bytes { break }
            result.append(character)
        }
        return result
    }

    /// Removes from `folder` the hidden temporaries (`.<name>.<UUID>.tmp[.<extension>]`) last modified before
    /// `now - age` (a link itself, by `lstat`, never what it points to). One directory listing.
    static func removeStaleTemporaries(in folder: URL, olderThan age: TimeInterval = 3600, now: Date = Date()) {
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: folder.path) else { return }
        for name in names where name.hasPrefix(".") && (name.hasSuffix(".tmp") || name.contains(".tmp.")) {
            let path = folder.appending(path: name, directoryHint: .notDirectory).path
            var info = stat()
            guard lstat(path, &info) == 0, info.st_mode & S_IFMT != S_IFDIR else { continue }
            if now.timeIntervalSince1970 - TimeInterval(info.st_mtimespec.tv_sec) > age { unlink(path) }
        }
    }

    /// Moves the finished `temporary` (from `temporaryFile(for:)`) over `url` with `rename(2)`, so a reader sees the
    /// old file or the whole new one, never part of one; its bytes are ordered before the rename (`F_BARRIERFSYNC`), so
    /// after a power loss the name holds them whole or is not there. Not synced further: a cache can be made again.
    ///
    /// Commits nothing and returns `false` if `temporary` is not there, or is a symlink (never followed) or anything
    /// else that is not a regular file, or if the move fails; whatever was at `temporary` is then removed (a link, not
    /// what it points to) and `url` is left as it was. Whether `url` now holds it.
    ///
    /// Throws `CancellationError` if the task is cancelled (a job whose editor closed), and removes `temporary`:
    /// nothing is written after that.
    @discardableResult
    public static func commit(_ temporary: URL, to url: URL) throws -> Bool {
        if Task.isCancelled {
            unlink(temporary.path)
            throw CancellationError()
        }
        let fd = open(temporary.path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        guard fd >= 0 else {
            unlink(temporary.path)
            return false
        }
        var info = stat()
        let ready = fstat(fd, &info) == 0 && info.st_mode & S_IFMT == S_IFREG && (try? DurableFile.barrierSync(fd)) != nil
        close(fd)
        guard ready, rename(temporary.path, url.path) == 0 else {
            unlink(temporary.path)
            return false
        }
        return true
    }

    /// The bytes of the cache file `url`, or `nil` if it is not there, is not a regular file (a symlink is not followed,
    /// a FIFO is not waited on) or cannot be read.
    public static func readAnalysis(_ url: URL) -> Data? {
        read(url)
    }

    /// Writes `data` to the cache file `url` whole, through `temporaryFile(for:)` and `commit(_:to:)`; a write that
    /// fails leaves nothing. Whether it was written. Never on the main thread.
    @discardableResult
    public static func writeAnalysis(_ data: Data, to url: URL) -> Bool {
        guard let temporary = try? temporaryFile(for: url) else { return false }
        let fd = open(temporary.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o644)
        guard fd >= 0 else { return false }
        let written = data.withUnsafeBytes { buffer -> Bool in
            guard var next = buffer.baseAddress else { return true }
            var remaining = buffer.count
            while remaining > 0 {
                let count = Darwin.write(fd, next, remaining)
                if count < 0 {
                    if errno == EINTR { continue }
                    return false
                }
                next += count
                remaining -= count
            }
            return true
        }
        guard close(fd) == 0, written else {
            unlink(temporary.path)
            return false
        }
        return (try? commit(temporary, to: url)) ?? false
    }

    /// Whether `name` names one entry of a folder: not empty, `.` or `..`, and without `/` or NUL.
    static func isOneName(_ name: String) -> Bool {
        !name.isEmpty && name != "." && name != ".." && !name.utf8.contains(UInt8(ascii: "/")) && !name.utf8.contains(0)
    }
}
