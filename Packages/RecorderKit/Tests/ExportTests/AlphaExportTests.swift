// SPDX-License-Identifier: GPL-3.0-or-later
import AVFoundation
import CoreMedia
import CoreVideo
import CryptoKit
@testable import Export
import Foundation
import ProjectFormat
import RecorderKitTestSupport
// @testable for `FrameEvaluator.frame(at:)`, where the screen is drawn.
@testable import Render
import Synchronization
import Testing
import VideoToolbox

// The export with alpha (phases 4 and 5 design §7.1 and §12, plan 4c Task X3): HEVC with alpha and ProRes 4444 write the
// transparent render (`FrameRenderer(…, transparentBackground: true)`) with premultiplied alpha, nothing where the
// background was and the screen opaque; any other codec gets the frames, the attachments and the settings it got before.

private let size = SIMD2(640, 360)
private let alphaCodecs = [ExportCodec.hevcAlpha, .proRes4444]

/// `sample` painted one colour: BGRA (60, 110, 200, 255), a warm orange.
@Sendable private func paintingOrange(_ frameIndex: Int, _ sample: CMSampleBuffer) -> CMSampleBuffer {
    let pixelBuffer = CMSampleBufferGetImageBuffer(sample)!
    CVPixelBufferLockBaseAddress(pixelBuffer, [])
    defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, []) }
    let width = CVPixelBufferGetWidth(pixelBuffer)
    let base = CVPixelBufferGetBaseAddress(pixelBuffer)!
    for y in 0..<CVPixelBufferGetHeight(pixelBuffer) {
        base.advanced(by: y * CVPixelBufferGetBytesPerRow(pixelBuffer))
            .assumingMemoryBound(to: UInt32.self)
            .update(repeating: 0xFFC8_6E3C, count: width)  // little-endian BGRA (60, 110, 200, 255)
    }
    return sample
}

/// A take of `seconds` of a 640 × 360 screen with the microphone: `SampleFactory`'s moving pattern, or one colour when
/// `plain`.
private func alphaTake(in dir: URL, seconds: Double = 1, plain: Bool = false) async throws -> LoadedProject {
    let builder = try TakeBuilder(in: dir)
    try await builder.addVideoTrack(
        id: displayID, source: displaySource,
        segments: [VideoSegmentSpec(start: base, seconds: seconds, transform: plain ? paintingOrange : nil)])
    try await builder.addAudioTrack(id: micID, source: micSource, segments: [AudioSegmentSpec(start: base, seconds: seconds)])
    return try LoadedProject.load(try builder.write().package.url)
}

/// The legacy document of `project` on a green fill, with round corners and a shadow: where the fill is, the movie with
/// alpha has nothing.
private func styled(_ project: LoadedProject) -> EditDocument {
    var document = EditDocument.legacy(for: project)
    document.style.background = .color(RGBA(0.1, 0.8, 0.3, 1))
    document.style.cornerRadius = 0.04
    document.style.shadow = 0.6
    return document
}

/// Exports `document` of `project` with `codec` at `size` and 30 fps to `dir/<name>.<the codec's extension>`, its frames
/// seen by `sink`.
@discardableResult
private func export(
    _ project: LoadedProject, _ document: EditDocument, _ codec: ExportCodec, size: SIMD2<Int> = size, to dir: URL,
    name: String = "out", sink: MP4Exporter.FrameSink? = nil
) async throws -> URL {
    let destination = dir.appending(path: "\(name).\(codec.fileExtension)")
    let settings = ExportSettings(outputSize: size, framesPerSecond: 30, codec: codec)
    try await MP4Exporter(project: project, document: document, settings: settings, frameSink: sink).export(to: destination) { _ in }
    return destination
}

/// The packed BGRA bytes of every frame `codec`'s export of `document` hands its encoder, by frame.
private func framesSeen(
    _ project: LoadedProject, _ document: EditDocument, _ codec: ExportCodec, in dir: URL
) async throws -> [Int: [UInt8]] {
    let seen = Mutex<[Int: [UInt8]]>([:])
    try await export(project, document, codec, to: dir, name: "seen-\(codec.rawValue)") { index, pixelBuffer in
        let bytes = packedBytes(of: pixelBuffer)
        seen.withLock { $0[index] = bytes }
    }
    return seen.withLock { $0 }
}

