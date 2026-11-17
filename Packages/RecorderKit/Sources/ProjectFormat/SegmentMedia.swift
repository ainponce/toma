// SPDX-License-Identifier: GPL-3.0-or-later
import AVFoundation
import CoreMedia
import Darwin
import Foundation

extension TrackKind {
    /// Whether the track's segments hold video; the others hold audio.
    public var isVideo: Bool {
        switch self {
        case .display, .window, .camera: true
        case .microphone, .systemAudio: false
        }
    }

    /// Whether the track records what is on screen: a display or a window.
    public var isScreen: Bool {
        switch self {
        case .display, .window: true
        case .camera, .microphone, .systemAudio: false
        }
    }
}

/// Whether a segment can hold media, from its manifest record and the file system alone: the file is never
/// opened. The screen reader and the microphone timeline leave out every segment that is not `present`
/// before reading anything.
public enum SegmentAvailability: Equatable, Sendable {
    /// Something with bytes is at the segment's path: only reading it tells whether it holds media.
    case present
    /// Nothing is at the segment's path.
    case missing
    /// Crash recovery found no sample in it (`SegmentEndReason.empty`), or its file has 0 bytes.
    case empty
    /// Crash recovery could not read its file of `bytes` bytes (`SegmentEndReason.unreadable`).
    case unreadable(bytes: Int64)

    /// By the segment's `endReason` (`empty` and `unreadable` say it all), then by `lstat` of its path, which
    /// never follows a symlink there. An `lstat` that fails with anything but `ENOENT` (for example `EACCES`)
    /// says nothing about the file, so the segment is `present` and reading it reports the error.
    public static func classify(_ segment: SegmentRecord, in package: ProjectPackage) -> SegmentAvailability {
        switch segment.endReason {
        case .empty?:
            return .empty
        case .unreadable(let bytes)?:
            return .unreadable(bytes: bytes)
        default:
            break
        }
        let path = package.fileURL(segment.file).path
        var info = stat()
        guard lstat(path, &info) == 0 else { return errno == ENOENT ? .missing : .present }
        return info.st_size == 0 ? .empty : .present
    }
}

/// What a segment file holds, as AVFoundation reads it now. Reading never changes the file. Crash recovery and
/// the verifier inspect files with it.
public enum SegmentMedia {
    /// Nothing at that path.
    case missing
    /// A file of 0 bytes, or one that opens without any media of its track's kind.
    case empty
    /// A non-empty file that can be opened but whose contents AVFoundation cannot read.
    case unreadable(bytes: Int64, error: any Error)
    /// `duration` of media of the track's kind (video when `kind.isVideo`, audio otherwise) can be read from
    /// `track` of `asset`. For a segment left open by a crash, that is everything up to its last complete
    /// fragment.
    case readable(asset: AVURLAsset, track: AVAssetTrack, duration: CMTime)

    /// Throws the `POSIXError` when the file exists but cannot be examined or opened for reading (for
    /// example `EACCES`): that says nothing about its contents, so it must not be recorded as them.
    public static func inspect(_ url: URL, kind: TrackKind) async throws -> SegmentMedia {
        var info = stat()
        guard stat(url.path, &info) == 0 else {
            if errno == ENOENT { return .missing }
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        let fd = open(url.path, O_RDONLY | O_CLOEXEC)
        guard fd >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        close(fd)
        let bytes = Int64(info.st_size)
        guard bytes > 0 else { return .empty }

        let asset = AVURLAsset(url: url)
        do {
            let duration = try await asset.load(.duration)
            let tracks = try await asset.loadTracks(withMediaType: kind.isVideo ? .video : .audio)
            guard let track = tracks.first, duration.isNumeric, duration > .zero else { return .empty }
            return .readable(asset: asset, track: track, duration: duration)
        } catch {
            return .unreadable(bytes: bytes, error: error)
        }
    }
}

extension ProjectPackage {
    /// The file a manifest path (relative to the package root) names, where the package is now (`currentURL`).
    public func fileURL(_ relativePath: String) -> URL {
        currentURL.appendingPathComponent(relativePath, isDirectory: false)
    }
}
