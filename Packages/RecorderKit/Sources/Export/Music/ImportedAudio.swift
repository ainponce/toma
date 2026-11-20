// SPDX-License-Identifier: GPL-3.0-or-later
import AVFoundation
import Darwin
import Foundation
import ProjectFormat

/// What `ImportedAudio.decode` throws besides `CancellationError` and the `POSIXError` of a write that failed.
public enum ImportedAudioError: Error, Equatable, Sendable {
    /// The file is no sound to decode: not there, a link (never followed), not a regular file, empty, without an audio
    /// track AVFoundation can decode, or one of which nothing decodes.
    case notAudio
    /// Decoding stopped partway (a damaged file, a read that failed), for the reason given. Nothing is kept: the next
    /// decoding tries again.
    case readingStopped(String)
}

/// A sound of the user's own as music (phase 3 design §7.7, plan 3c decision 6): its first audio track decoded once to
/// the music's own file (`MusicFile`: Float32 LPCM, little-endian, two channels interleaved, 48 kHz, only `desc` and
/// `data`), which the mix reads; the mix never reads the asset. Only its first `maximumFrames` frames (30 min) are kept.
///
/// - **Channels** as `AudioTrackTimeline` takes a file's: a mono sound goes into both channels, a stereo one as it is,
///   and one of more channels is mixed down with every channel at unity gain into each, clipped to full scale
///   (AVFoundation's own downmix gives silence for a discrete layout).
/// - **Rate.** The decoder resamples any rate to 48 kHz. Its resampler leaves out its last few frames (on macOS 26, 17
///   from 44.1 kHz and 33 from 22.05 kHz, a fraction of a millisecond): a sound that decodes to within `lengthSlack`
///   frames of its length (its track's duration, the precise one) is made exactly that long, padded with silence or
///   cut, so the file lasts what the sound does and a loop of it keeps time.
public enum ImportedAudio {
    /// The id of the decoding, with its version: it names the cache file (`<asset>-importedAudio-1.caf`), so another
    /// decoding is another file.
    public static let algorithm = "importedAudio-1"
    /// 30 min at 48 kHz.
    public static let maximumFrames = 86_400_000
    /// How far from its track's duration a decoded sound may end and still be made exactly that long: 4 096 frames
    /// (85 ms), far more than the resampler leaves out and far less than a file whose header misstates its length.
    static let lengthSlack = 4_096

    /// Decodes the sound at `url` to a new file at `destination`, in pieces as it goes (never the whole sound in memory),
    /// on a thread of its own once a decoding slot is free (`DecodingSlots`), never on Swift's cooperative pool, nor on
    /// the main thread. The file is written whole before it is closed: its header, which says how many frames it holds,
    /// goes last. Not atomic and not synced: the caller writes to a temporary and moves it into place
    /// (`ProjectCaches.temporaryFile(for:)` and `commit(_:to:)`). Reports the fraction done to `progress`, never going
    /// down, 1 last.
    ///
    /// The file at `url` is looked at before `AVURLAsset` is given it, without following a link (`lstat`).
    /// - Precondition: `maximumFrames > 0`.
    /// - Throws: `ImportedAudioError`, the `POSIXError` of a write that fails (a full drive: `ENOSPC`), or
    ///   `CancellationError` if the task is cancelled; each leaves nothing at `destination`.
    public static func decode(
        _ url: URL, to destination: URL, maximumFrames: Int = maximumFrames, progress: @escaping @Sendable (Double) -> Void
    ) async throws {
        precondition(maximumFrames > 0, "ImportedAudio: a maximum of \(maximumFrames) frames")
        try Task.checkCancellation()
        var info = stat()
        guard lstat(url.path, &info) == 0, info.st_mode & S_IFMT == S_IFREG, info.st_size > 0 else {
            throw ImportedAudioError.notAudio
        }
        let source = try await open(url)
        let cancelled = CancellationFlag()
        try await withTaskCancellationHandler {
            try await offTheCooperativePool {
                try write(source, to: destination, maximumFrames: maximumFrames, progress: progress, cancelled: cancelled)
            }
        } onCancel: {
            cancelled.cancel()
        }
        progress(1)
    }

    /// The first audio track of a file, ready to decode.
    private struct Source: @unchecked Sendable {
        // Unchecked: the asset and its track are only read, by one decoding at a time.
        var asset: AVURLAsset
        var track: AVAssetTrack
        /// Channels of the file.
        var channels: Int
        /// Its length at 48 kHz as its track's duration says it, to the nearest frame; `nil` if it does not say.
        var frames: Int?
    }

    /// The first audio track of the file at `url`, with its channels and its length.
    private static func open(_ url: URL) async throws -> Source {
        // The precise duration: an MP3's, from its frames rather than from its bit rate.
        let asset = AVURLAsset(url: url, options: [AVURLAssetPreferPreciseDurationAndTimingKey: true])
        do {
            guard let track = try await asset.loadTracks(withMediaType: .audio).first,
                  let format = try await track.load(.formatDescriptions).first,
                  let description = CMAudioFormatDescriptionGetStreamBasicDescription(format)?.pointee,
                  description.mSampleRate > 0, description.mChannelsPerFrame > 0
            else { throw ImportedAudioError.notAudio }
            let duration = try await track.load(.timeRange).duration
            let seconds = duration.isNumeric ? duration.seconds : 0
            let frames = seconds > 0 && seconds < 1e9 ? Int((seconds * Double(MusicFile.sampleRate)).rounded()) : nil
            return Source(asset: asset, track: track, channels: Int(description.mChannelsPerFrame), frames: frames)
        } catch let error as ImportedAudioError {
            throw error
        } catch {
            try Task.checkCancellation()
            throw ImportedAudioError.notAudio
        }
    }

