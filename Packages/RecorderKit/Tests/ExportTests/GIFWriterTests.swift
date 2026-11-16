// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import ImageIO
import Testing

@testable import Export

private struct SeededRandom: RandomNumberGenerator {
    var state: UInt64
    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}

private func encode(_ indices: [UInt8], colors: Int) throws -> (data: [UInt8], mcs: Int) {
    let mcs = LZWEncoder.minimumCodeSize(colors: colors)
    let data = try indices.withUnsafeBufferPointer { try LZWEncoder.encode($0, minimumCodeSize: mcs) }
    return (data, mcs)
}

private struct TempFileError: Error {}

private func tempFile() throws -> (fd: Int32, url: URL) {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("gif-\(UUID().uuidString).gif")
    let fd = open(url.path, O_WRONLY | O_CREAT | O_TRUNC, 0o644)
    guard fd >= 0 else { throw TempFileError() }
    return (fd, url)
}

private func gradientBlock(width: Int, height: Int, seed: Int, delay: Int) throws -> GIFImageBlock {
    let palette = (0..<16).map { SIMD3<UInt8>(UInt8($0 * 16), UInt8(255 - $0 * 16), UInt8(seed * 20 & 255)) }
    let indices = (0..<(width * height)).map { UInt8(($0 + seed) % 16) }
    let (data, mcs) = try encode(indices, colors: 16)
    return GIFImageBlock(
        x: 0, y: 0, width: width, height: height, palette: palette, delay: delay, minimumCodeSize: mcs, data: data)
}

@Suite struct GIFWriterTests {
    @Test func lzwRoundTripsWithTheTestDecoder() throws {
        var rng = SeededRandom(state: 42)
        for n in 0..<202 {
            let colors = Int.random(in: 2...256, using: &rng)
            let count = n >= 200 ? 2_000_000 : n == 0 ? 0 : Int.random(in: 1...20_000, using: &rng)
            let mode = n % 4
            var indices = [UInt8](repeating: 0, count: count)
            for i in 0..<count {
                switch mode {
                case 0: indices[i] = UInt8(Int.random(in: 0..<colors, using: &rng))
                case 1: indices[i] = UInt8((i / 7) % colors)
                case 2: indices[i] = Int.random(in: 0..<20, using: &rng) == 0 ? UInt8(Int.random(in: 0..<colors, using: &rng)) : 0
                default: indices[i] = UInt8(i % colors)
                }
            }
            let (data, mcs) = try encode(indices, colors: colors)
            #expect(GIFTestDecoder.lzw(data, minimumCodeSize: mcs) == indices, "stream \(n)")
        }
    }

    @Test func lzwPassesTheTableLimitManyTimes() throws {
        var rng = SeededRandom(state: 7)
        let indices = (0..<1_000_000).map { _ in UInt8.random(in: 0...255, using: &rng) }
        let (data, mcs) = try encode(indices, colors: 256)
        // Random 8-bit data fills the 4096 table roughly every 3 800 symbols.
        #expect(GIFTestDecoder.lzw(data, minimumCodeSize: mcs) == indices)
    }

    @Test func writtenGIFDecodesWithImageIO() throws {
        let (fd, url) = try tempFile()
        defer {
            close(fd)
            try? FileManager.default.removeItem(at: url)
        }
        var writer = try GIFWriter(fileDescriptor: fd, width: 64, height: 48, loops: true)
        let delays = GIFDelays.delays(frameCount: 10, fps: 15)
        for i in 0..<10 { try writer.write(try gradientBlock(width: 64, height: 48, seed: i, delay: delays[i])) }
        try writer.finish()
        let source = try #require(CGImageSourceCreateWithURL(url as CFURL, nil))
        #expect(CGImageSourceGetCount(source) == 10)
        for i in 0..<10 {
            let props = try #require(CGImageSourceCopyPropertiesAtIndex(source, i, nil) as? [CFString: Any])
            let gif = try #require(props[kCGImagePropertyGIFDictionary] as? [CFString: Any])
            let delay = try #require(gif[kCGImagePropertyGIFUnclampedDelayTime] as? Double)
            #expect(abs(delay - Double(delays[i]) / 100) < 1e-6)
            #expect(props[kCGImagePropertyPixelWidth] as? Int == 64)
            #expect(props[kCGImagePropertyPixelHeight] as? Int == 48)
        }
        let top = try #require(CGImageSourceCopyProperties(source, nil) as? [CFString: Any])
        let topGIF = try #require(top[kCGImagePropertyGIFDictionary] as? [CFString: Any])
        #expect(topGIF[kCGImagePropertyGIFLoopCount] as? Int == 0)
    }

