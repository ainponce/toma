// SPDX-License-Identifier: GPL-3.0-or-later
import AVFoundation
import CoreMedia
import Foundation
import Synchronization

/// What the files for external editors say of the video they sit next to (plan 4c, decision 11): its size, frame rate,
/// frames, audio and alpha. The exporter knows them as it writes the video (task X3); `ExternalEditorExport.write` reads
/// them from the file (`read(_:)`).
struct VideoFacts: Equatable, Sendable {
    /// The video, as given: the FCPXML's `media-rep` names it by this URL, the JSON by its name.
    var url: URL
    /// Width and height, in pixels.
    var size: SIMD2<Int>
    var frameRate: Int
    var frameCount: Int
    /// The channels of its audio track; `nil` without one.
    var audioChannels: Int?
    /// Whether its video keeps an alpha channel (HEVC with alpha, ProRes 4444 with alpha).
    var hasAlpha: Bool

    /// How long `read(_:)` waits for AVFoundation to load the file's tracks, as `TrackFrameReader.trackLoadTimeout`.
    static let loadTimeout = 10.0

    /// The facts of the movie at `url`: its first video track's natural size, nominal frame rate (rounded), frames (its
    /// duration at that rate, rounded) and alpha (`ContainsAlphaChannel`, HEVC with alpha, or ProRes 4444 of depth 32), and
    /// its first audio track's channels. AVFoundation loads them on a task of its own while the caller waits, at most
    /// `loadTimeout` (`AssetFrameReader.loadTrack`'s way: never on a Swift concurrency thread, nor the main thread).
    /// - Throws: `ExportError.writerFailed` for a file AVFoundation cannot open, one without a video track or a frame rate,
    ///   and one that takes longer than `loadTimeout` to load.
    static func read(_ url: URL) throws -> VideoFacts {
        let loaded = Loaded()
        let done = DispatchSemaphore(value: 0)
        Task.detached(priority: .userInitiated) {
            defer { done.signal() }
            loaded.set(await load(url))
        }
        guard done.wait(timeout: .now() + loadTimeout) == .success else {
            throw ExportError.writerFailed("loading \(url.lastPathComponent) took more than \(Int(loadTimeout)) s")
        }
        guard let result = loaded.get() else { throw ExportError.writerFailed("cannot read \(url.lastPathComponent)") }
        return try result.get()
    }

    private static func load(_ url: URL) async -> Result<VideoFacts, ExportError> {
        let name = url.lastPathComponent
        do {
            let asset = AVURLAsset(url: url)
            guard let video = try await asset.loadTracks(withMediaType: .video).first else {
                return .failure(.writerFailed("\(name) has no video track"))
            }
            let (natural, nominal, range, formats) = try await video.load(.naturalSize, .nominalFrameRate, .timeRange, .formatDescriptions)
            var rate = Double(nominal)
            if !(rate > 0) {
                let frame = try await video.load(.minFrameDuration)
                rate = frame.isValid && frame.seconds > 0 ? 1 / frame.seconds : 0
            }
            let frameRate = rate.isFinite ? Int(rate.rounded()) : 0
            guard frameRate > 0 else { return .failure(.writerFailed("\(name) has no frame rate")) }
            let seconds = range.duration.seconds
            let frameCount = seconds.isFinite ? Int((seconds * Double(frameRate)).rounded()) : 0
            var channels: Int?
            if let audio = try await asset.loadTracks(withMediaType: .audio).first {
                let format = try await audio.load(.formatDescriptions).first
                channels = format.flatMap { CMAudioFormatDescriptionGetStreamBasicDescription($0)?.pointee.mChannelsPerFrame }
                    .map(Int.init) ?? 0
            }
            return .success(VideoFacts(
                url: url, size: SIMD2(Int(natural.width.rounded()), Int(natural.height.rounded())), frameRate: frameRate,
                frameCount: frameCount, audioChannels: channels, hasAlpha: formats.first.map(hasAlpha) ?? false))
        } catch {
            return .failure(.writerFailed("cannot read \(name): \(error)"))
        }
    }

    /// Whether `format` describes video with alpha: it says so (`ContainsAlphaChannel`), or it is HEVC with alpha, or
    /// ProRes 4444 (or XQ) of depth 32.
    private static func hasAlpha(_ format: CMFormatDescription) -> Bool {
        if let says = CMFormatDescriptionGetExtension(format, extensionKey: kCMFormatDescriptionExtension_ContainsAlphaChannel)
            as? Bool
        {
            return says
        }
        switch CMFormatDescriptionGetMediaSubType(format) {
        case kCMVideoCodecType_HEVCWithAlpha:
            return true
        case kCMVideoCodecType_AppleProRes4444, kCMVideoCodecType_AppleProRes4444XQ:
            let depth = CMFormatDescriptionGetExtension(format, extensionKey: kCMFormatDescriptionExtension_Depth) as? Int
            return depth == 32
        default:
            return false
        }
    }
}

/// What `VideoFacts.read` loaded, handed from the loading task to the waiting caller.
private final class Loaded: Sendable {
    private let result = Mutex<Result<VideoFacts, ExportError>?>(nil)

    func set(_ value: Result<VideoFacts, ExportError>) {
        result.withLock { $0 = value }
    }

    func get() -> Result<VideoFacts, ExportError>? {
        result.withLock { $0 }
    }
}
