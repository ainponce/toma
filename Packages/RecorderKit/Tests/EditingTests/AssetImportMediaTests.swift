// SPDX-License-Identifier: GPL-3.0-or-later
import AVFoundation
import CryptoKit
import Darwin
import Foundation
import RecorderKitTestSupport
import Synchronization
import Testing
// Not @testable: the app uses only the public API.
import Editing
import ProjectFormat

// Phase 3 (base plan, Task B3, decision 13; design §5.4, §7.7): a clip (MOV, MP4, M4V of H.264, HEVC or ProRes) or a
// sound (M4A, MP3, WAV, AIFF, CAF) is copied into `assets/` as an image is, named by its content, once it is known to
// play.

private enum MediaFixture {
    static let base = HostTime(nanoseconds: 5_000_000_000_000)

    static func context(caches: URL) -> EditContext {
        let clock = Mutex(Date(timeIntervalSince1970: 1_794_773_523))
        let count = Mutex(0)
        return EditContext(
            app: AppInfo(name: "Toma", version: "0.5.0"), cachesRoot: caches, defaultStyle: .toma,
            now: {
                clock.withLock { date in
                    defer { date += 2 }
                    return date
                }
            },
            makeID: { prefix in
                count.withLock { count in
                    count += 1
                    return prefix + String(format: "%08x", count)
                }
            })
    }

    /// A take of 1 s of one display and a microphone, in a new package `<name>.toma`. Written off the main actor, where
    /// the tests' sessions live.
    @concurrent static func package(in dir: URL, name: String = "Fixture") async throws -> LoadedProject {
        let builder = try TakeBuilder(in: dir, name: name)
        let frame = Rect(x: 0, y: 0, width: 640, height: 360)
        try await builder.addVideoTrack(
            id: "display-1", source: TrackSource(name: "Synthetic Display", displayID: 1, globalFrame: frame, pixelScale: 1),
            segments: [VideoSegmentSpec(start: base, seconds: 1, framesPerSecond: 10, width: 320, height: 180)])
        try await builder.addAudioTrack(
            id: "mic", source: TrackSource(name: "Synthetic Microphone", deviceUniqueID: "mic"),
            segments: [AudioSegmentSpec(start: base, seconds: 1)])
        return try builder.write()
    }

    /// 0.5 s of a 440 Hz sine at `url`, of the file type its extension names in any case (AAC in an `.m4a`, PCM in the
    /// others). Written under the extension in lowercase, then renamed: `AVAudioFile` takes an `.M4A` for another type.
    @concurrent static func sound(at url: URL) async throws {
        let ext = url.pathExtension.lowercased()
        let written = url.deletingPathExtension().appendingPathExtension("written." + ext)
        try await sound(writing: written)
        try FileManager.default.moveItem(at: written, to: url)
    }

    @concurrent private static func sound(writing url: URL) async throws {
        var settings: [String: Any] = [AVSampleRateKey: 48_000, AVNumberOfChannelsKey: 1]
        if url.pathExtension.lowercased() == "m4a" {
            settings[AVFormatIDKey] = kAudioFormatMPEG4AAC
        } else {
            settings[AVFormatIDKey] = kAudioFormatLinearPCM
            settings[AVLinearPCMBitDepthKey] = 16
            settings[AVLinearPCMIsFloatKey] = false
            settings[AVLinearPCMIsBigEndianKey] = ["aif", "aiff"].contains(url.pathExtension.lowercased())
        }
        let file = try AVAudioFile(forWriting: url, settings: settings, commonFormat: .pcmFormatFloat32, interleaved: false)
        let buffer = try #require(AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: 24_000))
        buffer.frameLength = 24_000
        let samples = try #require(buffer.floatChannelData?[0])
        for n in 0..<24_000 { samples[n] = 0.25 * Float(sin(2 * Double.pi * 440 * Double(n) / 48_000)) }
        try file.write(from: buffer)
    }

