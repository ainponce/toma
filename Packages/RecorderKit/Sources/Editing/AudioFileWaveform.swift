// SPDX-License-Identifier: GPL-3.0-or-later
import AVFoundation
import CoreMedia
import Darwin
import Foundation

/// The outline of a whole sound file the timeline draws (phase 3 design §7.4 and §7.7): a theme of the music library or
/// an imported sound decoded into the caches (`MusicFile`), or an imported clip's file with its sound. The same pairs
/// as `Waveform` (the minimum and maximum of every 10 ms, over every channel), pair *k* covering the file's own
/// *k* × 10 ms from its start.
///
/// The file is read as `WaveformCache` reads a segment: its first audio track at its own rate, a buffer at a time, on a
/// dispatch queue of its own (never the main thread nor a thread of Swift's cooperative pool, which AVFoundation's
/// blocking reads would starve), and never through a link (`lstat`: a link or anything that is not a regular file is
/// not read). Nothing is written.
public enum AudioFileWaveform {
    /// One file at a time.
    private static let queue = DispatchQueue(label: "dev.toma.Toma.AudioFileWaveform", qos: .utility)

    /// The waveform of the sound of the file at `url`, 100 pairs a second from its start (up to 24 h); empty if it is
    /// not a regular file, has no sound that can be read, or the caller is cancelled before it is done.
    public static func waveform(of url: URL) async -> Waveform {
        var info = stat()
        guard lstat(url.path, &info) == 0, info.st_mode & S_IFMT == S_IFREG, !Task.isCancelled else { return Waveform(pairs: []) }
        let asset = AVURLAsset(url: url)
        guard let audio = try? await asset.loadTracks(withMediaType: .audio).first,
            let format = try? await audio.load(.formatDescriptions).first,
            let description = CMAudioFormatDescriptionGetStreamBasicDescription(format)?.pointee,
            description.mSampleRate >= Double(Waveform.pairsPerSecond), description.mChannelsPerFrame > 0,
            !Task.isCancelled
        else { return Waveform(pairs: []) }
        let input = DecoderInput(asset: asset, track: audio, sampleRate: description.mSampleRate)
        let cancelled = DecodingCancellation()
        let decoded = await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                queue.async { continuation.resume(returning: SegmentEnvelope.decode(input, cancelled: cancelled)) }
            }
        } onCancel: {
            cancelled.cancel()
        }
        guard let decoded, !Task.isCancelled else { return Waveform(pairs: []) }
        return Waveform(pairs: Array(decoded.pairs.prefix(WaveformCache.maxPairs)))
    }
}
