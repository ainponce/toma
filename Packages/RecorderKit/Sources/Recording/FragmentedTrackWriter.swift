// SPDX-License-Identifier: GPL-3.0-or-later
import AVFoundation
import AudioToolbox
import CoreMedia
import Darwin
import Foundation
import ProjectFormat

/// Writes one segment of one track as a fragmented QuickTime movie: every `fragmentInterval` of
/// media the file gains a movie fragment, and everything up to the last fragment can be read back
/// after a crash. Video is HEVC; audio is ALAC (or Float32 LPCM above 8 channels).
///
/// Time zero in the file is the first sample's presentation time (`SegmentResult.startHostTime`).
///
/// Not thread-safe: one owner (the track's pipeline actor) calls it, one call at a time.
/// Every AVFoundation precondition is checked before the call, because AVFoundation reports misuse
/// with Objective-C exceptions, which would end the process.
public final class FragmentedTrackWriter: TrackWriting {
    public static let defaultFragmentInterval = CMTime(value: 1, timescale: 1)

    /// Most audio held while the encoder is busy in real time; beyond it the oldest is dropped.
    static let maxPendingAudioSeconds = 2.0
    /// How often waiting for the encoder looks again.
    static let readinessPollMicroseconds: useconds_t = 1_000

    public var onStart: ((HostTime) -> Void)?
    public private(set) var formatDescription: CMFormatDescription?
    public private(set) var failure: NSError?

    /// How long a real-time writer waits for the encoder before it gives up.
    static let realTimeReadinessTimeoutSeconds = 5.0
    /// How long an offline writer waits: nothing is live, so a busy machine only makes it slower.
    static let offlineReadinessTimeoutSeconds = 30.0
    /// How long waiting for the encoder may take before it gives up.
    var readinessTimeoutSeconds: Double
    /// Whether the encoder takes more data now. Tests replace it to make the encoder look busy.
    var inputHasRoom: (AVAssetWriterInput) -> Bool = { $0.isReadyForMoreMediaData }

    private let media: TrackMedia
    private let realTime: Bool
    private let writer: AVAssetWriter
    private var input: AVAssetWriterInput?
    /// Host time of the first sample, time zero in the file.
    private var start: HostTime?
    /// Newest presentation time taken: written, queued or deliberately dropped, heartbeats included.
    private var lastPTS: HostTime?
    /// Newest presentation time handed to the encoder.
    private var lastWrittenPTS: HostTime?
    /// Newest video frame taken, already retimed; heartbeats and `finish` repeat it.
    private var lastFrame: CMSampleBuffer?
    /// The source audio format relabeled with the file's channel layout (`fileLayoutTag`). Every
    /// audio buffer goes to the encoder with it, so the encoder never remaps channels.
    private var writingAudioFormat: CMAudioFormatDescription?
    /// Real-time audio waiting for the encoder; set up with the source sample rate in `configure`.
    private var pendingAudio = PendingAudioQueue(capacitySeconds: maxPendingAudioSeconds, sampleRate: 0)
    private var sampleCount = 0
    public private(set) var droppedSampleCount = 0
    private var heartbeatSampleCount = 0
    /// Audio frames handed to the encoder so far: the frame of the file the next one starts at.
    private var writtenAudioFrames = 0
    public private(set) var lastWrittenAudio: AudioFilePosition?
    private var finished = false

    /// Creates the writer; the file itself is created with the first sample.
    /// - Throws: `WriterError.fileExists` if anything already exists at `url` (it is left untouched),
    ///   `WriterError.unsupportedFormat` for a URL that is not a file URL, a video rate below 1 fps or
    ///   a fragment interval that is not a positive time.
    public init(
        url: URL,
        media: TrackMedia,
        realTime: Bool = true,
        fragmentInterval: CMTime = defaultFragmentInterval
    ) throws {
        guard url.isFileURL else { throw WriterError.unsupportedFormat }
        if case .video(let framesPerSecond) = media, framesPerSecond < 1 { throw WriterError.unsupportedFormat }
        guard fragmentInterval.isNumeric, fragmentInterval > .zero else { throw WriterError.unsupportedFormat }
        var existing = stat()
        if lstat(url.path, &existing) == 0 { throw WriterError.fileExists }

        writer = try AVAssetWriter(outputURL: url, fileType: .mov)
        writer.movieFragmentInterval = fragmentInterval
        self.media = media
        self.realTime = realTime
        readinessTimeoutSeconds = realTime ? Self.realTimeReadinessTimeoutSeconds : Self.offlineReadinessTimeoutSeconds
    }