    @Test func withoutLoopsThereIsNoNetscapeExtension() throws {
        let (fd, url) = try tempFile()
        defer {
            close(fd)
            try? FileManager.default.removeItem(at: url)
        }
        var writer = try GIFWriter(fileDescriptor: fd, width: 16, height: 16, loops: false)
        try writer.write(try gradientBlock(width: 16, height: 16, seed: 0, delay: 5))
        try writer.finish()
        let bytes = try Data(contentsOf: url)
        #expect(bytes.range(of: Data("NETSCAPE2.0".utf8)) == nil)
        #expect(bytes.prefix(6) == Data("GIF89a".utf8))
        #expect(bytes.last == 0x3B)
    }

    @Test func delaysAccumulateWithoutDrift() {
        #expect(GIFDelays.delays(frameCount: 6, fps: 15) == [7, 6, 7, 7, 6, 7])
        #expect(GIFDelays.delays(frameCount: 150, fps: 15).reduce(0, +) == 1000)
        for fps in [10, 20, 25, 30] {
            let delays = GIFDelays.delays(frameCount: 9000, fps: fps)
            var sum = 0
            var wrong = [Int]()
            for n in 1...9000 {
                sum += delays[n - 1]
                if sum != (n * 100 + fps / 2) / fps { wrong.append(n) }
            }
            #expect(wrong.isEmpty, "prefix sums wrong at \(wrong.prefix(5)) for \(fps) fps")
        }
    }

    @Test func minimumCodeSizeRule() {
        #expect(LZWEncoder.minimumCodeSize(colors: 1) == 2)
        #expect(LZWEncoder.minimumCodeSize(colors: 2) == 2)
        #expect(LZWEncoder.minimumCodeSize(colors: 4) == 2)
        #expect(LZWEncoder.minimumCodeSize(colors: 5) == 3)
        #expect(LZWEncoder.minimumCodeSize(colors: 256) == 8)
    }

    @Test func subBlocksAre255Bytes() throws {
        let (fd, url) = try tempFile()
        defer {
            close(fd)
            try? FileManager.default.removeItem(at: url)
        }
        var writer = try GIFWriter(fileDescriptor: fd, width: 8, height: 8, loops: false)
        let payload = (0..<10_000).map { UInt8($0 & 0xFF) }
        try writer.write(
            GIFImageBlock(
                x: 0, y: 0, width: 8, height: 8, palette: [SIMD3(0, 0, 0), SIMD3(255, 255, 255)], delay: 1,
                minimumCodeSize: 2, data: payload))
        try writer.finish()
        let bytes = [UInt8](try Data(contentsOf: url))
        // header 13 (no NETSCAPE), graphic control 8, descriptor 10, local table 2 entries = 6, min code size 1.
        var p = 13 + 8 + 10 + 6 + 1
        var sizes = [Int]()
        var rebuilt = [UInt8]()
        while bytes[p] != 0 {
            let n = Int(bytes[p])
            sizes.append(n)
            rebuilt += bytes[(p + 1)..<(p + 1 + n)]
            p += 1 + n
        }
        #expect(sizes == Array(repeating: 255, count: 39) + [10_000 - 39 * 255])
        #expect(rebuilt == payload)
        #expect(bytes[p + 1] == 0x3B)
    }