/// The output seconds of frame `n` at 30 fps, as the exporter asks for it.
private func time(ofFrame n: Int) -> Double { Double(TimeMap.frameTime(n, frameRate: 30)) / 1e9 }

/// The pixels of `rect` (output pixels) `inset` pixels in from its edges.
private func interior(of rect: Rect, inset: Double) -> [(x: Int, y: Int)] {
    var points: [(x: Int, y: Int)] = []
    for y in Int((rect.y + inset).rounded(.up))..<Int((rect.y + rect.height - inset).rounded(.down)) {
        for x in Int((rect.x + inset).rounded(.up))..<Int((rect.x + rect.width - inset).rounded(.down)) {
            points.append((x, y))
        }
    }
    return points
}

/// The pixels where `drawn` (packed BGRA of `size`) has nothing within `margin` pixels, along both axes.
private func deepVoid(of drawn: [UInt8], margin: Int) -> [(x: Int, y: Int)] {
    let empty = (0..<size.x * size.y).map { drawn[$0 * 4 + 3] == 0 }
    func eroded(_ mask: [Bool], horizontal: Bool) -> [Bool] {
        (0..<size.x * size.y).map { i in
            let x = i % size.x, y = i / size.x
            return (-margin...margin).allSatisfy { d in
                let (u, v) = horizontal ? (x + d, y) : (x, y + d)
                guard u >= 0, u < size.x, v >= 0, v < size.y else { return true }
                return mask[v * size.x + u]
            }
        }
    }
    let deep = eroded(eroded(empty, horizontal: true), horizontal: false)
    return (0..<size.x * size.y).compactMap { deep[$0] ? ($0 % size.x, $0 / size.x) : nil }
}

/// The pixels of `drawn` (packed BGRA of `size`) that are not opaque and within `width` pixels (along both axes) of one
/// that is: the outer edge of what is drawn opaque, the screen's.
private func rim(of drawn: [UInt8], width: Int) -> [Bool] {
    (0..<size.x * size.y).map { i in
        guard drawn[i * 4 + 3] < 255 else { return false }
        let x = i % size.x, y = i / size.x
        for v in max(0, y - width)...min(size.y - 1, y + width) {
            for u in max(0, x - width)...min(size.x - 1, x + width) where drawn[(v * size.x + u) * 4 + 3] == 255 {
                return true
            }
        }
        return false
    }
}

private func fourCC(_ code: FourCharCode) -> String {
    String(decoding: [24, 16, 8, 0].map { UInt8((code >> $0) & 0xFF) }, as: UTF8.self)
}

// MARK: - Tests

