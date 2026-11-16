// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import ImageIO
import Testing

@testable import Export

struct SeededRandom: RandomNumberGenerator {
    var state: UInt64
    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}

private func encode(_ indices: [UInt8], colors: Int) -> (data: [UInt8], mcs: Int) {
    let mcs = LZWEncoder.minimumCodeSize(colors: colors)
    let data = indices.withUnsafeBufferPointer { LZWEncoder.encode($0, minimumCodeSize: mcs) }
    return (data, mcs)
}

private func tempFile() -> (fd: Int32, url: URL) {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("gif-\(UUID().uuidString).gif")
    let fd = open(url.path, O_WRONLY | O_CREAT | O_TRUNC, 0o644)
    return (fd, url)
}

private func gradientBlock(width: Int, height: Int, seed: Int, delay: Int) -> GIFImageBlock {
    let palette = (0..<16).map { SIMD3<UInt8>(UInt8($0 * 16), UInt8(255 - $0 * 16), UInt8(seed * 20 & 255)) }
    let indices = (0..<(width * height)).map { UInt8(($0 + seed) % 16) }
    let (data, mcs) = encode(indices, colors: 16)
    return GIFImageBlock(
        x: 0, y: 0, width: width, height: height, palette: palette, delay: delay, minimumCodeSize: mcs, data: data)
}

@Suite struct GIFWriterTests {
    @Test func lzwRoundTripsWithTheTestDecoder() {
        var rng = SeededRandom(state: 42)
        for n in 0..<200 {
            let colors = Int.random(in: 2...256, using: &rng)
            let count = n == 0 ? 0 : Int.random(in: 1...(n % 10 == 0 ? 2_000_000 : 20_000), using: &rng)
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
            let (data, mcs) = encode(indices, colors: colors)
            #expect(GIFTestDecoder.lzw(data, minimumCodeSize: mcs) == indices, "stream \(n)")
        }
    }

    @Test func lzwPassesTheTableLimitManyTimes() {
        var rng = SeededRandom(state: 7)
        let indices = (0..<3_000_000).map { _ in UInt8.random(in: 0...255, using: &rng) }
        let (data, mcs) = encode(indices, colors: 256)
        // Random 8-bit data fills the 4096 table roughly every 3 800 symbols.
        #expect(GIFTestDecoder.lzw(data, minimumCodeSize: mcs) == indices)
    }

    @Test func writtenGIFDecodesWithImageIO() throws {
        let (fd, url) = tempFile()
        defer { try? FileManager.default.removeItem(at: url) }
        var writer = try GIFWriter(fileDescriptor: fd, width: 64, height: 48, loops: true)
        let delays = GIFDelays.delays(frameCount: 10, fps: 15)
        for i in 0..<10 { try writer.write(gradientBlock(width: 64, height: 48, seed: i, delay: delays[i])) }
        try writer.finish()
        close(fd)
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
        let (fd, url) = tempFile()
        defer { try? FileManager.default.removeItem(at: url) }
        var writer = try GIFWriter(fileDescriptor: fd, width: 16, height: 16, loops: false)
        try writer.write(gradientBlock(width: 16, height: 16, seed: 0, delay: 5))
        try writer.finish()
        close(fd)
        let bytes = try Data(contentsOf: url)
        #expect(bytes.range(of: Data("NETSCAPE2.0".utf8)) == nil)
        #expect(bytes.prefix(6) == Data("GIF89a".utf8))
        #expect(bytes.last == 0x3B)
    }

    @Test func delaysAccumulateWithoutDrift() {
        #expect(GIFDelays.delays(frameCount: 6, fps: 15) == [7, 6, 7, 7, 6, 7])
        #expect(GIFDelays.delays(frameCount: 150, fps: 15).reduce(0, +) == 1000)
        for fps in [10, 20, 25, 30] {
            for n in [1, 2, 3, 17, 150, 1000, 9000] {
                let sum = GIFDelays.delays(frameCount: n, fps: fps).reduce(0, +)
                #expect(sum == Int((Double(n) * 100 / Double(fps)).rounded()), "\(n) frames at \(fps)")
            }
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
        let (fd, url) = tempFile()
        defer { try? FileManager.default.removeItem(at: url) }
        var writer = try GIFWriter(fileDescriptor: fd, width: 8, height: 8, loops: false)
        let payload = (0..<10_000).map { UInt8($0 & 0xFF) }
        try writer.write(
            GIFImageBlock(
                x: 0, y: 0, width: 8, height: 8, palette: [SIMD3(0, 0, 0), SIMD3(255, 255, 255)], delay: 1,
                minimumCodeSize: 2, data: payload))
        try writer.finish()
        close(fd)
        let bytes = [UInt8](try Data(contentsOf: url))
        // header 13, GCE 8, descriptor 10, table 6 (2 colors) → 4 entries? padded to 2 = 6 bytes, mcs 1 byte.
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
}
