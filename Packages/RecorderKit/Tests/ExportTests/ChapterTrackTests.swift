// SPDX-License-Identifier: GPL-3.0-or-later
import AVFoundation
import Analysis
import CoreMedia
import CryptoKit
@testable import Export
import Foundation
import ProjectFormat
import RecorderKitTestSupport
import Synchronization
import Testing

// The chapter track of the MP4 and the MOV (phase 3 plan 3d, decision 5): a text track of one sample per chapter, in a
// timescale of 1000, tied to the video as its chapter list and disabled, which QuickTime and `AVAsset` read back. It
// never changes a frame or a sample; without chapters the file has the tracks of before.

private let second: Int64 = 1_000_000_000

/// Intro at 0, Demo at 1.5 s and Fin at 3 s.
private let threeChapters = [
    Chapter(start: 0, title: "Intro"), Chapter(start: 3 * second / 2, title: "Demo"), Chapter(start: 3 * second, title: "Fin"),
]

/// A chapter as a file has it: its start and end in seconds, and its title.
private struct ReadChapter: Equatable {
    var start: Double
    var end: Double
    var title: String
}

/// The 4 s take of `GoldenDocuments` (`cutsAndSpeed`'s: its screen, its camera and its microphone) in `dir`.
private func fourSecondTake(in dir: URL) async throws -> LoadedProject {
    try await GoldenDocuments.makeProject("cutsAndSpeed", in: dir)
}

/// Exports `range` (all of it for `nil`) of the legacy document of `project` with `codec` at 640 × 360 and 30 fps, with
/// `chapters` in `language`, to `dir/<name>.<the codec's extension>`, its frames seen by `sink`.
private func export(
    _ project: LoadedProject, _ codec: ExportCodec, chapters: [Chapter], language: String? = nil, range: ExportRange? = nil,
    to dir: URL, name: String, sink: MP4Exporter.FrameSink? = nil
) async throws -> URL {
    let destination = dir.appending(path: "\(name).\(codec.fileExtension)")
    let settings = ExportSettings(
        outputSize: [640, 360], framesPerSecond: 30, codec: codec, chapters: chapters, chapterLanguage: language)
    try await MP4Exporter(project: project, document: .legacy(for: project), settings: settings, range: range, frameSink: sink)
        .export(to: destination) { _ in }
    return destination
}

/// The chapters of the file at `url`: those `loadChapterMetadataGroups(bestMatchingPreferredLanguages:)` gives for
/// `languages`, or, for `nil`, those of the first locale the file has chapters in.
private func chapters(of url: URL, languages: [String]?) async throws -> [ReadChapter] {
    let asset = AVURLAsset(url: url)
    let groups: [AVTimedMetadataGroup]
    if let languages {
        groups = try await asset.loadChapterMetadataGroups(bestMatchingPreferredLanguages: languages)
    } else {
        let locale = try #require(try await asset.load(.availableChapterLocales).first)
        groups = try await asset.loadChapterMetadataGroups(withTitleLocale: locale, containingItemsWithCommonKeys: [])
    }
    var read: [ReadChapter] = []
    for group in groups {
        let item = AVMetadataItem.metadataItems(from: group.items, filteredByIdentifier: .commonIdentifierTitle).first
        let title = try await item?.load(.stringValue)
        read.append(ReadChapter(start: group.timeRange.start.seconds, end: group.timeRange.end.seconds, title: title ?? ""))
    }
    return read
}

/// Whether `read` are `expected`, with their starts and ends within 1 ms.
private func matches(_ read: [ReadChapter], _ expected: [ReadChapter]) -> Bool {
    read.count == expected.count && zip(read, expected).allSatisfy { read, expected in
        read.title == expected.title && abs(read.start - expected.start) <= 0.001 && abs(read.end - expected.end) <= 0.001
    }
}

/// The media types of the file's tracks, in order.
private func trackKinds(of url: URL) async throws -> [AVMediaType] {
    try await AVURLAsset(url: url).load(.tracks).map(\.mediaType)
}

/// The bytes of every sample of the file's audio track, as stored (AAC packets, or LPCM), one after the other.
private func storedAudio(of url: URL) async throws -> [UInt8] {
    try await readTrack(of: url, mediaType: .audio, outputSettings: nil, into: [UInt8]()) { bytes, sample in
        guard let data = CMSampleBufferGetDataBuffer(sample) else { return }
        var stored = [UInt8](repeating: 0, count: CMBlockBufferGetDataLength(data))
        _ = stored.withUnsafeMutableBytes { CMBlockBufferCopyDataBytes(data, atOffset: 0, dataLength: $0.count, destination: $0.baseAddress!) }
        bytes += stored
    }
}

