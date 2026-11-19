// SPDX-License-Identifier: GPL-3.0-or-later
import AVFoundation
import AudioToolbox
import Foundation

/// Why `SoundIsolation.clean` could not clean.
public enum SoundIsolationError: Error, Equatable {
    /// This Mac has no `AUSoundIsolation`, or it does not take the high-quality voice model (plan decision 16).
    case unavailable
    /// The unit or the file failed while rendering (what failed, for the log).
    case renderingFailed(String)
}

/// `soundIsolation-1` (phase 2 design §5.6): the voice of a segment of an audio track without its noise, by the system's
/// `AUSoundIsolation` with `SoundToIsolate` the high-quality voice model (`kAUSoundIsolationSoundType_HighQualityVoice`)
/// and the mix all wet (`WetDryMixPercent` 100), rendered once, offline, into the cleanup cache (plan decision 14). The
/// mix only ever reads that file (`EditedMix`); nothing calls the unit while mixing or rendering a frame.
///
/// - The unit runs in an `AVAudioEngine` rendering offline by hand at 48 kHz in mono (Float32), `renderFrames` at a
///   time. It is fed the span's frames of the track as `TrackAudio` places them (the frames the mix plays there, its
///   channels mixed down as the timeline mixes them: each at unity gain, clipped), then silence.
/// - The unit's latency (`AVAudioUnit.latency` or its audio unit's, the larger, read once the engine has started it:
///   92.5 ms, 4 440 frames, on macOS 26) is made up for: the first `round(latency × 48 000)` frames it gives are dropped,
///   and it is fed on past the span as far as that, so the clean voice keeps time with the dry one frame for frame.
/// - The file (CAF, Float32 LPCM, mono, 48 kHz) holds exactly the span's frames, the clean voice of timeline frame
///   `span.frames.lowerBound + i` at its frame `i`.
public enum SoundIsolation {
    public static let algorithm = "soundIsolation-1"
    /// The frames the engine renders at a time.
    static let renderFrames: AVAudioFrameCount = 4_096

    /// `kAudioUnitType_Effect` / `kAudioUnitSubType_AUSoundIsolation` / Apple.
    static let component = AudioComponentDescription(
        componentType: kAudioUnitType_Effect, componentSubType: kAudioUnitSubType_AUSoundIsolation,
        componentManufacturer: kAudioUnitManufacturer_Apple, componentFlags: 0, componentFlagsMask: 0)

    /// Whether this Mac can clean: it has `AUSoundIsolation`, and an instance of it set to the high-quality voice model
    /// reads it back (plan decision 16). Found once, the first time it is read, by making an instance (about 10 ms).
    public static var isAvailable: Bool { availability }

    private static let availability = configuredParameters()?.soundToIsolate == Float(kAUSoundIsolationSoundType_HighQualityVoice)

    /// The parameters an instance of the unit reads back once set as `clean` sets them; `nil` when this Mac has no such
    /// unit or it cannot be made.
    static func configuredParameters() -> (soundToIsolate: Float, wetDryMixPercent: Float)? {
        var description = component
        guard let found = AudioComponentFindNext(nil, &description) else { return nil }
        var instance: AudioComponentInstance?
        guard AudioComponentInstanceNew(found, &instance) == noErr, let unit = instance else { return nil }
        defer { AudioComponentInstanceDispose(unit) }
        return configure(unit)
    }

    /// Sets `unit` to the high-quality voice model, all wet, and reads both back; `nil` if it takes neither.
    private static func configure(_ unit: AudioUnit) -> (soundToIsolate: Float, wetDryMixPercent: Float)? {
        let sound = AudioUnitParameterValue(kAUSoundIsolationSoundType_HighQualityVoice)
        guard AudioUnitSetParameter(unit, kAUSoundIsolationParam_SoundToIsolate, kAudioUnitScope_Global, 0, sound, 0) == noErr,
              AudioUnitSetParameter(unit, kAUSoundIsolationParam_WetDryMixPercent, kAudioUnitScope_Global, 0, 100, 0) == noErr
        else { return nil }
        var soundToIsolate: AudioUnitParameterValue = -1, wetDry: AudioUnitParameterValue = -1
        guard AudioUnitGetParameter(unit, kAUSoundIsolationParam_SoundToIsolate, kAudioUnitScope_Global, 0, &soundToIsolate) == noErr,
              AudioUnitGetParameter(unit, kAUSoundIsolationParam_WetDryMixPercent, kAudioUnitScope_Global, 0, &wetDry) == noErr
        else { return nil }
        return (soundToIsolate, wetDry)
    }

    /// Writes the clean voice of `span` of `audio` to a new file at `url` (see the type), reporting the fraction done to
    /// `progress`, up to 1 when it is all written. Renders on a thread of its own, never on Swift's cooperative pool, a
    /// block at a time: never more of the track in memory than that.
    /// - Throws: `SoundIsolationError.unavailable` without the unit (`isAvailable`); `CancellationError` if the task is
    ///   cancelled (seen between two blocks), leaving the file at `url` unfinished for the caller to delete;
    ///   `SoundIsolationError.renderingFailed` or what writing the file throws.
    public static func clean(
        _ audio: TrackAudio, span: TrackAudioSpan, to url: URL, progress: @escaping @Sendable (Double) -> Void
    ) async throws {
        try Task.checkCancellation()
        guard isAvailable else { throw SoundIsolationError.unavailable }
        let cancelled = CancellationFlag()
        try await withTaskCancellationHandler {
            try await offTheCooperativePool {
                try render(audio, span: span, to: url, progress: progress, cancelled: cancelled)
            }
        } onCancel: {
            cancelled.cancel()
        }
    }

