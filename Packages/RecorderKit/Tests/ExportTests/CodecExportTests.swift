// SPDX-License-Identifier: GPL-3.0-or-later
import AVFoundation
import CoreMedia
import CryptoKit
@testable import Export
import Foundation
import ProjectFormat
import RecorderKitTestSupport
import Render
import Synchronization
import Testing
import VideoToolbox

// HEVC in MP4 and ProRes 422 and 422 HQ in MOV (phase 2 design §6.8): the writer's settings of each codec, and what each
// writes, read back from the file.

/// The H.264 export of phase 1 does not change: its writer is given the dictionaries it was given before this task, as
/// they were written then; HEVC keeps its AAC.
@Test func h264SettingsAreThePhase1Ones() {
    let settings = ExportSettings(outputSize: [1280, 720], framesPerSecond: 30, quality: .high)
    #expect(settings.codec == .h264)
    let phase1Video: [String: Any] = [
        AVVideoCodecKey: AVVideoCodecType.h264,
        AVVideoWidthKey: 1280,
        AVVideoHeightKey: 720,
        AVVideoColorPropertiesKey: [
            AVVideoColorPrimariesKey: AVVideoColorPrimaries_ITU_R_709_2,
            AVVideoTransferFunctionKey: AVVideoTransferFunction_ITU_R_709_2,
            AVVideoYCbCrMatrixKey: AVVideoYCbCrMatrix_ITU_R_709_2,
        ],
        AVVideoCompressionPropertiesKey: [
            AVVideoAverageBitRateKey: 3_870_720,  // 1280 × 720 × 30 × 0.14
            AVVideoProfileLevelKey: AVVideoProfileLevelH264HighAutoLevel,
            AVVideoH264EntropyModeKey: AVVideoH264EntropyModeCABAC,
            AVVideoExpectedSourceFrameRateKey: 30,
        ],
    ]
    #expect(NSDictionary(dictionary: MP4Exporter.videoSettings(settings)).isEqual(to: phase1Video))
    for channels in [1, 2] {
        let phase1Audio: [String: Any] = [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: 48_000.0,
            AVNumberOfChannelsKey: channels,
            AVChannelLayoutKey: AudioMix.channelLayoutData(channels: channels),
            AVEncoderBitRateKey: 160_000,
            AVEncoderBitRateStrategyKey: AVAudioBitRateStrategy_Constant,
        ]
        #expect(NSDictionary(dictionary: MP4Exporter.audioSettings(settings, channels: channels)).isEqual(to: phase1Audio))
        var hevc = settings
        hevc.codec = .hevc
        #expect(NSDictionary(dictionary: MP4Exporter.audioSettings(hevc, channels: channels)).isEqual(to: phase1Audio))
    }
}