/// The four characters of `code`.
private func fourCC(_ code: FourCharCode) -> String {
    String(decoding: [24, 16, 8, 0].map { UInt8((code >> $0) & 0xFF) }, as: UTF8.self)
}

/// H.264 in the MP4 (`tx3g` text) and ProRes 422 in the MOV (QuickTime `text`): three chapters come back with their
/// titles and starts, the last up to the end, for a reader that asks for Spanish; the text track is disabled, of a
/// timescale of 1000 and the video's chapter list.
@Test(.enabled(if: MetalCondition.isAvailable || MetalCondition.isRequired), arguments: [ExportCodec.h264, .proRes422])
func chaptersRoundTripInMP4AndMOV(codec: ExportCodec) async throws {
    try await withTemporaryDirectory { dir in
        let project = try await fourSecondTake(in: dir)
        let url = try await export(project, codec, chapters: threeChapters, language: "es", to: dir, name: "chapters")
        let duration = try await AVURLAsset(url: url).load(.duration).seconds
        #expect(abs(duration - 4) < 0.001)
        let read = try await chapters(of: url, languages: ["es"])
        let expected = [
            ReadChapter(start: 0, end: 1.5, title: "Intro"), ReadChapter(start: 1.5, end: 3, title: "Demo"),
            ReadChapter(start: 3, end: duration, title: "Fin"),
        ]
        #expect(matches(read, expected), "\(read)")
        #expect(try await trackKinds(of: url) == [.video, .audio, .text])

        let asset = AVURLAsset(url: url)
        let text = try #require(try await asset.loadTracks(withMediaType: .text).first)
        #expect(try await text.load(.isEnabled) == false)
        #expect(try await text.load(.naturalTimeScale) == 1000)
        #expect(try await text.load(.languageCode) == "spa")
        let format = try #require(try await text.load(.formatDescriptions).first)
        #expect(fourCC(CMFormatDescriptionGetMediaSubType(format)) == (codec.fileType == .mp4 ? "tx3g" : "text"))
        let video = try #require(try await asset.loadTracks(withMediaType: .video).first)
        let chapterList = try await video.loadAssociatedTracks(ofType: .chapterList)
        #expect(chapterList.map(\.trackID) == [text.trackID])
    }
}

/// With chapters or without, the encoders are handed the same frames, and the file holds the same audio, byte for byte:
/// the same AAC packets in the MP4, the same LPCM in the MOV. (The bytes, not what they decode to: two decodings of the
/// same AAC can differ by 2·10⁻⁷.)
@Test(.enabled(if: MetalCondition.isAvailable || MetalCondition.isRequired), arguments: [ExportCodec.h264, .proRes422])
func chaptersDoNotTouchFramesOrSound(codec: ExportCodec) async throws {
    try await withTemporaryDirectory { dir in
        let project = try await fourSecondTake(in: dir)
        var frames: [[Int: String]] = []
        var sounds: [[UInt8]] = []
        for (name, list) in [("without", [Chapter]()), ("with", threeChapters)] {
            let seen = Mutex<[Int: String]>([:])
            let url = try await export(project, codec, chapters: list, language: "es", to: dir, name: name) { index, pixelBuffer in
                let digest = SHA256.hash(data: packedBytes(of: pixelBuffer)).map { String(format: "%02x", $0) }.joined()
                seen.withLock { $0[index] = digest }
            }
            frames.append(seen.withLock { $0 })
            sounds.append(try await storedAudio(of: url))
        }
        #expect(frames[0].keys.sorted() == Array(0..<120))
        #expect(Set(frames[0].values).count > 1, "the frames are not all alike")
        #expect(frames[1] == frames[0])
        #expect(!sounds[0].isEmpty)
        #expect(sounds[1] == sounds[0])
    }
}

/// No chapters: the file has its video and its audio and nothing else, no chapter list, as before.
@Test(.enabled(if: MetalCondition.isAvailable || MetalCondition.isRequired), arguments: [ExportCodec.h264, .proRes422])
func noChaptersNoTextTrack(codec: ExportCodec) async throws {
    try await withTemporaryDirectory { dir in
        let project = try await fourSecondTake(in: dir)
        let url = try await export(project, codec, chapters: [], language: "es", to: dir, name: "none")
        #expect(try await trackKinds(of: url) == [.video, .audio])
        let asset = AVURLAsset(url: url)
        #expect(try await asset.load(.availableChapterLocales).isEmpty)
        let video = try #require(try await asset.loadTracks(withMediaType: .video).first)
        #expect(try await video.loadAssociatedTracks(ofType: .chapterList).isEmpty)
    }
}