    public func append(_ sample: CMSampleBuffer) throws {
        try checkWritable()
        guard let format = CMSampleBufferGetFormatDescription(sample) else { throw WriterError.unsupportedFormat }
        if case .video = media, CMSampleBufferGetImageBuffer(sample) == nil { throw WriterError.unsupportedFormat }
        let pts = sample.presentationTimeStamp
        guard pts.isNumeric else { throw WriterError.appendFailed("sample has no presentation time") }
        let host = HostTime(pts)
        if let lastPTS, host <= lastPTS {
            throw WriterError.appendFailed("presentation time \(host.nanoseconds) ns is not after \(lastPTS.nanoseconds) ns")
        }

        let input: AVAssetWriterInput
        if let configured = self.input, let configuredFormat = formatDescription {
            guard Self.isCompatible(format, with: configuredFormat, media: media) else { throw WriterError.unsupportedFormat }
            input = configured
        } else {
            input = try configure(with: format)
        }
        if start == nil { try startWriting(at: host) }
        let retimed = try self.retimed(sample, at: host)

        // The sample counts as taken (`lastPTS`, `lastFrame`) only once it is written, queued or
        // deliberately dropped; a sample that times out or fails is not taken.
        switch media {
        case .video:
            if realTime {
                guard try hasRoom(input) else {
                    lastPTS = host
                    lastFrame = retimed
                    droppedSampleCount += 1
                    return
                }
            } else {
                try waitUntilReady(input)
            }
            try write(retimed, to: input)
            lastPTS = host
            lastFrame = retimed
            sampleCount += 1
        case .audio:
            if realTime {
                try drainPendingAudio(into: input, waiting: false)  // make room before the cap applies
                droppedSampleCount += pendingAudio.push(retimed).count
                lastPTS = host
                try drainPendingAudio(into: input, waiting: false)
            } else {
                try waitUntilReady(input)
                try write(retimed, to: input)
                lastPTS = host
                sampleCount += 1
            }
        }
    }

    /// Writes the last video frame again with presentation time `time`. Does nothing for audio or
    /// before the first frame (there is nothing to repeat), and in real time when the encoder is busy
    /// (the next heartbeat or frame follows soon).
    /// - Throws: `appendFailed` if `time` is not after the last sample, or as `append` does.
    public func appendHeartbeat(at time: HostTime) throws {
        try checkWritable()
        guard case .video = media, let input, let lastFrame else { return }
        if let lastPTS, time <= lastPTS {
            throw WriterError.appendFailed("heartbeat time \(time.nanoseconds) ns is not after \(lastPTS.nanoseconds) ns")
        }
        let repeated = try retimed(lastFrame, at: time)
        if realTime {
            guard try hasRoom(input) else { return }
        } else {
            try waitUntilReady(input)
        }
        try write(repeated, to: input)
        lastPTS = time
        heartbeatSampleCount += 1
    }