@Suite(.enabled(if: MetalCondition.isAvailable || MetalCondition.isRequired))
struct AlphaExportTests {
    /// The movie keeps the alpha it was given (design §12): decoded in BGRA, the fill is transparent (0 in ProRes 4444, at
    /// most 2 in the lossy alpha of HEVC), the middle of the screen opaque (255, or at least 253), the shadow under it in
    /// between, and every pixel premultiplied: no colour above its alpha (by more than 3, what the codecs lose).
    @Test(arguments: alphaCodecs)
    func alphaMovHasAlphaWhereTheStageIs(codec: ExportCodec) async throws {
        try await withTemporaryDirectory { dir in
            let project = try await alphaTake(in: dir, plain: true)
            let document = styled(project)
            let destination = try await export(project, document, codec, to: dir)
            let renderer = try FrameRenderer(
                project: project, document: document, outputSize: size, frameRate: 30, transparentBackground: true)
            let drawn = renderer.scene.frame(at: 0.5)
            #expect(drawn.background == .transparent && drawn.shadow != nil)
            let screen = try #require(drawn.screen?.rect)
            let rendered = try await offThePool { try renderer.renderBytes(at: 0.5) }
            let decoded = try await videoFrame(of: destination, nearest: 0.5)
            #expect(abs(decoded.time - 0.5) < 0.001 && decoded.width == size.x && decoded.height == size.y)
            let bytes = decoded.bytes
            func at(_ x: Int, _ y: Int) -> SIMD4<UInt8> { pixel(bytes, width: size.x, x: x, y: y) }

            let lossy = codec == .hevcAlpha
            let rim = rim(of: rendered, width: 3)
            let void = deepVoid(of: rendered, margin: 4)
            #expect(void.count > 10_000, "the fill is around the stage")
            let seen = void.filter { at($0.x, $0.y).w > (lossy ? 2 : 0) }
            #expect(seen.isEmpty, "\(codec): \(seen.count) pixels of the fill not transparent, \(seen.prefix(6).map { at($0.x, $0.y) })")
            let corner = 0.04 * Double(size.y) + 3
            let opaque = interior(of: screen, inset: corner).filter { at($0.x, $0.y).w < (lossy ? 253 : 255) }
            #expect(opaque.isEmpty, "\(codec): \(opaque.count) pixels of the screen not opaque, \(opaque.prefix(6).map { at($0.x, $0.y) })")
            let middle = at(Int(screen.x + screen.width / 2), Int(screen.y + screen.height / 2))
            #expect(middle.w >= (lossy ? 253 : 255), "\(codec): \(middle)")
            let below = Int((screen.y + screen.height).rounded(.up)) + 2
            let shadow = at(Int(screen.x + screen.width / 2), below)
            #expect(shadow.w > 0 && shadow.w < 255, "\(codec): the shadow is \(shadow)")
            // Premultiplied: no colour above its alpha. HEVC codes its colour lossily at 4:2:0 apart from its alpha, so
            // along the screen's edge (where the alpha steps from 255 to the shadow's, and the colour's chroma is shared
            // with the pixels inside) a colour may stand a few levels above its alpha: there, at most 16.
            var unpremultiplied: [(Int, Int, SIMD4<UInt8>)] = []
            var overRim: [(Int, Int, SIMD4<UInt8>)] = []
            for y in 0..<size.y {
                for x in 0..<size.x {
                    let p = at(x, y)
                    let above = Int(max(p.x, p.y, p.z)) - Int(p.w)
                    if lossy, rim[y * size.x + x] {
                        if above > 16 { overRim.append((x, y, p)) }
                    } else if above > 3 {
                        unpremultiplied.append((x, y, p))
                    }
                }
            }
            #expect(unpremultiplied.isEmpty, "\(codec): \(unpremultiplied.count) pixels with colour above alpha, \(unpremultiplied.prefix(6))")
            #expect(overRim.isEmpty, "\(codec): \(overRim.count) pixels of the screen's edge far above alpha, \(overRim.prefix(6))")
        }
    }

    /// What each codec with alpha hands its encoder is the transparent render, the one the preview shows with the
    /// checkerboard (`FrameRenderer(…, transparentBackground: true)`): the same bytes, frame for frame, for both.
    @Test func alphaFramesAreTheTransparentRender() async throws {
        try await withTemporaryDirectory { dir in
            let project = try await alphaTake(in: dir)
            let document = styled(project)
            let hevc = try await framesSeen(project, document, .hevcAlpha, in: dir)
            let proRes = try await framesSeen(project, document, .proRes4444, in: dir)
            #expect(hevc.keys.sorted() == Array(0..<30))
            #expect(proRes == hevc)
            let renderer = try FrameRenderer(
                project: project, document: document, outputSize: size, frameRate: 30, transparentBackground: true)
            for n in [0, 7, 15, 29] {
                let drawn = try await offThePool { try renderer.renderBytes(at: time(ofFrame: n)) }
                #expect(hevc[n] == drawn, "frame \(n)")
            }
            #expect(hevc[15].map { pixel($0, width: size.x, x: 4, y: 4) } == SIMD4<UInt8>.zero, "nothing behind the stage")
        }
    }

    /// Inside the screen, away from its round corners, nothing is transparent: H.264 and HEVC with alpha get the same
    /// bytes there, frame for frame; outside, H.264 gets the fill and HEVC with alpha nothing.
    @Test func alphaAndOpaqueAgreeInsideTheScreen() async throws {
        try await withTemporaryDirectory { dir in
            let project = try await alphaTake(in: dir)
            let document = styled(project)
            let h264 = try await framesSeen(project, document, .h264, in: dir)
            let alpha = try await framesSeen(project, document, .hevcAlpha, in: dir)
            let renderer = try FrameRenderer(project: project, document: document, outputSize: size, frameRate: 30)
            let screen = try #require(renderer.scene.frame(at: 0.5).screen?.rect)
            let inside = interior(of: screen, inset: 0.04 * Double(size.y) + 2)
            #expect(inside.count > 80_000)
            for n in 0..<30 {
                let a = try #require(h264[n]), b = try #require(alpha[n])
                let differ = inside.filter { pixel(a, width: size.x, x: $0.x, y: $0.y) != pixel(b, width: size.x, x: $0.x, y: $0.y) }
                #expect(differ.isEmpty, "frame \(n): \(differ.count) pixels of the screen differ")
                #expect(pixel(a, width: size.x, x: 4, y: 4).w == 255 && pixel(b, width: size.x, x: 4, y: 4) == .zero, "frame \(n)")
            }
        }
    }

