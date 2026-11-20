// SPDX-License-Identifier: GPL-3.0-or-later
import AVFoundation
import CoreMedia
import Darwin
import Foundation
import ProjectFormat

/// A clip or a sound of the user's own (phase 3 design §5.4, §7.7; base plan decision 13): judged by whether it plays
/// before anything is copied, then copied into `assets/` as an image is (`AssetImport.place`).
extension AssetImport {
    /// The codecs a clip is taken in: H.264, HEVC (with alpha too) and ProRes, the ones AVFoundation decodes on every Mac
    /// Toma runs on.
    static let clipCodecs: Set<CMVideoCodecType> = [
        kCMVideoCodecType_H264, kCMVideoCodecType_HEVC, kCMVideoCodecType_HEVCWithAlpha,
        kCMVideoCodecType_AppleProRes4444XQ, kCMVideoCodecType_AppleProRes4444, kCMVideoCodecType_AppleProRes422HQ,
        kCMVideoCodecType_AppleProRes422, kCMVideoCodecType_AppleProRes422LT, kCMVideoCodecType_AppleProRes422Proxy,
    ]

    /// What `EditSession.importAsset` says at once for the clip or the sound at `url` as `kind` (`.video` or `.audio`),
    /// before anything is written (or a legacy package upgraded) for it: `nil` if it can be copied, `.notPlayable` if it
    /// is not named as a file of its kind (judged by its name alone, never opened), is not there, is not a regular file
    /// (never waited on: a FIFO is told by `fstat` first), is larger than `kind`'s limit, or is not one AVFoundation
    /// reads (`AVURLAsset`: readable, with a duration) with a track of its kind with a duration, of H.264, HEVC or
    /// ProRes for a clip (`clipCodecs`). `nil` for an image or a `.cube`, which `refusal(of:as:)` judges.
    ///
    /// Off the main thread and the caller's actor: AVFoundation reads the file meanwhile.
    public static func mediaRefusal(of url: URL, as kind: AssetKind) async -> AssetImportOutcome? {
        guard kind.isMedia else { return nil }
        do {
            let source = try openSource(url, as: kind)
            close(source.fd)
        } catch {
            return .notPlayable
        }
        let asset = AVURLAsset(url: url)
        do {
            let (duration, readable) = try await asset.load(.duration, .isReadable)
            guard readable, duration.isNumeric, duration > .zero else { return .notPlayable }
            let tracks = try await asset.loadTracks(withMediaType: kind == .video ? .video : .audio)
            for track in tracks {
                let (range, formats) = try await track.load(.timeRange, .formatDescriptions)
                guard range.duration.isNumeric, range.duration > .zero else { continue }
                if kind == .audio || formats.contains(where: { clipCodecs.contains(CMFormatDescriptionGetMediaSubType($0)) }) {
                    return nil
                }
            }
            return .notPlayable
        } catch {
            return .notPlayable
        }
    }
}
