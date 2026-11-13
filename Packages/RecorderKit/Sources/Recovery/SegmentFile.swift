// SPDX-License-Identifier: GPL-3.0-or-later
import AVFoundation
import CoreMedia
import Darwin
import Foundation
import ProjectFormat

/// What a segment file holds, as AVFoundation reads it now. Reading never changes the file.
enum SegmentFile {
    /// Nothing at that path.
    case missing
    /// A file of 0 bytes, or one that opens without any media of its track's kind.
    case empty
    /// A non-empty file that can be opened but whose contents AVFoundation cannot read.
    case unreadable(bytes: Int64, error: any Error)
    /// `duration` of media of the track's kind can be read from `track` of `asset`. For a segment
    /// left open by a crash, that is everything up to its last complete fragment.
    case readable(asset: AVURLAsset, track: AVAssetTrack, duration: CMTime)

    /// Throws the `POSIXError` when the file exists but cannot be examined or opened for reading (for
    /// example `EACCES`): that says nothing about its contents, so it must not be recorded as them.
    static func inspect(_ url: URL, kind: TrackKind) async throws -> SegmentFile {
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
            let tracks = try await asset.loadTracks(withMediaType: kind == .display ? .video : .audio)
            guard let track = tracks.first, duration.isNumeric, duration > .zero else { return .empty }
            return .readable(asset: asset, track: track, duration: duration)
        } catch {
            return .unreadable(bytes: bytes, error: error)
        }
    }
}

extension ProjectPackage {
    /// The file a manifest path (relative to the package root) names.
    func fileURL(_ relativePath: String) -> URL {
        url.appendingPathComponent(relativePath, isDirectory: false)
    }
}