    /// Only the codecs with alpha tag their buffers as premultiplied (`kCVImageBufferAlphaChannelModeKey`, which
    /// VideoToolbox matches against the encoder's alpha mode): the buffers of the four others carry the attachments they
    /// always carried, the three Rec. 709 tags and what the writer's pool puts on its buffers, the same for the four, and
    /// no alpha mode; the two with alpha carry those and their alpha mode.
    @Test func opaqueBuffersCarryNoAlphaMode() async throws {
        try await withTemporaryDirectory { dir in
            let project = try await alphaTake(in: dir)
            let rec709: Set<String> = [
                kCVImageBufferColorPrimariesKey as String, kCVImageBufferTransferFunctionKey as String,
                kCVImageBufferYCbCrMatrixKey as String,
            ]
            var opaqueKeys: Set<String>?
            for codec in ExportCodec.allCases {
                let modes = Mutex<[String?]>([])
                let keys = Mutex<Set<String>>([])
                try await export(project, styled(project), codec, size: [320, 180], to: dir, name: "modes-\(codec.rawValue)") { _, pixelBuffer in
                    let mode = CVBufferCopyAttachment(pixelBuffer, kCVImageBufferAlphaChannelModeKey, nil) as? String
                    let attached = (CVBufferCopyAttachments(pixelBuffer, .shouldPropagate) as? [String: Any]).map { Set($0.keys) } ?? []
                    modes.withLock { $0.append(mode) }
                    keys.withLock { $0.formUnion(attached) }
                }
                let seen = modes.withLock { $0 }, attached = keys.withLock { $0 }
                #expect(seen.count == 30, "\(codec)")
                #expect(attached.isSuperset(of: rec709), "\(codec): \(attached)")
                if codec.hasAlpha {
                    #expect(seen.allSatisfy { $0 == kCVImageBufferAlphaChannelMode_PremultipliedAlpha as String }, "\(codec): \(Set(seen))")
                    #expect(attached.subtracting([kCVImageBufferAlphaChannelModeKey as String]) == opaqueKeys, "\(codec): \(attached)")
                } else {
                    #expect(seen.allSatisfy { $0 == nil }, "\(codec): \(Set(seen))")
                    #expect(!attached.contains(kCVImageBufferAlphaChannelModeKey as String), "\(codec)")
                    #expect(opaqueKeys == nil || attached == opaqueKeys, "\(codec): \(attached)")
                    opaqueKeys = opaqueKeys ?? attached
                }
            }
        }
    }