/// The range [1, 3.5) s has the chapter in force at its start at 0 and the others shifted by its start: Intro at 0, Demo
/// at 0.5 s and Fin at 2 s, up to its end at 2.5 s.
@Test(.enabled(if: MetalCondition.isAvailable || MetalCondition.isRequired))
func aRangeExportsItsChapters() async throws {
    try await withTemporaryDirectory { dir in
        let project = try await fourSecondTake(in: dir)
        let range = ExportRange(start: second, end: 7 * second / 2)
        let url = try await export(project, .h264, chapters: threeChapters, language: "es", range: range, to: dir, name: "range")
        let read = try await chapters(of: url, languages: ["es"])
        let expected = [
            ReadChapter(start: 0, end: 0.5, title: "Intro"), ReadChapter(start: 0.5, end: 2, title: "Demo"),
            ReadChapter(start: 2, end: 2.5, title: "Fin"),
        ]
        #expect(matches(read, expected), "\(read)")
    }
}

/// Accents and emoji come back as they were written, in the MP4 and the MOV; without a language the track's is
/// undetermined (`und`), and its chapters are read in that locale.
@Test(.enabled(if: MetalCondition.isAvailable || MetalCondition.isRequired), arguments: [ExportCodec.h264, .proRes422])
func accentsAndEmojiAreKept(codec: ExportCodec) async throws {
    try await withTemporaryDirectory { dir in
        let project = try await fourSecondTake(in: dir)
        let titled = [Chapter(start: 0, title: "Configuración ✨"), Chapter(start: 2 * second, title: "Año 2026, ¿qué sigue? 🎬")]
        let url = try await export(project, codec, chapters: titled, to: dir, name: "accents")
        let text = try #require(try await AVURLAsset(url: url).loadTracks(withMediaType: .text).first)
        #expect(try await text.load(.languageCode) == "und")
        let read = try await chapters(of: url, languages: nil)
        #expect(read.map(\.title) == ["Configuración ✨", "Año 2026, ¿qué sigue? 🎬"])
    }
}

/// The samples: one per chapter, in a timescale of 1000, each its title's UTF-8 after its length in 16 bits big-endian,
/// followed in QuickTime text by the `encd` atom that says it is UTF-8; each lasts up to the next, the last up to the
/// end. A chapter at or after the end is left out, and of two that round to the same millisecond, the later one stays.
@Test func samplesAreLengthPrefixedUTF8() throws {
    for fileType in [AVFileType.mp4, .mov] {
        let format = try ChapterTrack.formatDescription(for: fileType)
        #expect(CMFormatDescriptionGetMediaType(format) == kCMMediaType_Text)
        let chapters = [
            Chapter(start: 0, title: "Intro"), Chapter(start: 300_000, title: "Ñandú"), Chapter(start: 1_000_000_000, title: "Demo"),
            Chapter(start: 2_500_000_000, title: "Fin"), Chapter(start: 4_000_000_000, title: "After"),
        ]
        let samples = try ChapterTrack.samples(chapters, duration: 4_000_000_000, format: format)
        let timing = samples.map { ($0.presentationTimeStamp, $0.duration) }
        #expect(timing.map(\.0) == [0, 1000, 2500].map { CMTime(value: $0, timescale: ChapterTrack.timescale) })
        #expect(timing.map(\.1) == [1000, 1500, 1500].map { CMTime(value: $0, timescale: ChapterTrack.timescale) })
        let bytes = try samples.map { sample -> [UInt8] in
            let data = try #require(CMSampleBufferGetDataBuffer(sample))
            var bytes = [UInt8](repeating: 0, count: CMBlockBufferGetDataLength(data))
            _ = bytes.withUnsafeMutableBytes { CMBlockBufferCopyDataBytes(data, atOffset: 0, dataLength: $0.count, destination: $0.baseAddress!) }
            return bytes
        }
        let encd: [UInt8] = fileType == .mov ? [0, 0, 0, 12] + Array("encd".utf8) + [0, 0, 1, 0] : []
        #expect(bytes[0] == [0, 7] + Array("Ñandú".utf8) + encd)
        #expect(bytes[1] == [0, 4] + Array("Demo".utf8) + encd)
        #expect(bytes[2] == [0, 3] + Array("Fin".utf8) + encd)
    }
    #expect(throws: ExportError.self) { try ChapterTrack.formatDescription(for: .m4a) }
}

