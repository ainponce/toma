// SPDX-License-Identifier: GPL-3.0-or-later
import CoreGraphics
import CoreMedia
import Foundation
import ImageIO
import ProjectFormat
import RecorderKitTestSupport
@testable import Sharing
import Testing

// `poster.jpg` (plan 5a decision 10): exactly the frame of the exported video, a JPEG of its size.

/// The frame the JPEG at `url` shows, modulo 19, and its size: `SampleFactory` paints a white 16 px square along the
/// top row of each frame, at x = 16 · (i mod 19) in a frame 320 px wide, so where it is tells a frame from the ones next
/// to it whatever the colours went through (H.264 and the colour spaces move the background's palette colour by more
/// than half a step on some frames; white stays white). `nil` if no square is found.
private func frame(ofJPEG url: URL) throws -> (frameMod19: Int?, width: Int, height: Int) {
    let source = try #require(CGImageSourceCreateWithURL(url as CFURL, nil))
    let image = try #require(CGImageSourceCreateImageAtIndex(source, 0, nil))
    let width = image.width, height = image.height
    var bytes = [UInt8](repeating: 0, count: width * height * 4)
    let drawn = bytes.withUnsafeMutableBytes { buffer -> Bool in
        guard let context = CGContext(
            data: buffer.baseAddress, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return false }
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        return true
    }
    try #require(drawn)
    // The middle of each place the square can be at, in the first row of the bitmap, the top of the picture.
    let white = (0..<19).filter { p in
        let i = (8 * width + 16 * p + 8) * 4
        return bytes[i] > 235 && bytes[i + 1] > 235 && bytes[i + 2] > 235
    }
    return (white.count == 1 ? white[0] : nil, width, height)
}

@Suite struct SharePosterTests {
    @Test func posterIsTheExactFrame() async throws {
        try await withTemporaryDirectory { dir in
            let clip = try MediaFixtures.clip(in: dir, seconds: 3, size: [320, 180], pattern: 0)
            let poster = dir.appending(path: "poster.jpg")
            let size = try await SharePoster.write(from: clip, atOutput: 1_000_000_000, to: poster)
            #expect(size == [320, 180])
            let data = try Data(contentsOf: poster)
            #expect(data.prefix(2) == Data([0xFF, 0xD8]))
            let read = try frame(ofJPEG: poster)
            #expect(read.frameMod19 == 30 % 19 && read.width == 320 && read.height == 180)
            // Each frame at its start, those the grid in ns rounds down (1, 22) and up (2, 29) alike, and a nanosecond
            // before one is the frame before it.
            for n in [1, 2, 22, 29] {
                _ = try await SharePoster.write(from: clip, atOutput: TimeMap.frameTime(n, frameRate: 30), to: poster)
                #expect(try frame(ofJPEG: poster).frameMod19 == n % 19, "frame \(n)")
            }
            _ = try await SharePoster.write(from: clip, atOutput: TimeMap.frameTime(2, frameRate: 30) - 1, to: poster)
            #expect(try frame(ofJPEG: poster).frameMod19 == 1)
        }
    }

    @Test func posterPastTheEndIsTheLastFrame() async throws {
        try await withTemporaryDirectory { dir in
            let clip = try MediaFixtures.clip(in: dir, seconds: 3, size: [320, 180], pattern: 0)
            let poster = dir.appending(path: "poster.jpg")
            for time: Int64 in [5_000_000_000, 3_000_000_000, TimeMap.frameTime(89, frameRate: 30)] {
                _ = try await SharePoster.write(from: clip, atOutput: time, to: poster)
                // Frame 89, the last of 90.
                #expect(try frame(ofJPEG: poster).frameMod19 == 89 % 19, "at \(time) ns")
            }
            _ = try await SharePoster.write(from: clip, atOutput: TimeMap.frameTime(89, frameRate: 30) - 1, to: poster)
            #expect(try frame(ofJPEG: poster).frameMod19 == 88 % 19)
            _ = try await SharePoster.write(from: clip, atOutput: -5, to: poster)
            #expect(try frame(ofJPEG: poster).frameMod19 == 0)
        }
    }

    @Test func theFrameIsAskedForInItsMiddle() {
        // An export's frames are at n / fps exactly (timescale fps), a grid in ns rounds their starts: either way the
        // middle of frame n is inside it.
        let range = CMTimeRange(start: .zero, duration: CMTime(value: 90, timescale: 30))
        for n in [0, 1, 2, 29, 89] {
            let asked = SharePoster.requestTime(TimeMap.frameTime(n, frameRate: 30), range: range, nominalFrameRate: 30)
            #expect(asked == CMTime(value: CMTimeValue(2 * n + 1), timescale: 60), "frame \(n)")
        }
        #expect(SharePoster.requestTime(9_000_000_000, range: range, nominalFrameRate: 30) == CMTime(value: 179, timescale: 60))
        // A track that does not start at 0 is asked from its start.
        let later = CMTimeRange(start: CMTime(value: 1, timescale: 1), duration: CMTime(value: 2, timescale: 1))
        #expect(SharePoster.requestTime(0, range: later, nominalFrameRate: 25) == CMTimeAdd(later.start, CMTime(value: 1, timescale: 50)))
    }

    @Test func aFileWithoutVideoHasNoPoster() async throws {
        try await withTemporaryDirectory { dir in
            let file = dir.appending(path: "not-a-video.mp4")
            try Data("not a video".utf8).write(to: file)
            await #expect(throws: (any Error).self) {
                _ = try await SharePoster.write(from: file, atOutput: 0, to: dir.appending(path: "poster.jpg"))
            }
            #expect(!FileManager.default.fileExists(atPath: dir.appending(path: "poster.jpg").path))
        }
    }
}