    /// ProRes 4444 is given each frame in 16-bit RGBA, every 8-bit value × 257 exactly (so 255, opaque, stays opaque in
    /// the file: its encoder widens an 8-bit alpha by × 256), with the frame's attachments; every other codec its BGRA.
    @Test func proRes4444FramesAreWidenedExactly() throws {
        #expect(ExportCodec.allCases.filter { MP4Exporter.sourcePixelFormat(of: $0) != kCVPixelFormatType_32BGRA } == [.proRes4444])
        #expect(MP4Exporter.sourcePixelFormat(of: .proRes4444) == kCVPixelFormatType_64RGBALE)
        let width = 256, height = 3
        func buffer(_ format: OSType) throws -> CVPixelBuffer {
            var made: CVPixelBuffer?
            let status = CVPixelBufferCreate(
                kCFAllocatorDefault, width, height, format,
                [kCVPixelBufferIOSurfacePropertiesKey as String: [String: Any]()] as CFDictionary, &made)
            try #require(status == kCVReturnSuccess)
            return try #require(made)
        }
        let drawn = try buffer(kCVPixelFormatType_32BGRA), wide = try buffer(kCVPixelFormatType_64RGBALE)
        CVPixelBufferLockBaseAddress(drawn, [])
        let source = CVPixelBufferGetBaseAddress(drawn)!.assumingMemoryBound(to: UInt8.self)
        for y in 0..<height {
            for x in 0..<width {
                let p = source + y * CVPixelBufferGetBytesPerRow(drawn) + x * 4
                (p[0], p[1], p[2], p[3]) = (UInt8(x), UInt8(255 - x), UInt8((x + 85 * y) % 256), UInt8((x * 7 + y) % 256))
            }
        }
        CVPixelBufferUnlockBaseAddress(drawn, [])
        CVBufferSetAttachment(drawn, kCVImageBufferAlphaChannelModeKey, kCVImageBufferAlphaChannelMode_PremultipliedAlpha, .shouldPropagate)
        try MP4Exporter.widen(drawn, into: wide)
        CVPixelBufferLockBaseAddress(wide, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(wide, .readOnly) }
        let widened = CVPixelBufferGetBaseAddress(wide)!
        var wrong = 0
        for y in 0..<height {
            for x in 0..<width {
                let p = (widened + y * CVPixelBufferGetBytesPerRow(wide)).assumingMemoryBound(to: UInt16.self) + x * 4
                let (b, g, r, a) = (x, 255 - x, (x + 85 * y) % 256, (x * 7 + y) % 256)
                if [p[0], p[1], p[2], p[3]] != [r, g, b, a].map({ UInt16($0 * 257) }) { wrong += 1 }
            }
        }
        #expect(wrong == 0)
        #expect(CVBufferCopyAttachment(wide, kCVImageBufferAlphaChannelModeKey, nil) as? String
            == kCVImageBufferAlphaChannelMode_PremultipliedAlpha as String)
        #expect(throws: ExportError.self) { try MP4Exporter.widen(wide, into: drawn) }
    }

    /// HEVC with alpha: its codec, HEVC's bitrate for its colour, its alpha premultiplied and nearly lossless; ProRes 4444
    /// its codec alone, as ProRes 422. Both tagged Rec. 709 as every codec is.
    @Test func alphaVideoSettings() {
        let colors: [String: Any] = [
            AVVideoColorPrimariesKey: AVVideoColorPrimaries_ITU_R_709_2,
            AVVideoTransferFunctionKey: AVVideoTransferFunction_ITU_R_709_2,
            AVVideoYCbCrMatrixKey: AVVideoYCbCrMatrix_ITU_R_709_2,
        ]
        let hevc = MP4Exporter.videoSettings(ExportSettings(outputSize: [1280, 720], framesPerSecond: 30, codec: .hevcAlpha))
        let expectedHEVC: [String: Any] = [
            AVVideoCodecKey: AVVideoCodecType.hevcWithAlpha,
            AVVideoWidthKey: 1280,
            AVVideoHeightKey: 720,
            AVVideoColorPropertiesKey: colors,
            AVVideoCompressionPropertiesKey: [
                AVVideoAverageBitRateKey: 1_327_104,  // HEVC's: 0.6 × 1280 × 720 × 30 × 0.08
                AVVideoExpectedSourceFrameRateKey: 30,
                kVTCompressionPropertyKey_AlphaChannelMode as String: kVTAlphaChannelMode_PremultipliedAlpha as String,
                kVTCompressionPropertyKey_TargetQualityForAlpha as String: 1.0,
            ],
        ]
        #expect(NSDictionary(dictionary: hevc).isEqual(to: expectedHEVC))
        let proRes = MP4Exporter.videoSettings(ExportSettings(outputSize: [3840, 2160], framesPerSecond: 60, codec: .proRes4444))
        let expectedProRes: [String: Any] = [
            AVVideoCodecKey: AVVideoCodecType.proRes4444, AVVideoWidthKey: 3840, AVVideoHeightKey: 2160,
            AVVideoColorPropertiesKey: colors,
        ]
        #expect(NSDictionary(dictionary: proRes).isEqual(to: expectedProRes))
        // The audio: AAC for HEVC with alpha, as HEVC; 24-bit LPCM for ProRes 4444, as ProRes 422.
        var opaque = ExportSettings(outputSize: [1280, 720], framesPerSecond: 30, codec: .hevc)
        var alpha = opaque
        alpha.codec = .hevcAlpha
        #expect(NSDictionary(dictionary: MP4Exporter.audioSettings(alpha, channels: 2))
            .isEqual(to: MP4Exporter.audioSettings(opaque, channels: 2)))
        opaque.codec = .proRes422
        alpha.codec = .proRes4444
        #expect(NSDictionary(dictionary: MP4Exporter.audioSettings(alpha, channels: 1))
            .isEqual(to: MP4Exporter.audioSettings(opaque, channels: 1)))
    }

    /// The writer of each codec with alpha takes its settings at every size of the export sheet: nothing is refused at
    /// export time (decision 5's `TargetQualityForAlpha` among them).
    @Test func alphaSettingsApply() throws {
        for codec in alphaCodecs {
            for resolution in ExportResolution.allCases {
                let settings = ExportSettings(aspect: .landscape, resolution: resolution, framesPerSecond: 60, quality: .high, codec: codec)
                let writer = try AVAssetWriter(
                    outputURL: FileManager.default.temporaryDirectory.appending(path: "never-\(UUID().uuidString).mov"),
                    fileType: codec.fileType)
                #expect(writer.canApply(outputSettings: MP4Exporter.videoSettings(settings), forMediaType: .video), "\(codec) \(resolution)")
            }
        }
    }
}

