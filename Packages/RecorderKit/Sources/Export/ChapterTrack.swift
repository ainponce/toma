// SPDX-License-Identifier: GPL-3.0-or-later
import AVFoundation
import Analysis
import CoreMedia

/// The chapter track of an MP4 or a MOV (phase 3 plan 3d, decision 5): a text track, 3GPP text (`tx3g`) in the MP4 and
/// QuickTime text (`text`) in the MOV, with one sample per chapter in a timescale of 1000, which the export ties to the
/// video as its chapter list (`AVAssetTrack.AssociationType.chapterList`) and marks disabled, so players list the
/// chapters and never draw them. Each sample is its title's UTF-8 after its length in 16 bits big-endian; in QuickTime
/// text it is followed by an `encd` atom saying it is UTF-8, without which QuickTime reads it as Mac Roman.
public enum ChapterTrack {
    /// The track's timescale: milliseconds.
    public static let timescale: CMTimeScale = 1000

    /// `encd` (12 bytes, kTextEncodingUnicodeDefault in UTF-8): the encoding of a sample of QuickTime text.
    private static let utf8Encoding: [UInt8] = [0, 0, 0, 12] + Array("encd".utf8) + [0, 0, 1, 0]

    /// The format of the chapter track of a file of `fileType`: 3GPP text for `.mp4`, QuickTime text for `.mov`, white
    /// on black in a box of no size, as no one draws it.
    /// - Throws: `ExportError.writerFailed` for another file type, or when Core Media cannot make the format.
    public static func formatDescription(for fileType: AVFileType) throws -> CMFormatDescription {
        let subType: CMTextFormatType
        let extensions: [CFString: Any]
        let box: [CFString: Any] = [
            kCMTextFormatDescriptionRect_Top: 0, kCMTextFormatDescriptionRect_Left: 0,
            kCMTextFormatDescriptionRect_Bottom: 0, kCMTextFormatDescriptionRect_Right: 0,
        ]
        switch fileType {
        case .mp4:
            subType = kCMTextFormatType_3GText
            let white: [CFString: Any] = [
                kCMTextFormatDescriptionColor_Red: 255, kCMTextFormatDescriptionColor_Green: 255,
                kCMTextFormatDescriptionColor_Blue: 255, kCMTextFormatDescriptionColor_Alpha: 255,
            ]
            extensions = [
                kCMTextFormatDescriptionExtension_DisplayFlags: 0,
                kCMTextFormatDescriptionExtension_HorizontalJustification: 0,
                kCMTextFormatDescriptionExtension_VerticalJustification: 0,
                kCMTextFormatDescriptionExtension_BackgroundColor: [
                    kCMTextFormatDescriptionColor_Red: 0, kCMTextFormatDescriptionColor_Green: 0,
                    kCMTextFormatDescriptionColor_Blue: 0, kCMTextFormatDescriptionColor_Alpha: 255,
                ],
                kCMTextFormatDescriptionExtension_DefaultTextBox: box,
                kCMTextFormatDescriptionExtension_DefaultStyle: [
                    kCMTextFormatDescriptionStyle_StartChar: 0, kCMTextFormatDescriptionStyle_EndChar: 0,
                    kCMTextFormatDescriptionStyle_Font: 1, kCMTextFormatDescriptionStyle_FontFace: 0,
                    kCMTextFormatDescriptionStyle_FontSize: 12, kCMTextFormatDescriptionStyle_ForegroundColor: white,
                ],
                kCMTextFormatDescriptionExtension_FontTable: ["1": "Sans-Serif"],
            ]
        case .mov:
            subType = kCMTextFormatType_QTText
            extensions = [
                kCMTextFormatDescriptionExtension_DisplayFlags: 0,
                kCMTextFormatDescriptionExtension_TextJustification: 0,
                kCMTextFormatDescriptionExtension_BackgroundColor: [
                    kCMTextFormatDescriptionColor_Red: 0, kCMTextFormatDescriptionColor_Green: 0, kCMTextFormatDescriptionColor_Blue: 0,
                ],
                kCMTextFormatDescriptionExtension_DefaultTextBox: box,
                kCMTextFormatDescriptionExtension_DefaultStyle: [
                    kCMTextFormatDescriptionStyle_StartChar: 0, kCMTextFormatDescriptionStyle_Height: 0,
                    kCMTextFormatDescriptionStyle_Ascent: 0, kCMTextFormatDescriptionStyle_Font: 0,
                    kCMTextFormatDescriptionStyle_FontFace: 0, kCMTextFormatDescriptionStyle_FontSize: 12,
                    kCMTextFormatDescriptionStyle_ForegroundColor: [
                        kCMTextFormatDescriptionColor_Red: 65535, kCMTextFormatDescriptionColor_Green: 65535,
                        kCMTextFormatDescriptionColor_Blue: 65535,
                    ],
                ],
                kCMTextFormatDescriptionExtension_DefaultFontName: "Helvetica",
            ]
        default:
            throw ExportError.writerFailed("no chapter track in a file of type \(fileType.rawValue)")
        }
        var format: CMFormatDescription?
        let status = CMFormatDescriptionCreate(
            allocator: kCFAllocatorDefault, mediaType: kCMMediaType_Text, mediaSubType: subType,
            extensions: extensions as CFDictionary, formatDescriptionOut: &format)
        guard status == noErr, let format else {
            throw ExportError.writerFailed("cannot make the chapter track's format (OSStatus \(status))")
        }
        return format
    }