    /// A clip of five 64 × 64 frames in Motion JPEG: a movie, but of none of the codecs a clip is taken in.
    @concurrent static func motionJPEG(at url: URL) async throws {
        let writer = try AVAssetWriter(outputURL: url, fileType: .mov)
        let input = AVAssetWriterInput(
            mediaType: .video, outputSettings: [AVVideoCodecKey: AVVideoCodecType.jpeg, AVVideoWidthKey: 64, AVVideoHeightKey: 64])
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: nil)
        writer.add(input)
        #expect(writer.startWriting())
        writer.startSession(atSourceTime: .zero)
        for frame in 0..<5 {
            var buffer: CVPixelBuffer?
            CVPixelBufferCreate(nil, 64, 64, kCVPixelFormatType_32BGRA, nil, &buffer)
            let pixels = try #require(buffer)
            CVPixelBufferLockBaseAddress(pixels, [])
            memset(CVPixelBufferGetBaseAddress(pixels), Int32(frame * 40), CVPixelBufferGetDataSize(pixels))
            CVPixelBufferUnlockBaseAddress(pixels, [])
            while !input.isReadyForMoreMediaData { try await Task.sleep(for: .milliseconds(5)) }
            #expect(adaptor.append(pixels, withPresentationTime: CMTime(value: CMTimeValue(frame), timescale: 10)))
        }
        input.markAsFinished()
        await writer.finishWriting()
        #expect(writer.status == .completed)
    }

    /// The name of an asset of `data`: 32 hex digits of its SHA-256.
    static func hash(_ data: Data) -> String {
        SHA256.hash(data: data).prefix(16).map { String(format: "%02x", $0) }.joined()
    }

    /// The names in `assets/` of `package`, none if there is no such folder.
    static func assets(of package: ProjectPackage) -> [String] {
        ((try? FileManager.default.contentsOfDirectory(atPath: package.assetsURL.path)) ?? []).sorted()
    }
}

@MainActor @Test func aClipIsCopiedByItsHash() async throws {
    try await withTemporaryDirectory { dir in
        let project = try await MediaFixture.package(in: dir)
        // The take's own screen segment, a movie of HEVC or H.264, as the user's clip.
        let clip = dir.appending(path: "Clip.mov")
        try FileManager.default.copyItem(at: project.package.segmentURL(take: "take-001", track: "display-1", index: 1), to: clip)
        let bytes = try Data(contentsOf: clip)
        #expect(await AssetImport.mediaRefusal(of: clip, as: .video) == nil)

        let session = try await EditSession.open(project.package.url, take: nil, context: MediaFixture.context(caches: dir.appending(path: "Caches")))
        let path = "assets/\(MediaFixture.hash(bytes)).mov"
        #expect(await session.importAsset(clip, kind: .video) == .imported(path))
        #expect(try Data(contentsOf: project.package.fileURL(path)) == bytes)
        #expect(project.package.mediaAsset(path, as: .video) != nil)
        // Twice: one copy.
        #expect(await session.importAsset(clip, kind: .video) == .imported(path))
        #expect(MediaFixture.assets(of: project.package) == [String(path.dropFirst("assets/".count))])
        // The same bytes named `.M4V` are another file, lowercased.
        let upper = dir.appending(path: "Clip.M4V")
        try bytes.write(to: upper)
        #expect(await session.importAsset(upper, kind: .video) == .imported("assets/\(MediaFixture.hash(bytes)).m4v"))
        // A sound: copied the same way.
        let sound = dir.appending(path: "Voice.m4a")
        try await MediaFixture.sound(at: sound)
        let soundPath = "assets/\(MediaFixture.hash(try Data(contentsOf: sound))).m4a"
        #expect(await session.importAsset(sound, kind: .audio) == .imported(soundPath))
        #expect(project.package.mediaAsset(soundPath, as: .audio) != nil)
        #expect(MediaFixture.assets(of: project.package).count == 3)
        await session.close()
        // Nothing of the take changed.
        #expect(try Data(contentsOf: project.package.segmentURL(take: "take-001", track: "display-1", index: 1)) == bytes)
    }
}