/// HEVC: Main profile at the level the encoder picks, at 0.6 × H.264's bitrate, tagged Rec.709 as H.264 is. ProRes: its
/// codec, the same colors and no bitrate, with 24-bit integer LPCM at 48 kHz.
@Test func hevcAndProResSettings() throws {
    let colors: [String: Any] = [
        AVVideoColorPrimariesKey: AVVideoColorPrimaries_ITU_R_709_2,
        AVVideoTransferFunctionKey: AVVideoTransferFunction_ITU_R_709_2,
        AVVideoYCbCrMatrixKey: AVVideoYCbCrMatrix_ITU_R_709_2,
    ]
    let hevc = MP4Exporter.videoSettings(ExportSettings(outputSize: [1280, 720], framesPerSecond: 30, codec: .hevc))
    let expectedHEVC: [String: Any] = [
        AVVideoCodecKey: AVVideoCodecType.hevc,
        AVVideoWidthKey: 1280,
        AVVideoHeightKey: 720,
        AVVideoColorPropertiesKey: colors,
        AVVideoCompressionPropertiesKey: [
            AVVideoAverageBitRateKey: 1_327_104,  // 0.6 × 1280 × 720 × 30 × 0.08
            AVVideoProfileLevelKey: kVTProfileLevel_HEVC_Main_AutoLevel as String,
            AVVideoExpectedSourceFrameRateKey: 30,
        ],
    ]
    #expect(NSDictionary(dictionary: hevc).isEqual(to: expectedHEVC))

    for (codec, type) in [(ExportCodec.proRes422, AVVideoCodecType.proRes422), (.proRes422HQ, .proRes422HQ)] {
        let settings = ExportSettings(outputSize: [3840, 2160], framesPerSecond: 60, quality: .high, codec: codec)
        let expected: [String: Any] = [
            AVVideoCodecKey: type, AVVideoWidthKey: 3840, AVVideoHeightKey: 2160, AVVideoColorPropertiesKey: colors,
        ]
        #expect(NSDictionary(dictionary: MP4Exporter.videoSettings(settings)).isEqual(to: expected), "\(codec)")
        for channels in [1, 2] {
            let lpcm: [String: Any] = [
                AVFormatIDKey: kAudioFormatLinearPCM,
                AVSampleRateKey: 48_000.0,
                AVNumberOfChannelsKey: channels,
                AVChannelLayoutKey: AudioMix.channelLayoutData(channels: channels),
                AVLinearPCMBitDepthKey: 24,
                AVLinearPCMIsFloatKey: false,
                AVLinearPCMIsBigEndianKey: false,
                AVLinearPCMIsNonInterleaved: false,
            ]
            #expect(NSDictionary(dictionary: MP4Exporter.audioSettings(settings, channels: channels)).isEqual(to: lpcm), "\(codec)")
        }
    }
}

/// Every codec's file, read back: its container, its codec's four-character code, its size, every frame at 30 fps, its
/// colors, its audio (AAC, or LPCM for ProRes) carrying the microphone's sine, and frames that decode to what the preview
/// draws.
@Test(.enabled(if: MetalCondition.isAvailable || MetalCondition.isRequired), arguments: ExportCodec.allCases.filter { !$0.hasAlpha })
func everyCodecWritesWhatItSays(codec: ExportCodec) async throws {
    try await withTemporaryDirectory { dir in
        let project = try await codecTake(in: dir, seconds: 1)
        let destination = try await export(project, codec, size: [640, 360], to: dir)
        #expect(destination.pathExtension == codec.fileExtension)
        #expect(try partialFiles(in: dir).isEmpty)
        #expect(try majorBrand(of: destination) == (codec.fileType == .mov ? "qt  " : "mp42"))

        let asset = AVURLAsset(url: destination)
        #expect(abs(try await asset.load(.duration).seconds - 1) <= 1.0 / 30 + 1e-6)
        let video = try #require(try await asset.loadTracks(withMediaType: .video).first)
        let format = try #require(try await video.load(.formatDescriptions).first)
        let expectedCode: FourCharCode = switch codec {
        case .h264: kCMVideoCodecType_H264
        case .hevc: kCMVideoCodecType_HEVC
        case .proRes422: kCMVideoCodecType_AppleProRes422
        case .proRes422HQ: kCMVideoCodecType_AppleProRes422HQ
        case .hevcAlpha: kCMVideoCodecType_HEVCWithAlpha
        case .proRes4444: kCMVideoCodecType_AppleProRes4444
        }
        #expect(fourCC(CMFormatDescriptionGetMediaSubType(format)) == fourCC(expectedCode))
        let size = CMVideoFormatDescriptionGetDimensions(format)
        #expect(size.width == 640 && size.height == 360)
        #expect(abs(try await video.load(.nominalFrameRate) - 30) < 0.01)
        func colorTag(_ key: CFString) -> String? { CMFormatDescriptionGetExtension(format, extensionKey: key) as? String }
        #expect(colorTag(kCMFormatDescriptionExtension_ColorPrimaries) == kCMFormatDescriptionColorPrimaries_ITU_R_709_2 as String)
        #expect(colorTag(kCMFormatDescriptionExtension_TransferFunction) == kCMFormatDescriptionTransferFunction_ITU_R_709_2 as String)
        #expect(colorTag(kCMFormatDescriptionExtension_YCbCrMatrix) == kCMFormatDescriptionYCbCrMatrix_ITU_R_709_2 as String)
        let frames = try await readTrack(of: destination, mediaType: .video, outputSettings: nil, into: 0) { count, sample in
            count += CMSampleBufferGetNumSamples(sample)
        }
        #expect(frames == 30)

        let audio = try #require(try await asset.loadTracks(withMediaType: .audio).first)
        let audioFormat = try #require(try await audio.load(.formatDescriptions).first)
        let asbd = try #require(CMAudioFormatDescriptionGetStreamBasicDescription(audioFormat)?.pointee)
        #expect(asbd.mFormatID == (codec.fileType == .mov ? kAudioFormatLinearPCM : kAudioFormatMPEG4AAC))
        #expect(asbd.mSampleRate == 48_000 && asbd.mChannelsPerFrame == 1)
        let (start, samples) = try await decodedAudio(of: destination)
        #expect(abs(rms(samples, start: start, from: 0.2, to: 0.8) - codecSineRMS) < 0.02)

        // Preview == export, within what the codec loses.
        let renderer = try FrameRenderer(project: project, document: .legacy(for: project), outputSize: [640, 360], frameRate: 30)
        for time in [0.0, 0.5, 29.0 / 30] {
            let decoded = try await videoFrame(of: destination, nearest: time)
            #expect(abs(decoded.time - time) < 0.001)
            let drawn = try await offThePool { try renderer.renderBytes(at: time) }
            let ssim = ssimLuma(decoded.bytes, drawn, width: 640, height: 360)
            #expect(ssim >= 0.98, "\(codec) at \(time) s: SSIM \(ssim)")
        }
    }
}