    /// One sample of `format` per chapter of `chapters` (in output order, starts in ns from the file's start) in a file
    /// whose video lasts `duration` ns: each from its start, rounded to the millisecond, up to the next one's, the last
    /// up to `duration`'s. A chapter that would last no millisecond is left out: one at or after the end, and the earlier
    /// of two that round to the same millisecond (the one in force at a range's start, when the next begins less than
    /// half a millisecond after it). A title longer than the 65 535 bytes of its length is cut at a character.
    /// - Throws: `ExportError.writerFailed` when Core Media cannot make a sample.
    public static func samples(_ chapters: [Chapter], duration: Int64, format: CMFormatDescription) throws -> [CMSampleBuffer] {
        let end = milliseconds(duration)
        var starts: [(start: Int64, title: String)] = []
        for chapter in chapters {
            let start = milliseconds(chapter.start)
            guard start < end else { continue }
            if let last = starts.last, last.start >= start { starts.removeLast() }
            starts.append((start, chapter.title))
        }
        let trailer = CMFormatDescriptionGetMediaSubType(format) == kCMTextFormatType_QTText ? utf8Encoding : []
        return try starts.indices.map { index in
            let (start, title) = starts[index]
            let next = index + 1 < starts.count ? starts[index + 1].start : end
            let text = Array(fitting(title).utf8)
            let bytes = [UInt8(text.count >> 8), UInt8(text.count & 0xFF)] + text + trailer
            return try sample(bytes, start: start, duration: next - start, format: format)
        }
    }

    /// `ns` nanoseconds in whole milliseconds, rounded; never below 0.
    private static func milliseconds(_ ns: Int64) -> Int64 {
        (max(ns, 0) + 500_000) / 1_000_000
    }

    /// `title`, cut at a character so its UTF-8 fits a 16-bit length.
    private static func fitting(_ title: String) -> String {
        guard title.utf8.count > Int(UInt16.max) else { return title }
        var cut = ""
        for character in title {
            guard cut.utf8.count + character.utf8.count <= Int(UInt16.max) else { break }
            cut.append(character)
        }
        return cut
    }

    /// A sample of `format` holding `bytes`, from `start` for `duration` milliseconds.
    private static func sample(_ bytes: [UInt8], start: Int64, duration: Int64, format: CMFormatDescription) throws -> CMSampleBuffer {
        var block: CMBlockBuffer?
        var status = CMBlockBufferCreateWithMemoryBlock(
            allocator: kCFAllocatorDefault, memoryBlock: nil, blockLength: bytes.count, blockAllocator: kCFAllocatorDefault,
            customBlockSource: nil, offsetToData: 0, dataLength: bytes.count, flags: kCMBlockBufferAssureMemoryNowFlag,
            blockBufferOut: &block)
        guard status == noErr, let block else { throw failure("a chapter's block", status) }
        status = bytes.withUnsafeBytes {
            CMBlockBufferReplaceDataBytes(with: $0.baseAddress!, blockBuffer: block, offsetIntoDestination: 0, dataLength: $0.count)
        }
        guard status == noErr else { throw failure("a chapter's bytes", status) }
        var timing = CMSampleTimingInfo(
            duration: CMTime(value: duration, timescale: timescale), presentationTimeStamp: CMTime(value: start, timescale: timescale),
            decodeTimeStamp: .invalid)
        var size = bytes.count
        var sample: CMSampleBuffer?
        status = CMSampleBufferCreateReady(
            allocator: kCFAllocatorDefault, dataBuffer: block, formatDescription: format, sampleCount: 1, sampleTimingEntryCount: 1,
            sampleTimingArray: &timing, sampleSizeEntryCount: 1, sampleSizeArray: &size, sampleBufferOut: &sample)
        guard status == noErr, let sample else { throw failure("a chapter's sample", status) }
        return sample
    }

    private static func failure(_ what: String, _ status: OSStatus) -> ExportError {
        .writerFailed("cannot make \(what) (OSStatus \(status))")
    }
}