    /// Writes the queued audio, holds the last video frame until `stopTime`, ends the session there
    /// and finishes the file. The session never ends before the start of the last sample taken; an
    /// audio block that ends after `stopTime` is cut at `stopTime`.
    ///
    /// Follows `TrackWriting.finish`: once the segment started it always returns a result, and a
    /// writer error goes to `failure`. If the encoder has no room for 5 s while finishing, the audio
    /// still queued is counted as dropped and the hold frame is skipped, and the file is finished anyway.
    /// - Throws: Only `alreadyFinished`, on a second call.
    public nonisolated(nonsending) func finish(at stopTime: HostTime) async throws -> SegmentResult {
        guard !finished else { throw WriterError.alreadyFinished }
        finished = true
        guard let start, let input else {
            return SegmentResult(
                startHostTime: nil, endHostTime: stopTime, sampleCount: 0, droppedSampleCount: 0, heartbeatSampleCount: 0
            )
        }
        if failure == nil, writer.status != .writing { _ = recordFailure() }
        let end = max(stopTime, lastPTS ?? start)
        if failure == nil { await finalize(input, endingAt: end) }
        guard failure == nil else {
            // Not finalized: the file holds the fragments written before the failure.
            droppedSampleCount += pendingAudio.removeAll().count
            return result(start: start, end: lastWrittenPTS ?? start)
        }
        return result(start: start, end: end)
    }

    // MARK: - Setup

    private func checkWritable() throws {
        if finished { throw WriterError.alreadyFinished }
        if let failure { throw WriterError.appendFailed(failure.localizedDescription) }
        if start != nil, writer.status != .writing { throw recordFailure() }
    }

    /// Creates and adds the input for the first sample's format. Throws `unsupportedFormat` (and
    /// adds nothing) if the format cannot be encoded, so a later sample may try again.
    private func configure(with format: CMFormatDescription) throws -> AVAssetWriterInput {
        let mediaType: AVMediaType
        let settings: [String: Any]
        let hint: CMFormatDescription?
        var sampleRate = 0.0
        switch media {
        case .video(let framesPerSecond):
            guard CMFormatDescriptionGetMediaType(format) == kCMMediaType_Video else { throw WriterError.unsupportedFormat }
            let size = CMVideoFormatDescriptionGetDimensions(format)
            guard size.width > 0, size.height > 0 else { throw WriterError.unsupportedFormat }
            mediaType = .video
            settings = Self.videoSettings(width: Int(size.width), height: Int(size.height), framesPerSecond: framesPerSecond)
            hint = format
        case .audio:
            guard CMFormatDescriptionGetMediaType(format) == kCMMediaType_Audio,
                  let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(format)?.pointee,
                  asbd.mFormatID == kAudioFormatLinearPCM, asbd.mChannelsPerFrame > 0, asbd.mSampleRate > 0
            else { throw WriterError.unsupportedFormat }
            mediaType = .audio
            settings = Self.audioSettings(for: asbd)
            hint = nil
            sampleRate = asbd.mSampleRate
            writingAudioFormat = try Self.writingFormat(for: asbd)
        }
        guard writer.status == .unknown, writer.canApply(outputSettings: settings, forMediaType: mediaType) else {
            throw WriterError.unsupportedFormat
        }
        let input = AVAssetWriterInput(mediaType: mediaType, outputSettings: settings, sourceFormatHint: hint)
        input.expectsMediaDataInRealTime = realTime
        guard writer.canAdd(input) else { throw WriterError.unsupportedFormat }
        writer.add(input)
        self.input = input
        formatDescription = format
        pendingAudio = PendingAudioQueue(capacitySeconds: Self.maxPendingAudioSeconds, sampleRate: sampleRate)
        return input
    }

    /// Creates the file and starts the session at zero; the first sample's time becomes the start.
    private func startWriting(at host: HostTime) throws {
        guard writer.startWriting() else { throw recordFailure() }
        writer.startSession(atSourceTime: .zero)
        start = host
        onStart?(host)
    }

    static func videoSettings(width: Int, height: Int, framesPerSecond: Int) -> [String: Any] {
        [
            AVVideoCodecKey: AVVideoCodecType.hevc,
            AVVideoWidthKey: width,
            AVVideoHeightKey: height,
            AVVideoColorPropertiesKey: [
                AVVideoColorPrimariesKey: AVVideoColorPrimaries_ITU_R_709_2,
                AVVideoTransferFunctionKey: AVVideoTransferFunction_ITU_R_709_2,
                AVVideoYCbCrMatrixKey: AVVideoYCbCrMatrix_ITU_R_709_2,
            ],
            AVVideoCompressionPropertiesKey: [
                AVVideoAverageBitRateKey: VideoBitrate.averageBitRate(
                    width: width, height: height, framesPerSecond: framesPerSecond
                ),
                AVVideoExpectedSourceFrameRateKey: framesPerSecond,
                AVVideoMaxKeyFrameIntervalDurationKey: 1,
                AVVideoAllowFrameReorderingKey: false,
            ],
        ]
    }

