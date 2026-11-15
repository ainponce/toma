// SPDX-License-Identifier: GPL-3.0-or-later
import Darwin
import Foundation

/// A path of a package that cannot be trusted. A package can come from anywhere (a shared folder, a
/// download), so its manifest and its folders are checked before anything follows them: a take ID with
/// `..`, or a symlink where a folder or a file of a take should be, would send writes outside the package.
public enum PackagePathError: Error, Equatable, Sendable, CustomStringConvertible {
    /// A take ID that is not `take-` and three or more digits.
    case invalidTakeID(String)
    /// A track ID that is not made of letters, digits and `-` only.
    case invalidTrackID(take: String, track: String)
    /// A segment whose `file` is not `takes/<take>/<track>/seg-NNNN.mov` for its own index.
    case invalidSegmentFile(take: String, track: String, file: String)
    /// An entry of a take, relative to the package root, that is a symlink or not the kind of file it must be.
    case unexpectedEntry(String)

    public var description: String {
        switch self {
        case .invalidTakeID(let id): "take ID \"\(id)\" is not take-NNN"
        case let .invalidTrackID(take, track): "track ID \"\(track)\" of \(take) has characters other than letters, digits and -"
        case let .invalidSegmentFile(take, track, file): "segment file \"\(file)\" of \(take)/\(track) is not where its index says"
        case .unexpectedEntry(let path): "\(path) is a symlink or not the kind of file it should be"
        }
    }
}

extension Manifest {
    /// Throws unless every take ID is `take-NNN` (three or more digits), every track ID is letters,
    /// digits and `-`, and every segment's `file` is exactly `takes/<take>/<track>/seg-NNNN.mov` for its
    /// index (1 or more), so no path built from the manifest can leave the package.
    public func validatePaths() throws(PackagePathError) {
        for take in takes { try take.validatePaths() }
    }
}

extension TakeRecord {
    /// `Manifest.validatePaths()` for this take.
    public func validatePaths() throws(PackagePathError) {
        try ProjectPackage.validateTakeID(id)
        for track in tracks {
            guard ProjectPackage.isValidTrackID(track.id) else { throw .invalidTrackID(take: id, track: track.id) }
            for segment in track.segments {
                guard segment.index >= 1,
                      segment.file == "takes/\(id)/\(track.id)/" + ProjectPackage.segmentFileName(index: segment.index)
                else { throw .invalidSegmentFile(take: id, track: track.id, file: segment.file) }
            }
        }
    }
}

extension ProjectPackage {
    /// Throws `invalidTakeID` unless `id` is `take-` and three or more digits.
    public static func validateTakeID(_ id: String) throws(PackagePathError) {
        let digits = id.utf8.dropFirst("take-".utf8.count)
        guard id.hasPrefix("take-"), digits.count >= 3, digits.allSatisfy({ (UInt8(ascii: "0")...UInt8(ascii: "9")).contains($0) })
        else { throw .invalidTakeID(id) }
    }

    /// Whether `id` is a track ID: one or more ASCII letters, digits and `-`.
    static func isValidTrackID(_ id: String) -> Bool {
        !id.isEmpty && id.utf8.allSatisfy { byte in
            switch byte {
            case UInt8(ascii: "a")...UInt8(ascii: "z"), UInt8(ascii: "A")...UInt8(ascii: "Z"),
                 UInt8(ascii: "0")...UInt8(ascii: "9"), UInt8(ascii: "-"):
                true
            default:
                false
            }
        }
    }

    /// `seg-0001.mov` for index 1.
    static func segmentFileName(index: Int) -> String {
        "seg-" + String(format: "%04d", index) + ".mov"
    }

    /// Throws `unexpectedEntry` if `takes/`, the folder of `take`, its `wallpapers/` or the folder of one of its
    /// tracks is a symlink or not a folder, or if its `recording.lock`, `events.jsonl` or `.reserve` is a symlink
    /// or not a regular file. Entries that do not exist are fine: a take may not have them yet. Reads nothing
    /// and changes nothing. The package's own path may go through symlinks (`/var` is one): only what is
    /// inside it is checked.
    public func checkLayout(of take: TakeRecord) throws(PackagePathError) {
        try ProjectPackage.validateTakeID(take.id)
        try check(takesURL, isDirectory: true)
        try check(takeDirectory(take.id), isDirectory: true)
        try check(wallpapersDirectory(take: take.id), isDirectory: true)
        for track in take.tracks where ProjectPackage.isValidTrackID(track.id) {
            try check(trackDirectory(take: take.id, track: track.id), isDirectory: true)
        }
        for file in [lockURL(take: take.id), eventsURL(take: take.id), reserveURL(take: take.id)] {
            try check(file, isDirectory: false)
        }
    }

    private func check(_ entry: URL, isDirectory: Bool) throws(PackagePathError) {
        var info = stat()
        guard lstat(entry.path, &info) == 0 else {
            if errno == ENOENT { return }
            throw .unexpectedEntry(relativeDescription(of: entry))
        }
        let type = info.st_mode & S_IFMT
        guard type == (isDirectory ? S_IFDIR : S_IFREG) else { throw .unexpectedEntry(relativeDescription(of: entry)) }
    }

    private func relativeDescription(of entry: URL) -> String {
        (try? relativePath(of: entry)) ?? entry.lastPathComponent
    }
}