// MARK: - Measures

/// What the codecs with alpha spend and how fast they export against H.264, HEVC and ProRes 422 and 422 HQ (plan 4c
/// decision 6, `docs/performance.md`):
/// at 1920 × 1080 and 60 fps, the take of these tests (`SampleFactory`'s moving pattern, `TOMA_BENCH_SECONDS` s, 60 by
/// default) on its fill with a shadow, and golden 4's project of phase 3 (8.6 s, `GoldenPhase3Project`). Prints, per
/// project and codec, the export's time and its video track's bytes, as bits per second, per pixel and as a share of
/// H.264's.
@Test(.enabled(if: ProcessInfo.processInfo.environment["TOMA_BENCH"] == "1"), .timeLimit(.minutes(60)))
func alphaCodecRates() async throws {
    let seconds = Double(ProcessInfo.processInfo.environment["TOMA_BENCH_SECONDS"] ?? "") ?? 60
    try await withTemporaryDirectory { dir in
        for folder in ["take", "golden"] {
            try FileManager.default.createDirectory(at: dir.appending(path: folder), withIntermediateDirectories: false)
        }
        let take = try await alphaTake(in: dir.appending(path: "take"), seconds: seconds)
        let golden = try await GoldenPhase3Project.makeProject(in: dir.appending(path: "golden"))
        let projects = [
            ("take", take, styled(take)), ("golden4", golden, try GoldenPhase3Project.makeDocument(for: golden)),
        ]
        for (name, project, document) in projects {
            var h264Bits = 0.0
            for codec in [ExportCodec.h264, .hevc, .hevcAlpha, .proRes422, .proRes422HQ, .proRes4444] {
                let settings = ExportSettings(outputSize: [1920, 1080], framesPerSecond: 60, codec: codec)
                let destination = dir.appending(path: "\(name)-\(codec.rawValue).\(codec.fileExtension)")
                let clock = ContinuousClock(), start = clock.now
                try await MP4Exporter(project: project, document: document, settings: settings).export(to: destination) { _ in }
                let elapsed = (clock.now - start) / .seconds(1)
                let track = try #require(try await AVURLAsset(url: destination).loadTracks(withMediaType: .video).first)
                let bytes = Double(try await track.load(.totalSampleDataLength))
                let duration = try await track.load(.timeRange).duration.seconds
                let bitsPerSecond = bytes * 8 / duration
                if codec == .h264 { h264Bits = bitsPerSecond }
                print(String(
                    format: "alphaCodecRates %@ %@: %.1f s of video in %.2f s (%.2f× real time), %.0f bytes, %.3f Mb/s, %.3f bits per pixel, %.3f of H.264's, %.3f of H.264's asked (%d b/s)",
                    name, codec.rawValue, duration, elapsed, duration / elapsed, bytes, bitsPerSecond / 1e6,
                    bitsPerSecond / (1920 * 1080 * 60), bitsPerSecond / h264Bits,
                    bitsPerSecond / Double(settings.averageBitRate), settings.averageBitRate))
                try FileManager.default.removeItem(at: destination)
            }
        }
    }
}