    /// ALAC up to 8 channels (AVFoundation raises an exception without a bit-depth hint, and needs
    /// an explicit layout above 2 channels); Float32 LPCM with a discrete layout beyond that. The
    /// layout is `fileLayoutTag`.
    static func audioSettings(for source: AudioStreamBasicDescription) -> [String: Any] {
        let channels = Int(source.mChannelsPerFrame)
        var settings: [String: Any] = [
            AVSampleRateKey: source.mSampleRate,
            AVNumberOfChannelsKey: channels,
        ]
        if channels > 8 {
            settings[AVFormatIDKey] = kAudioFormatLinearPCM
            settings[AVLinearPCMBitDepthKey] = 32
            settings[AVLinearPCMIsFloatKey] = true
            settings[AVLinearPCMIsBigEndianKey] = false
            settings[AVLinearPCMIsNonInterleaved] = false
            settings[AVChannelLayoutKey] = channelLayoutData(fileLayoutTag(channels: channels, sampleRate: source.mSampleRate))
            return settings
        }
        let isFloat = source.mFormatFlags & kAudioFormatFlagIsFloat != 0
        settings[AVFormatIDKey] = kAudioFormatAppleLossless
        settings[AVEncoderBitDepthHintKey] = !isFloat && source.mBitsPerChannel <= 16 ? 16 : 24
        if channels > 2 {
            settings[AVChannelLayoutKey] = channelLayoutData(fileLayoutTag(channels: channels, sampleRate: source.mSampleRate))
        }
        return settings
    }

    /// The channel layout written in the file: mono or stereo for 1–2 channels (ALAC's own), the
    /// ALAC layout for 3–8 (`alacLayoutTag`), and discrete in order beyond 8 (LPCM).
    ///
    /// It only labels the channels: they are always the source's channels, in the source's order.
    /// Interfaces label their inputs as discrete (or with labels of their own), and the encoder would
    /// map those labels onto the file's layout, giving silence or moved channels. So every buffer is
    /// relabeled with this layout before the encoder sees it (`writingFormat(for:)`).
    static func fileLayoutTag(channels: Int, sampleRate: Double) -> AudioChannelLayoutTag {
        switch channels {
        case 1: kAudioChannelLayoutTag_Mono
        case 2: kAudioChannelLayoutTag_Stereo
        case 3...8: alacLayoutTag(channels: channels, sampleRate: sampleRate)
        default: kAudioChannelLayoutTag_DiscreteInOrder | UInt32(channels)
        }
    }

    /// `source` with the layout `fileLayoutTag`, and nothing else from the source's description.
    static func writingFormat(for source: AudioStreamBasicDescription) throws -> CMAudioFormatDescription {
        var asbd = source
        var layout = AudioChannelLayout()
        layout.mChannelLayoutTag = fileLayoutTag(channels: Int(source.mChannelsPerFrame), sampleRate: source.mSampleRate)
        var format: CMAudioFormatDescription?
        let status = CMAudioFormatDescriptionCreate(
            allocator: kCFAllocatorDefault, asbd: &asbd, layoutSize: MemoryLayout<AudioChannelLayout>.size, layout: &layout,
            magicCookieSize: 0, magicCookie: nil, extensions: nil, formatDescriptionOut: &format
        )
        guard status == noErr, let format else { throw WriterError.unsupportedFormat }
        return format
    }