    @Test func largeFrameSurvivesImageIOPixelForPixel() throws {
        // 300x300 noisy indices over 64 colors: crosses the 4 096-entry limit several times.
        var rng = SeededRandom(state: 99)
        let w = 300, h = 300
        let palette: [SIMD3<UInt8>] = (0..<64).map { (i: Int) -> SIMD3<UInt8> in
            SIMD3<UInt8>(UInt8(i * 4), UInt8(255 - i * 4), UInt8((i * 37) & 255))
        }
        let indices = (0..<(w * h)).map { _ in UInt8.random(in: 0..<64, using: &rng) }
        let (data, mcs) = try encode(indices, colors: 64)
        let (fd, url) = try tempFile()
        defer {
            close(fd)
            try? FileManager.default.removeItem(at: url)
        }
        var writer = try GIFWriter(fileDescriptor: fd, width: w, height: h, loops: false)
        try writer.write(
            GIFImageBlock(x: 0, y: 0, width: w, height: h, palette: palette, delay: 4, minimumCodeSize: mcs, data: data))
        try writer.finish()
        let source = try #require(CGImageSourceCreateWithURL(url as CFURL, nil))
        let image = try #require(CGImageSourceCreateImageAtIndex(source, 0, nil))
        var rgba = [UInt8](repeating: 0, count: w * h * 4)
        let ctx = try #require(
            CGContext(
                data: &rgba, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        var mismatches = 0
        for i in 0..<(w * h) {
            let c = palette[Int(indices[i])]
            if rgba[i * 4] != c.x || rgba[i * 4 + 1] != c.y || rgba[i * 4 + 2] != c.z { mismatches += 1 }
        }
        #expect(mismatches == 0)
    }

    @Test func encoderRejectsIndicesOutsideTheCodeSize() {
        let bad: [UInt8] = [0, 1, 2, 4, 1]
        #expect(throws: LZWError.indexOutOfRange(4)) {
            try bad.withUnsafeBufferPointer { try LZWEncoder.encode($0, minimumCodeSize: 2) }
        }
        #expect(throws: LZWError.invalidMinimumCodeSize) {
            try bad.withUnsafeBufferPointer { try LZWEncoder.encode($0, minimumCodeSize: 9) }
        }
        #expect(throws: Never.self) {
            try [0, 1, 2, 3].withUnsafeBufferPointer { try LZWEncoder.encode($0, minimumCodeSize: 2) }
        }
    }

    @Test func writerRejectsInvalidBlocks() throws {
        let (fd, url) = try tempFile()
        defer {
            close(fd)
            try? FileManager.default.removeItem(at: url)
        }
        var writer = try GIFWriter(fileDescriptor: fd, width: 8, height: 8, loops: false)
        let five = (0..<5).map { SIMD3<UInt8>(UInt8($0), 0, 0) }
        func block(
            palette: [SIMD3<UInt8>], mcs: Int = 3, transparent: Int? = nil, x: Int = 0, delay: Int = 1
        ) -> GIFImageBlock {
            GIFImageBlock(
                x: x, y: 0, width: 8, height: 8, palette: palette, transparentIndex: transparent, delay: delay,
                minimumCodeSize: mcs, data: [0])
        }
        #expect(throws: GIFWriterError.minimumCodeSizeTooSmallForPalette) { try writer.write(block(palette: five, mcs: 2)) }
        #expect(throws: GIFWriterError.transparentIndexOutsidePalette) { try writer.write(block(palette: five, transparent: 6)) }
        // transparent == palette.count is valid but needs the code size to cover it: 4 colors + transparent at mcs 2.
        let four = Array(five.prefix(4))
        #expect(throws: GIFWriterError.minimumCodeSizeTooSmallForPalette) {
            try writer.write(block(palette: four, mcs: 2, transparent: 4))
        }
        #expect(throws: Never.self) { try writer.write(block(palette: four, mcs: 3, transparent: 4)) }
        #expect(throws: GIFWriterError.transparentIndexOutsidePalette) { try writer.write(block(palette: five, transparent: -1)) }
        #expect(throws: GIFWriterError.blockOutsideScreen) { try writer.write(block(palette: five, x: 1)) }
        #expect(throws: GIFWriterError.invalidPaletteSize) { try writer.write(block(palette: [])) }
        #expect(throws: GIFWriterError.invalidMinimumCodeSize) { try writer.write(block(palette: five, mcs: 9)) }
        #expect(throws: GIFWriterError.invalidDelay) { try writer.write(block(palette: five, delay: 70_000)) }
        #expect(throws: Never.self) { try writer.write(block(palette: five)) }
        try writer.finish()
        #expect(throws: GIFWriterError.finished) { try writer.finish() }
    }

    @Test func transparentIndexPastAFourColorPaletteDecodes() throws {
        let w = 40, h = 30
        let palette: [SIMD3<UInt8>] = [SIMD3(255, 0, 0), SIMD3(0, 255, 0), SIMD3(0, 0, 255), SIMD3(255, 255, 0)]
        // 4 colors + transparent index 4: code size comes from colors + 1 = 5 → 3 (4 would collide with clear).
        let mcs = LZWEncoder.minimumCodeSize(colors: palette.count + 1)
        #expect(mcs == 3)
        let indices = (0..<(w * h)).map { UInt8($0 % 5) }
        let data = try indices.withUnsafeBufferPointer { try LZWEncoder.encode($0, minimumCodeSize: mcs) }
        let (fd, url) = try tempFile()
        defer {
            close(fd)
            try? FileManager.default.removeItem(at: url)
        }
        var writer = try GIFWriter(fileDescriptor: fd, width: w, height: h, loops: false)
        try writer.write(
            GIFImageBlock(
                x: 0, y: 0, width: w, height: h, palette: palette, transparentIndex: 4, delay: 3, minimumCodeSize: mcs,
                data: data))
        try writer.finish()
        let source = try #require(CGImageSourceCreateWithURL(url as CFURL, nil))
        let image = try #require(CGImageSourceCreateImageAtIndex(source, 0, nil))
        var rgba = [UInt8](repeating: 0, count: w * h * 4)
        let ctx = try #require(
            CGContext(
                data: &rgba, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        var mismatches = 0
        for i in 0..<(w * h) {
            let index = Int(indices[i])
            if index == 4 {
                if rgba[i * 4 + 3] != 0 { mismatches += 1 }
            } else {
                let c = palette[index]
                if rgba[i * 4] != c.x || rgba[i * 4 + 1] != c.y || rgba[i * 4 + 2] != c.z || rgba[i * 4 + 3] != 255 {
                    mismatches += 1
                }
            }
        }
        #expect(mismatches == 0)
    }
}