    private static func render(
        _ audio: TrackAudio, span: TrackAudioSpan, to url: URL, progress: @Sendable (Double) -> Void, cancelled: CancellationFlag
    ) throws {
        guard let format = AVAudioFormat(
            commonFormat: .pcmFormatFloat32, sampleRate: TrackAudio.sampleRate, channels: 1, interleaved: false)
        else { throw SoundIsolationError.renderingFailed("no 48 kHz mono format") }
        let engine = AVAudioEngine()
        try engine.enableManualRenderingMode(.offline, format: format, maximumFrameCount: renderFrames)
        let feed = IsolationFeed(reader: audio.makeReader(), channels: audio.channels, frames: span.frames)
        let node = AVAudioSourceNode(format: format) { _, _, count, list in
            feed.fill(Int(count), into: list)
            return noErr
        }
        let effect = AVAudioUnitEffect(audioComponentDescription: component)
        guard configure(effect.audioUnit)?.soundToIsolate == Float(kAUSoundIsolationSoundType_HighQualityVoice) else {
            throw SoundIsolationError.unavailable
        }
        engine.attach(node)
        engine.attach(effect)
        engine.connect(node, to: effect, format: format)
        engine.connect(effect, to: engine.outputNode, format: format)
        try engine.start()
        defer { engine.stop() }
        // Started, the unit still uses the high-quality voice model; and its latency is known.
        var soundToIsolate: AudioUnitParameterValue = -1
        guard AudioUnitGetParameter(effect.audioUnit, kAUSoundIsolationParam_SoundToIsolate, kAudioUnitScope_Global, 0, &soundToIsolate) == noErr,
              soundToIsolate == Float(kAUSoundIsolationSoundType_HighQualityVoice)
        else { throw SoundIsolationError.unavailable }
        let latency = Int64((max(effect.latency, effect.auAudioUnit.latency) * TrackAudio.sampleRate).rounded())
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: TrackAudio.sampleRate, AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 32, AVLinearPCMIsFloatKey: true, AVLinearPCMIsNonInterleaved: false,
            AVLinearPCMIsBigEndianKey: false, AVAudioFileTypeKey: kAudioFileCAFType,
        ]
        let file = try AVAudioFile(forWriting: url, settings: settings, commonFormat: .pcmFormatFloat32, interleaved: false)
        guard let rendered = AVAudioPCMBuffer(pcmFormat: engine.manualRenderingFormat, frameCapacity: renderFrames),
              let kept = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: renderFrames)
        else { throw SoundIsolationError.renderingFailed("no buffer") }
        let total = Int64(span.frames.count)
        var dropping = latency, written: Int64 = 0, reported = -1.0
        while written < total {
            if cancelled.isCancelled { throw CancellationError() }
            let status = try engine.renderOffline(renderFrames, to: rendered)
            guard status == .success, rendered.frameLength == renderFrames, let output = rendered.floatChannelData,
                  let destination = kept.floatChannelData
            else { throw SoundIsolationError.renderingFailed("rendering gave status \(status.rawValue), \(rendered.frameLength) frames") }
            let dropped = Int(min(dropping, Int64(renderFrames)))
            dropping -= Int64(dropped)
            let count = Int(min(Int64(Int(renderFrames) - dropped), total - written))
            guard count > 0 else { continue }
            destination[0].update(from: output[0] + dropped, count: count)
            kept.frameLength = AVAudioFrameCount(count)
            try file.write(from: kept)
            written += Int64(count)
            let fraction = Double(written) / Double(total)
            if fraction == 1 || fraction - reported >= 0.01 {
                reported = fraction
                progress(fraction)
            }
        }
        file.close()
        if total == 0 { progress(1) }
    }
}

/// What the unit takes in: frames `frames` of the track, read in order as it asks for them, mixed down to mono; silence
/// before and after.
private final class IsolationFeed {
    private let reader: TrackAudioReader
    private let channels: Int
    private let frames: Range<Int64>
    /// The timeline frame of the next frame the unit takes.
    private var position: Int64
    private var samples: [Float] = []

    init(reader: TrackAudioReader, channels: Int, frames: Range<Int64>) {
        self.reader = reader
        self.channels = channels
        self.frames = frames
        position = frames.lowerBound
    }

    /// Writes the next `count` frames into the unit's buffer.
    func fill(_ count: Int, into list: UnsafeMutablePointer<AudioBufferList>) {
        let read = (position..<(position + Int64(count))).clamped(to: frames)
        if !read.isEmpty { reader.read(read, into: &samples) }
        let first = Int(read.lowerBound - position), last = first + read.count
        let buffers = UnsafeMutableAudioBufferListPointer(list)
        for b in 0..<buffers.count {
            buffers[b].mDataByteSize = UInt32(count * MemoryLayout<Float>.size)
            guard let data = buffers[b].mData?.assumingMemoryBound(to: Float.self) else { continue }
            for i in 0..<count {
                guard i >= first, i < last else {
                    data[i] = 0
                    continue
                }
                if channels == 1 {
                    data[i] = samples[i - first]
                } else {
                    // As the timeline mixes a segment down: every channel at unity gain, clipped.
                    var sum: Float = 0
                    for c in 0..<channels { sum += samples[(i - first) * channels + c] }
                    data[i] = min(max(sum, -1), 1)
                }
            }
        }
        position += Int64(count)
    }
}