    /// The layout ALAC prefers for `channels` (3...8): the first matching entry of
    /// `kAudioFormatProperty_AvailableEncodeChannelLayoutTags`, or the known answer if the query fails.
    static func alacLayoutTag(channels: Int, sampleRate: Double) -> AudioChannelLayoutTag {
        let known: [Int: AudioChannelLayoutTag] = [
            3: kAudioChannelLayoutTag_MPEG_3_0_B,
            4: kAudioChannelLayoutTag_MPEG_4_0_B,
            5: kAudioChannelLayoutTag_MPEG_5_0_D,
            6: kAudioChannelLayoutTag_MPEG_5_1_D,
            7: kAudioChannelLayoutTag_AAC_6_1,
            8: kAudioChannelLayoutTag_MPEG_7_1_B,
        ]
        var format = AudioStreamBasicDescription()
        format.mFormatID = kAudioFormatAppleLossless
        format.mSampleRate = sampleRate
        format.mChannelsPerFrame = UInt32(channels)
        let specifierSize = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        var size: UInt32 = 0
        if AudioFormatGetPropertyInfo(
            kAudioFormatProperty_AvailableEncodeChannelLayoutTags, specifierSize, &format, &size
        ) == noErr, size >= UInt32(MemoryLayout<AudioChannelLayoutTag>.size) {
            var tags = [AudioChannelLayoutTag](repeating: 0, count: Int(size) / MemoryLayout<AudioChannelLayoutTag>.size)
            let status = tags.withUnsafeMutableBytes { buffer in
                AudioFormatGetProperty(
                    kAudioFormatProperty_AvailableEncodeChannelLayoutTags, specifierSize, &format, &size, buffer.baseAddress!
                )
            }
            let returned = tags.prefix(Int(size) / MemoryLayout<AudioChannelLayoutTag>.size)
            // The low 16 bits of a layout tag are its channel count.
            if status == noErr, let tag = returned.first(where: { Int($0 & 0xFFFF) == channels }) {
                return tag
            }
        }
        return known[channels] ?? (kAudioChannelLayoutTag_DiscreteInOrder | UInt32(channels))
    }

    private static func channelLayoutData(_ tag: AudioChannelLayoutTag) -> Data {
        var layout = AudioChannelLayout()
        layout.mChannelLayoutTag = tag
        return Data(bytes: &layout, count: MemoryLayout<AudioChannelLayout>.size)
    }

    /// Whether `format` can go into an input configured for `configured`: same dimensions for video,
    /// same sample rate, channel count and sample layout for audio. `append` refuses anything else
    /// with `unsupportedFormat`; the track pipeline uses it to decide when a format change needs a
    /// new segment.
    static func isCompatible(_ format: CMFormatDescription, with configured: CMFormatDescription, media: TrackMedia) -> Bool {
        guard CMFormatDescriptionGetMediaType(format) == CMFormatDescriptionGetMediaType(configured) else { return false }
        switch media {
        case .video:
            let a = CMVideoFormatDescriptionGetDimensions(format)
            let b = CMVideoFormatDescriptionGetDimensions(configured)
            return a.width == b.width && a.height == b.height
        case .audio:
            guard let a = CMAudioFormatDescriptionGetStreamBasicDescription(format)?.pointee,
                  let b = CMAudioFormatDescriptionGetStreamBasicDescription(configured)?.pointee
            else { return false }
            return a.mSampleRate == b.mSampleRate && a.mFormatID == b.mFormatID && a.mFormatFlags == b.mFormatFlags
                && a.mChannelsPerFrame == b.mChannelsPerFrame && a.mBitsPerChannel == b.mBitsPerChannel
                && a.mBytesPerFrame == b.mBytesPerFrame
        }
    }

    // MARK: - Writing

    /// Drains the queue, adds the hold frame, ends the session at `end` and finishes the file. A
    /// timeout drops what is still queued, or skips the hold, and finishing goes on; a writer error
    /// stops here and is left in `failure`.
    private nonisolated(nonsending) func finalize(_ input: AVAssetWriterInput, endingAt end: HostTime) async {
        do {
            try drainPendingAudio(into: input, waiting: true)
        } catch {
            guard failure == nil else { return }
            droppedSampleCount += pendingAudio.removeAll().count
        }
        if case .video(let framesPerSecond) = media, let lastFrame, let lastPTS,
           end.seconds(since: lastPTS) > 1 / Double(framesPerSecond) {
            do {
                let held = try retimed(lastFrame, at: end)
                try waitUntilReady(input)
                try write(held, to: input)
            } catch {
                guard failure == nil else { return }  // otherwise the hold is cosmetic: skip it
            }
        }
        guard writer.status == .writing else {
            _ = recordFailure()
            return
        }
        writer.endSession(atSourceTime: offset(of: end))
        await withCheckedContinuation { (done: CheckedContinuation<Void, Never>) in
            writer.finishWriting { done.resume() }
        }
        if writer.status != .completed { _ = recordFailure() }
    }