@MainActor @Test func notAClipIsNotPlayable() async throws {
    try await withTemporaryDirectory { dir in
        let project = try await MediaFixture.package(in: dir)
        let session = try await EditSession.open(project.package.url, take: nil, context: MediaFixture.context(caches: dir.appending(path: "Caches")))

        let garbage = dir.appending(path: "Garbage.mov")
        try Data((0..<4_096).map { UInt8(truncatingIfNeeded: $0 &* 31) }).write(to: garbage)
        let empty = dir.appending(path: "Empty.m4a")
        try Data().write(to: empty)
        let missing = dir.appending(path: "Missing.mp4")
        let jpeg = dir.appending(path: "Motion.mov")
        try await MediaFixture.motionJPEG(at: jpeg)
        // A movie of the screen alone has no sound, and a sound is no clip.
        let silent = dir.appending(path: "Screen.m4a")
        try FileManager.default.copyItem(at: project.package.segmentURL(take: "take-001", track: "display-1", index: 1), to: silent)
        let voice = dir.appending(path: "Voice.wav")
        try await MediaFixture.sound(at: voice)
        let voiceAsClip = dir.appending(path: "Voice.mov")
        try FileManager.default.copyItem(at: voice, to: voiceAsClip)
        let folder = dir.appending(path: "Folder.mov", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)

        for (url, kind) in [
            (garbage, AssetKind.video), (empty, .audio), (missing, .video), (jpeg, .video), (silent, .audio), (voice, .video),
            (voiceAsClip, .video), (folder, .video),
        ] {
            #expect(await AssetImport.mediaRefusal(of: url, as: kind) == .notPlayable, "\(url.lastPathComponent)")
            #expect(await session.importAsset(url, kind: kind) == .notPlayable, "\(url.lastPathComponent)")
        }
        #expect(!FileManager.default.fileExists(atPath: project.package.assetsURL.path))
        #expect(session.notices.isEmpty)
        await session.close()
    }
}

@MainActor @Test func audioExtensionsAreNormalized() async throws {
    try await withTemporaryDirectory { dir in
        let project = try await MediaFixture.package(in: dir)
        let session = try await EditSession.open(project.package.url, take: nil, context: MediaFixture.context(caches: dir.appending(path: "Caches")))

        var placed: Set<String> = []
        for (name, ext) in [("Voice.aif", "aiff"), ("Voice.AIFF", "aiff"), ("Voice.M4A", "m4a"), ("Voice.wav", "wav"), ("Voice.caf", "caf")] {
            let url = dir.appending(path: name)
            try await MediaFixture.sound(at: url)
            let path = "assets/\(MediaFixture.hash(try Data(contentsOf: url))).\(ext)"
            let outcome = await session.importAsset(url, kind: .audio)
            #expect(outcome == .imported(path), "\(name)")
            #expect(project.package.mediaAsset(path, as: .audio) != nil, "\(name)")
            placed.insert(String(path.dropFirst("assets/".count)))
            try FileManager.default.removeItem(at: url)
        }
        // An extension that is not taken is refused before the file is opened: a FIFO, which would never answer.
        let fifo = dir.appending(path: "Voice.ogg")
        #expect(mkfifo(fifo.path, 0o644) == 0)
        #expect(await AssetImport.mediaRefusal(of: fifo, as: .audio) == .notPlayable)
        #expect(await session.importAsset(fifo, kind: .audio) == .notPlayable)
        // One that is taken, but a FIFO: refused as no regular file, never waited on.
        let named = dir.appending(path: "Voice.mp3")
        #expect(mkfifo(named.path, 0o644) == 0)
        #expect(await session.importAsset(named, kind: .audio) == .notPlayable)
        #expect(Set(MediaFixture.assets(of: project.package)) == placed)
        await session.close()
    }
}
