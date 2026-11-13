// SPDX-License-Identifier: GPL-3.0-or-later
import AVFoundation
import CoreMedia
import Foundation
import ProjectFormat

/// What a segment file holds, as AVFoundation reads it now. Reading never changes the file.
enum SegmentFile {
    /// Nothing at that path.
    case missing
    /// A file of 0 bytes, or one that opens without any media of its track's kind.
    case empty
    /// A non-empty file that cannot be opened.
    case unreadable(bytes: Int64, error: any Error)
    /// `duration` of media of the track's kind can be read from `track` of `asset`. For a segment
    /// left open by a crash, that is everything up to its last complete fragment.
    case readable(asset: AVURLAsset, track: AVAssetTrack, duration: CMTime)

    static func inspect(_ url: URL, kind: TrackKind) async -> SegmentFile {
        let bytes: Int64
        do {
            let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
            bytes = (attributes[.size] as? NSNumber)?.int64Value ?? 0
        } catch let error as CocoaError where error.code == .fileReadNoSuchFile {
            return .missing
        } catch {
            return .unreadable(bytes: 0, error: error)
        }
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
