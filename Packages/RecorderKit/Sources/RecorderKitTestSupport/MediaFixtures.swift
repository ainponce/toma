// SPDX-License-Identifier: GPL-3.0-or-later
import AVFoundation
import CoreGraphics
import CoreMedia
import Dispatch
import Editing
import Foundation
import ProjectFormat
import Synchronization
import SyntheticCapture

/// Clips of the user's own for the tests of the phase 3a layers (plan Tasks A3, A7, A9 and A10): a movie that tells which
/// frame of it is shown, with a sine for its sound, and the copy of one into a package as the editor makes it.
public enum MediaFixtures {
    /// The frame rate of a clip `clip(in:…)` writes.
    public static let framesPerSecond = 30

    /// Writes `MediaClip-<pattern>.mov` into `dir` (replacing one there) and returns it: `seconds` of video (`codec`) of
    /// `size`, at `framesPerSecond`, frame `i` presented at `i / framesPerSecond` s and painted as `SampleFactory`'s frame
    /// `pattern + i` (its palette's colour, which `SampleFactory.frameIndex(nearestTo:)` tells after encoding, and a white
    /// square that moves every frame), so every frame differs from the one before and clips of other patterns differ.
    /// With `tone`, also an AAC track of that many Hz of sine at 1/4 of full scale on each of `channels`, at
    /// `sampleRate`, for the same `seconds`. `transform` is its video track's `preferredTransform`, how a player turns it
    /// upright (a phone's clip shot upright is encoded on its side, with a quarter turn). `codec` is its video's codec,
    /// H.264 unless given: `.proRes422Proxy` for a clip whose frames must decode to the same pixels on every run (a
    /// golden project's), as the H.264 and HEVC encoders `AVAssetWriter` picks write other bitstreams of the same frames
    /// from one run to the next, which decode to other pixels, and ProRes does not.
    ///
    /// It blocks the calling thread while AVFoundation encodes, on its own queues.
    public static func clip(
        in dir: URL, seconds: Double, size: SIMD2<Int>, pattern: Int, tone: Double? = nil, sampleRate: Double = 48_000,
        channels: Int = 2, transform: CGAffineTransform = .identity, codec: AVVideoCodecType = .h264
    ) throws -> URL {
        guard seconds > 0, size.x > 0, size.y > 0, sampleRate > 0, channels > 0 else {
            throw TestSupportError.failed("MediaFixtures.clip: nothing to write")
        }
        let url = dir.appending(path: "MediaClip-\(pattern).mov")
        try? FileManager.default.removeItem(at: url)
        let writer = try AVAssetWriter(outputURL: url, fileType: .mov)
        let video = AVAssetWriterInput(
            mediaType: .video,
            outputSettings: [AVVideoCodecKey: codec, AVVideoWidthKey: size.x, AVVideoHeightKey: size.y])
        video.expectsMediaDataInRealTime = false
        video.transform = transform
        writer.add(video)
        var audio: AVAssetWriterInput?
        if tone != nil {
            let input = AVAssetWriterInput(
                mediaType: .audio,
                outputSettings: [AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: sampleRate, AVNumberOfChannelsKey: channels])
            input.expectsMediaDataInRealTime = false
            writer.add(input)
            audio = input
        }
        guard writer.startWriting() else {
            throw TestSupportError.failed("MediaFixtures.clip: \(String(describing: writer.error))")
        }
        writer.startSession(atSourceTime: .zero)

        let frames = Int((seconds * Double(framesPerSecond)).rounded())
        let blockFrames = max(1, Int(sampleRate / 100))
        let totalAudioFrames = Int((seconds * sampleRate).rounded())
        var (frame, audioFrame) = (0, 0)
        // Each input takes its samples while it is ready, so the writer can interleave the two.
        while frame < frames || (audio != nil && audioFrame < totalAudioFrames) {
            guard writer.status == .writing else {
                throw TestSupportError.failed("MediaFixtures.clip: \(String(describing: writer.error))")
            }
            var appended = false
            if frame < frames, video.isReadyForMoreMediaData {
                let pts = HostTime(nanoseconds: UInt64(TimeMap.frameTime(frame, frameRate: framesPerSecond)))
                guard video.append(SampleFactory.videoSample(width: size.x, height: size.y, pts: pts, frameIndex: pattern + frame)) else {
                    throw TestSupportError.failed("MediaFixtures.clip: video \(String(describing: writer.error))")
                }
                frame += 1
                appended = true
                // Finished at once: the writer would otherwise hold the other input back to interleave it with more.
                if frame == frames { video.markAsFinished() }
            }
            if let audio, let tone, audioFrame < totalAudioFrames, audio.isReadyForMoreMediaData {
                let count = min(blockFrames, totalAudioFrames - audioFrame)
                let pts = HostTime(nanoseconds: UInt64((Double(audioFrame) / sampleRate * 1e9).rounded()))
                let sample = SampleFactory.audioSample(
                    pts: pts, frames: count, sampleRate: sampleRate, channels: channels, amplitude: 0.25, frequency: tone)
                guard audio.append(sample) else {
                    throw TestSupportError.failed("MediaFixtures.clip: audio \(String(describing: writer.error))")
                }
                audioFrame += count
                appended = true
                if audioFrame == totalAudioFrames { audio.markAsFinished() }
            }
            if !appended { usleep(1_000) }
        }
        if frames == 0 { video.markAsFinished() }
        if let audio, totalAudioFrames == 0 { audio.markAsFinished() }
        writer.endSession(atSourceTime: CMTime(value: CMTimeValue((seconds * 1e9).rounded()), timescale: 1_000_000_000))
        let finished = DispatchSemaphore(value: 0)
        writer.finishWriting { finished.signal() }
        finished.wait()
        guard writer.status == .completed else {
            throw TestSupportError.failed("MediaFixtures.clip: \(String(describing: writer.error))")
        }
        return url
    }

    /// The file at `url` copied into `project`'s package as `kind` by `EditSession.importAsset`, as the editor imports
    /// one, and the path the document names it by (`assets/<sha>.<ext>`). It opens a session of its own on the package
    /// and closes it before it returns, so call it before a test opens one (a second session of the same package is
    /// read-only). Throws if the import is anything but `.imported`.
    @MainActor public static func imported(_ url: URL, into project: LoadedProject, as kind: AssetKind) async throws -> String {
        let count = Mutex(0)
        let context = EditContext(
            app: AppInfo(name: "Toma", version: "0.0.0"),
            cachesRoot: project.package.url.deletingLastPathComponent().appending(path: "MediaFixtures-Caches"),
            defaultStyle: .toma, now: { Date(timeIntervalSince1970: 1_794_773_523) },
            makeID: { prefix in
                count.withLock { count in
                    count += 1
                    return prefix + String(format: "%08x", count)
                }
            })
        let session = try await EditSession.open(project.package.url, take: nil, context: context)
        let outcome = await session.importAsset(url, kind: kind)
        await session.close()
        guard case let .imported(path) = outcome else {
            throw TestSupportError.failed("MediaFixtures.imported: \(url.lastPathComponent) gave \(outcome)")
        }
        return path
    }
}