    private func result(start: HostTime, end: HostTime) -> SegmentResult {
        SegmentResult(
            startHostTime: start, endHostTime: end, sampleCount: sampleCount,
            droppedSampleCount: droppedSampleCount, heartbeatSampleCount: heartbeatSampleCount
        )
    }

    /// Hands queued real-time audio to the encoder in order: while it has room, or, with `waiting`,
    /// all of it, waiting for room as `append` does outside real time.
    private func drainPendingAudio(into input: AVAssetWriterInput, waiting: Bool) throws {
        while let next = pendingAudio.first {
            if waiting {
                try waitUntilReady(input)
            } else if try !hasRoom(input) {
                return
            }
            try write(next, to: input)
            _ = pendingAudio.popFirst()
            sampleCount += 1
        }
    }

    /// Whether the encoder takes more data now. A writer that stopped is noticed here, so `failure`
    /// is set on the call where it happens rather than on the next one.
    private func hasRoom(_ input: AVAssetWriterInput) throws -> Bool {
        if inputHasRoom(input) { return true }
        guard writer.status == .writing else { throw recordFailure() }
        return false
    }

    /// Polls every millisecond until the encoder takes more data; gives up after
    /// `readinessTimeoutSeconds` with `appendFailed("timeout")`, leaving `failure` unset.
    private func waitUntilReady(_ input: AVAssetWriterInput) throws {
        let deadline = HostTime.now().adding(seconds: readinessTimeoutSeconds)
        while try !hasRoom(input) {
            guard HostTime.now() < deadline else { throw WriterError.appendFailed("timeout") }
            usleep(Self.readinessPollMicroseconds)
        }
    }

    private func write(_ sample: CMSampleBuffer, to input: AVAssetWriterInput) throws {
        guard writer.status == .writing else { throw recordFailure() }
        guard input.append(sample), writer.status != .failed else { throw recordFailure() }
        let host = HostTime(nanoseconds: (start?.nanoseconds ?? 0) + HostTime(sample.presentationTimeStamp).nanoseconds)
        lastWrittenPTS = host
        if media == .audio {
            lastWrittenAudio = AudioFilePosition(frame: writtenAudioFrames, hostTime: host)
            writtenAudioFrames += CMSampleBufferGetNumSamples(sample)
        }
    }

    /// Keeps the writer's error as `failure` and returns the error to throw.
    private func recordFailure() -> WriterError {
        let error = failure ?? (writer.error as NSError?) ?? NSError(
            domain: "dev.toma.Recording.FragmentedTrackWriter",
            code: writer.status.rawValue,
            userInfo: [NSLocalizedDescriptionKey: "AVAssetWriter stopped writing (status \(writer.status.rawValue))"]
        )
        failure = error
        return .appendFailed(error.localizedDescription)
    }

    /// Time of `host` in the file: nanoseconds since the first sample.
    private func offset(of host: HostTime) -> CMTime {
        let start = start ?? host
        return CMTime(value: CMTimeValue(host.nanoseconds - min(start.nanoseconds, host.nanoseconds)), timescale: 1_000_000_000)
    }