/// HEVC is tagged `hvc1` (Safari and QuickTime do not play `hev1`), in an MP4, Main profile at 8 bits 4:2:0.
@Test(.enabled(if: MetalCondition.isAvailable || MetalCondition.isRequired))
func hevcIsHvc1Main8Bit() async throws {
    try await withTemporaryDirectory { dir in
        let project = try await codecTake(in: dir, seconds: 1)
        let destination = try await export(project, .hevc, to: dir)
        #expect(destination.lastPathComponent == "out.mp4")
        #expect(try majorBrand(of: destination) == "mp42")
        let video = try #require(try await AVURLAsset(url: destination).loadTracks(withMediaType: .video).first)
        let format = try #require(try await video.load(.formatDescriptions).first)
        #expect(fourCC(CMFormatDescriptionGetMediaSubType(format)) == "hvc1")
        let atoms = CMFormatDescriptionGetExtension(format, extensionKey: kCMFormatDescriptionExtension_SampleDescriptionExtensionAtoms)
            as? [String: Any]
        // The HEVC decoder configuration record (ISO/IEC 14496-15 §8.3.3.1).
        let hvcC = [UInt8](try #require(atoms?["hvcC"] as? Data))
        try #require(hvcC.count > 22)
        #expect(hvcC[0] == 1, "configurationVersion")
        #expect(hvcC[1] & 0x1F == 1, "general_profile_idc: Main")
        #expect(hvcC[16] & 0x03 == 1, "chromaFormat: 4:2:0")
        #expect(hvcC[17] & 0x07 == 0, "bitDepthLumaMinus8")
        #expect(hvcC[18] & 0x07 == 0, "bitDepthChromaMinus8")
    }
}

/// ProRes 422 is `apcn` and 422 HQ `apch`, in a QuickTime movie, with the mix's channels as 24-bit little-endian
/// interleaved integer LPCM at 48 kHz: a mono microphone gives one channel, a stereo one two.
@Test(.enabled(if: MetalCondition.isAvailable || MetalCondition.isRequired), arguments: [
    (ExportCodec.proRes422, "apcn", 1), (.proRes422HQ, "apch", 2),
])
func proResIsMovWithLPCM24(codec: ExportCodec, code: String, channels: Int) async throws {
    try await withTemporaryDirectory { dir in
        let project = try await codecTake(in: dir, seconds: 1, channels: channels)
        let destination = try await export(project, codec, to: dir)
        #expect(destination.lastPathComponent == "out.mov")
        #expect(try majorBrand(of: destination) == "qt  ")
        let asset = AVURLAsset(url: destination)
        let video = try #require(try await asset.loadTracks(withMediaType: .video).first)
        let format = try #require(try await video.load(.formatDescriptions).first)
        #expect(fourCC(CMFormatDescriptionGetMediaSubType(format)) == code)

        let audio = try #require(try await asset.loadTracks(withMediaType: .audio).first)
        let audioFormat = try #require(try await audio.load(.formatDescriptions).first)
        #expect(CMFormatDescriptionGetMediaSubType(audioFormat) == kAudioFormatLinearPCM)
        let asbd = try #require(CMAudioFormatDescriptionGetStreamBasicDescription(audioFormat)?.pointee)
        #expect(asbd.mFormatID == kAudioFormatLinearPCM)
        #expect(asbd.mSampleRate == 48_000)
        #expect(asbd.mChannelsPerFrame == UInt32(channels))
        #expect(asbd.mBitsPerChannel == 24)
        #expect(asbd.mBytesPerFrame == UInt32(3 * channels))
        #expect(asbd.mFormatFlags & kAudioFormatFlagIsSignedInteger != 0)
        #expect(asbd.mFormatFlags & kAudioFormatFlagIsFloat == 0)
        #expect(asbd.mFormatFlags & kAudioFormatFlagIsBigEndian == 0)
        #expect(asbd.mFormatFlags & kAudioFormatFlagIsNonInterleaved == 0)
        let (start, samples) = try await decodedAudio(of: destination)
        #expect(abs(rms(samples, start: start, from: 0.2, to: 0.8) - codecSineRMS) < 0.02)
    }
}

/// The codec is how the frames are encoded, never what is drawn: the four exports hand their encoders the same pixels,
/// frame for frame.
@Test(.enabled(if: MetalCondition.isAvailable || MetalCondition.isRequired))
func everyCodecGetsTheSameFrames() async throws {
    try await withTemporaryDirectory { dir in
        let project = try await codecTake(in: dir, seconds: 1)
        var seenByCodec: [ExportCodec: [Int: String]] = [:]
        for codec in ExportCodec.allCases.filter { !$0.hasAlpha } {
            let seen = Mutex<[Int: String]>([:])
            try await export(project, codec, to: dir, name: "\(codec)") { index, pixelBuffer in
                let digest = SHA256.hash(data: packedBytes(of: pixelBuffer)).map { String(format: "%02x", $0) }.joined()
                seen.withLock { $0[index] = digest }
            }
            seenByCodec[codec] = seen.withLock { $0 }
        }
        let h264 = try #require(seenByCodec[.h264])
        #expect(h264.keys.sorted() == Array(0..<30))
        #expect(Set(h264.values).count > 1, "the frames are not all alike")
        for codec in ExportCodec.allCases.filter { !$0.hasAlpha } {
            #expect(seenByCodec[codec] == h264, "\(codec)")
        }
    }
}

/// A ProRes export writes `<destination>.partial.mov`, replacing one an export that died left; cancelled halfway, it
/// leaves neither that nor the destination.
@Test(.enabled(if: MetalCondition.isAvailable || MetalCondition.isRequired), .timeLimit(.minutes(10)))
func proResPartialIsAMovAndLeavesNothing() async throws {
    try await withTemporaryDirectory { dir in
        let project = try await codecTake(in: dir, seconds: 3)
        let destination = dir.appending(path: "out.mov")
        let partial = URL(fileURLWithPath: destination.path + ".partial.mov")
        try Data("stale".utf8).write(to: partial)
        let exporter = MP4Exporter(
            project: project, settings: ExportSettings(outputSize: [640, 360], framesPerSecond: 30, codec: .proRes422HQ))
        // The export waits in its progress callback, a third of the way in, until the task has been cancelled.
        let (reached, reachedContinuation) = AsyncStream.makeStream(of: Void.self)
        let cancelled = DispatchSemaphore(value: 0)
        let progress = Mutex<[Double]>([])
        let writing = Mutex<(mov: Int?, mp4: Bool)>((nil, false))
        let task = Task {
            defer { reachedContinuation.finish() }  // so the test does not wait forever if it never gets there
            try await exporter.export(to: destination) { value in
                let first = progress.withLock { values in
                    defer { values.append(value) }
                    return value > 1.0 / 3 && !values.contains { $0 > 1.0 / 3 }
                }
                if first {
                    let size = (try? FileManager.default.attributesOfItem(atPath: partial.path))?[.size] as? Int
                    let mp4 = FileManager.default.fileExists(atPath: destination.path + ".partial.mp4")
                    writing.withLock { $0 = (size, mp4) }
                    reachedContinuation.yield()
                    cancelled.wait()
                }
            }
        }
        for await _ in reached { break }
        task.cancel()
        cancelled.signal()
        await #expect(throws: ExportError.cancelled) { try await task.value }
        let seen = writing.withLock { $0 }
        #expect(try #require(seen.mov) > 5, "the movie was being written to \(partial.lastPathComponent), the stale one gone")
        #expect(!seen.mp4)
        #expect(try partialFiles(in: dir).isEmpty)
        #expect(!FileManager.default.fileExists(atPath: destination.path))
        #expect(try #require(progress.withLock { $0 }.last) < 1)
    }
}

// MARK: - Helpers

/// RMS of the `SampleFactory` sine.
private let codecSineRMS = 0.25 / 2.0.squareRoot()

/// A take of `seconds` of a 640 × 360 screen and a microphone of `channels` channels.
private func codecTake(in dir: URL, seconds: Double, channels: Int = 1) async throws -> LoadedProject {
    let builder = try TakeBuilder(in: dir)
    try await builder.addVideoTrack(id: displayID, source: displaySource, segments: [VideoSegmentSpec(start: base, seconds: seconds)])
    try await builder.addAudioTrack(
        id: micID, source: micSource, segments: [AudioSegmentSpec(start: base, seconds: seconds, channels: channels)])
    return try LoadedProject.load(try builder.write().package.url)
}

/// Exports the legacy document of `project` with `codec` at `size` and 30 fps to `dir/<name>.<the codec's extension>`,
/// its frames seen by `sink`.
@discardableResult
private func export(
    _ project: LoadedProject, _ codec: ExportCodec, size: SIMD2<Int> = [320, 180], to dir: URL, name: String = "out",
    sink: MP4Exporter.FrameSink? = nil
) async throws -> URL {
    let destination = dir.appending(path: "\(name).\(codec.fileExtension)")
    let settings = ExportSettings(outputSize: size, framesPerSecond: 30, codec: codec)
    try await MP4Exporter(project: project, document: .legacy(for: project), settings: settings, frameSink: sink)
        .export(to: destination) { _ in }
    return destination
}

/// The four characters of `code`.
private func fourCC(_ code: FourCharCode) -> String {
    String(decoding: [24, 16, 8, 0].map { UInt8((code >> $0) & 0xFF) }, as: UTF8.self)
}

/// The major brand of the file's `ftyp` box, its first: `qt  ` for a QuickTime movie, `mp42` for an MP4.
private func majorBrand(of url: URL) throws -> String {
    let handle = try FileHandle(forReadingFrom: url)
    defer { try? handle.close() }
    let head = [UInt8](try handle.read(upToCount: 12) ?? Data())
    try #require(head.count == 12 && String(decoding: head[4..<8], as: UTF8.self) == "ftyp")
    return String(decoding: head[8..<12], as: UTF8.self)
}

/// Until milestone 4c the exporter refuses the codecs with alpha before it writes anything.
@Test func alphaExportIsUnsupportedUntil4c() async throws {
    try await withTemporaryDirectory { dir in
        let project = try await codecTake(in: dir, seconds: 1)
        for codec in [ExportCodec.hevcAlpha, .proRes4444] {
            let destination = dir.appending(path: "alpha-\(codec.rawValue).mov")
            let exporter = MP4Exporter(
                project: project, settings: ExportSettings(outputSize: [640, 360], framesPerSecond: 30, codec: codec))
            await #expect(throws: ExportError.unsupportedCodec) { try await exporter.export(to: destination) { _ in } }
            #expect(!FileManager.default.fileExists(atPath: destination.path))
        }
    }
}