    /// Decodes `source` into a new file at `destination`, blocking the calling thread; removes what it wrote if anything
    /// fails or `cancelled` is set.
    private static func write(
        _ source: Source, to destination: URL, maximumFrames: Int, progress: @Sendable (Double) -> Void,
        cancelled: CancellationFlag
    ) throws {
        // The decoder resamples to 48 kHz, in the file's channels; they are made two here.
        let channels = source.channels
        let reader: AVAssetReader
        do {
            reader = try AVAssetReader(asset: source.asset)
        } catch {
            throw ImportedAudioError.notAudio
        }
        let output = AVAssetReaderTrackOutput(track: source.track, outputSettings: [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: MusicFile.sampleRate,
            AVNumberOfChannelsKey: channels,
            AVLinearPCMBitDepthKey: 32,
            AVLinearPCMIsFloatKey: true,
            AVLinearPCMIsNonInterleaved: false,
            AVLinearPCMIsBigEndianKey: false,
        ])
        output.alwaysCopiesSampleData = false
        guard reader.canAdd(output) else { throw ImportedAudioError.notAudio }
        reader.add(output)
        guard reader.startReading() else { throw ImportedAudioError.notAudio }
        defer { reader.cancelReading() }

        let fd = Darwin.open(destination.path, O_WRONLY | O_CREAT | O_TRUNC | O_NOFOLLOW | O_CLOEXEC, 0o644)
        guard fd >= 0 else { throw currentError() }
        var open = true
        do {
            // A header of no frames until the frames are known; written again last.
            try MusicFile.header(frames: 0).withUnsafeBytes { try writeAll(fd, $0) }
            let total = Double(min(source.frames ?? 0, maximumFrames))
            var frames = 0
            var decoded: [Float] = []
            var piece: [UInt32] = []
            while frames < maximumFrames {
                if cancelled.isCancelled { throw CancellationError() }
                guard let sample = output.copyNextSampleBuffer() else { break }
                guard let block = CMSampleBufferGetDataBuffer(sample) else { continue }
                let count = CMBlockBufferGetDataLength(block) / MemoryLayout<Float>.size
                let blockFrames = min(count / channels, maximumFrames - frames)
                guard blockFrames > 0 else { continue }
                if decoded.count != count { decoded = [Float](repeating: 0, count: count) }
                let status = decoded.withUnsafeMutableBytes { bytes in
                    CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: bytes.count, destination: bytes.baseAddress!)
                }
                guard status == noErr else { throw ImportedAudioError.readingStopped("cannot copy decoded audio (OSStatus \(status))") }
                // Interleaved, left and right, each sample little-endian (a no-op on Apple silicon).
                piece.removeAll(keepingCapacity: true)
                switch channels {
                case 1:
                    for i in 0..<blockFrames {
                        let value = decoded[i].bitPattern.littleEndian
                        piece.append(value)
                        piece.append(value)
                    }
                case 2:
                    for i in 0..<(blockFrames * 2) { piece.append(decoded[i].bitPattern.littleEndian) }
                default:
                    for frame in 0..<blockFrames {
                        var sum: Float = 0
                        for c in 0..<channels { sum += decoded[frame * channels + c] }
                        let value = min(max(sum, -1), 1).bitPattern.littleEndian
                        piece.append(value)
                        piece.append(value)
                    }
                }
                try piece.withUnsafeBytes { try writeAll(fd, $0) }
                frames += blockFrames
                if total > 0 { progress(min(Double(frames) / total, 0.99)) }
            }
            if frames < maximumFrames, reader.status == .failed {
                throw ImportedAudioError.readingStopped(reader.error.map { String(describing: $0) } ?? "the reader failed")
            }
            guard frames > 0 else { throw ImportedAudioError.notAudio }
            // Read to its end: exactly as long as the sound, if it is near.
            if frames < maximumFrames, let length = source.frames, abs(length - frames) <= lengthSlack {
                let target = min(length, maximumFrames)
                if target > frames {
                    let silence = [UInt32](repeating: 0, count: (target - frames) * MusicFile.channels)
                    try silence.withUnsafeBytes { try writeAll(fd, $0) }
                } else if target < frames, ftruncate(fd, off_t(MusicFile.headerBytes + target * MusicFile.frameBytes)) != 0 {
                    throw currentError()
                }
                frames = target
            }
            let header = MusicFile.header(frames: frames)
            let written = header.withUnsafeBytes { pwrite(fd, $0.baseAddress, $0.count, 0) }
            guard written == header.count else { throw written < 0 ? currentError() : POSIXError(.EIO) }
            open = false
            guard close(fd) == 0 else { throw currentError() }
        } catch {
            if open { close(fd) }
            unlink(destination.path)
            throw error
        }
    }

    /// Writes all of `bytes` to `fd`.
    private static func writeAll(_ fd: Int32, _ bytes: UnsafeRawBufferPointer) throws {
        guard var next = bytes.baseAddress else { return }
        var remaining = bytes.count
        while remaining > 0 {
            let count = Darwin.write(fd, next, remaining)
            if count < 0 {
                if errno == EINTR { continue }
                throw currentError()
            }
            next += count
            remaining -= count
        }
    }

    /// The error of `errno` now.
    private static func currentError() -> POSIXError {
        POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
    }
}