    /// A copy of `sample` that presents at `host` in file time.
    ///
    /// Video: every timing entry keeps its offset from the first one. Decode times are dropped (the
    /// frames are uncompressed and the encoder assigns its own), and so are durations: a frame lasts
    /// until the next one, so held and heartbeat frames extend however the source timed them.
    /// Audio: see `relabeledAudio(_:at:)`.
    private func retimed(_ sample: CMSampleBuffer, at host: HostTime) throws -> CMSampleBuffer {
        if case .audio = media { return try relabeledAudio(sample, at: host) }
        let entries = (try? sample.sampleTimingInfos()) ?? []
        let first = entries.first?.presentationTimeStamp ?? .invalid
        let shift = offset(of: host)
        let timing: [CMSampleTimingInfo]
        if entries.isEmpty || !first.isNumeric {
            timing = [CMSampleTimingInfo(duration: .invalid, presentationTimeStamp: shift, decodeTimeStamp: .invalid)]
        } else {
            timing = entries.map { entry in
                let pts = entry.presentationTimeStamp.isNumeric
                    ? CMTimeAdd(shift, CMTimeSubtract(entry.presentationTimeStamp, first))
                    : shift
                return CMSampleTimingInfo(duration: .invalid, presentationTimeStamp: pts, decodeTimeStamp: .invalid)
            }
        }
        do {
            return try CMSampleBuffer(copying: sample, withNewTiming: timing)
        } catch {
            throw WriterError.appendFailed("could not retime sample (\(error))")
        }
    }

    /// The same audio frames, in the same channel order, as `sample`, presenting at `host` in file
    /// time and described by `writingAudioFormat`, so the encoder sees the file's own layout and copies
    /// every channel as it is instead of mapping channels by label.
    ///
    /// The samples are copied through the source's own `AudioBufferList`, so any block layout the
    /// source uses (interleaved, planar, planes padded for alignment) arrives intact.
    private func relabeledAudio(_ sample: CMSampleBuffer, at host: HostTime) throws -> CMSampleBuffer {
        guard let format = writingAudioFormat, CMSampleBufferDataIsReady(sample) else {
            throw WriterError.appendFailed("audio sample has no data ready")
        }
        var listSize = 0
        var status = CMSampleBufferGetAudioBufferListWithRetainedBlockBuffer(
            sample, bufferListSizeNeededOut: &listSize, bufferListOut: nil, bufferListSize: 0,
            blockBufferAllocator: nil, blockBufferMemoryAllocator: nil, flags: 0, blockBufferOut: nil
        )
        guard status == noErr, listSize >= MemoryLayout<AudioBufferList>.size else {
            throw WriterError.appendFailed("could not read audio sample (\(status))")
        }
        let list = UnsafeMutableRawPointer.allocate(byteCount: listSize, alignment: MemoryLayout<AudioBufferList>.alignment)
            .bindMemory(to: AudioBufferList.self, capacity: 1)
        defer { list.deallocate() }
        var source: CMBlockBuffer?
        status = CMSampleBufferGetAudioBufferListWithRetainedBlockBuffer(
            sample, bufferListSizeNeededOut: nil, bufferListOut: list, bufferListSize: listSize,
            blockBufferAllocator: nil, blockBufferMemoryAllocator: nil, flags: 0, blockBufferOut: &source
        )
        guard status == noErr else { throw WriterError.appendFailed("could not read audio sample (\(status))") }

        var relabeled: CMSampleBuffer?
        status = CMAudioSampleBufferCreateWithPacketDescriptions(
            allocator: kCFAllocatorDefault, dataBuffer: nil, dataReady: false, makeDataReadyCallback: nil, refcon: nil,
            formatDescription: format, sampleCount: CMSampleBufferGetNumSamples(sample),
            presentationTimeStamp: offset(of: host), packetDescriptions: nil, sampleBufferOut: &relabeled
        )
        guard status == noErr, let relabeled else {
            throw WriterError.appendFailed("could not relabel audio sample (\(status))")
        }
        // `list` points into `source`, which must stay alive until the copy is made.
        status = withExtendedLifetime(source) {
            CMSampleBufferSetDataBufferFromAudioBufferList(
                relabeled, blockBufferAllocator: kCFAllocatorDefault, blockBufferMemoryAllocator: kCFAllocatorDefault,
                flags: 0, bufferList: list
            )
        }
        guard status == noErr, CMSampleBufferDataIsReady(relabeled) else {
            throw WriterError.appendFailed("could not copy audio sample (\(status))")
        }
        return relabeled
    }
}
