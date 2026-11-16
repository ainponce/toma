// SPDX-License-Identifier: GPL-3.0-or-later
@testable import Export
import Foundation
import ImageIO
import Testing

/// SplitMix64: the same numbers on every run.
private struct SplitMix64: RandomNumberGenerator {
    var state: UInt64
    init(seed: UInt64) { state = seed }
    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}

private struct TempFileError: Error {}

/// `image` (colours row by row) mapped to `palette`, which holds every colour of it.
private func quantized(
    _ image: [SIMD3<UInt8>], width: Int, height: Int, palette: [SIMD3<UInt8>], delay: Int = 7
) -> QuantizedFrame {
    var index: [SIMD3<UInt8>: UInt8] = [:]
    for (i, color) in palette.enumerated() where index[color] == nil { index[color] = UInt8(i) }
    return QuantizedFrame(
        width: width, height: height, indices: image.map { index[$0]! },
        palette: GIFPalette(colors: palette, exactCount: 0), delay: delay)
}

/// The colours a quantized frame shows, row by row.
private func colors(of frame: QuantizedFrame) -> [SIMD3<UInt8>] { frame.indices.map { frame.palette.colors[Int($0)] } }

/// Every frame through one composer, then its `finish`.
private func compose(_ frames: [QuantizedFrame], width: Int, height: Int) -> [ComposedFrame] {
    var composer = GIFComposer(width: width, height: height)
    var out = frames.compactMap { composer.add($0) }
    if let last = composer.finish() { out.append(last) }
    return out
}

/// The composed frames written as Task 22 writes them: LZW with the code size of the palette plus the transparent
/// index, through `GIFWriter`.
private func gifData(_ frames: [ComposedFrame], width: Int, height: Int) throws -> Data {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("composer-\(UUID().uuidString).gif")
    let fd = open(url.path, O_WRONLY | O_CREAT | O_TRUNC, 0o644)
    guard fd >= 0 else { throw TempFileError() }
    defer {
        close(fd)
        try? FileManager.default.removeItem(at: url)
    }
    var writer = try GIFWriter(fileDescriptor: fd, width: width, height: height, loops: true)
    for frame in frames {
        let mcs = LZWEncoder.minimumCodeSize(colors: frame.palette.count + 1)
        let data = try frame.indices.withUnsafeBufferPointer { try LZWEncoder.encode($0, minimumCodeSize: mcs) }
        try writer.write(
            GIFImageBlock(
                x: frame.x, y: frame.y, width: frame.width, height: frame.height, palette: frame.palette,
                transparentIndex: frame.transparentIndex, delay: frame.delay, minimumCodeSize: mcs, data: data))
    }
    try writer.finish()
    return try Data(contentsOf: url)
}

@Suite struct GIFComposerTests {
    /// Three colours in diagonal stripes, 8 × 6.
    private static let stripes: [SIMD3<UInt8>] = (0..<48).map { i in
        [SIMD3<UInt8>(250, 10, 10), SIMD3(10, 250, 10), SIMD3(10, 10, 250)][(i % 8 + i / 8) % 3]
    }

    @Test func firstFrameHasNoTransparency() throws {
        let palette: [SIMD3<UInt8>] = [SIMD3(10, 10, 250), SIMD3(250, 10, 10), SIMD3(10, 250, 10)]
        let first = quantized(Self.stripes, width: 8, height: 6, palette: palette, delay: 7)
        var changed = Self.stripes
        changed[20] = SIMD3(0, 0, 0)
        var composer = GIFComposer(width: 8, height: 6)
        #expect(composer.add(first) == nil)
        let returned = composer.add(quantized(changed, width: 8, height: 6, palette: palette + [.zero]))
        let composed = try #require(returned)
        #expect(composed.x == 0 && composed.y == 0 && composed.width == 8 && composed.height == 6)
        #expect(composed.transparentIndex == nil)
        #expect(composed.indices == first.indices)
        #expect(composed.palette == palette)
        #expect(composed.delay == 7)
        #expect(composer.finish()?.transparentIndex == 4)
    }

    @Test func unchangedPixelsBecomeTransparent() throws {
        let width = 16, height = 12
        let base: [SIMD3<UInt8>] = (0..<6).map { SIMD3(UInt8(40 * $0), UInt8(200 - 30 * $0), 77) }
        let a: [SIMD3<UInt8>] = (0..<(width * height)).map { base[($0 % width + 2 * ($0 / width)) % 6] }
        // The border of the 3 × 4 square at (5, 6) turns white; its two pixels inside stay as they were.
        let white = SIMD3<UInt8>(255, 255, 255)
        var b = a
        for y in 6..<10 {
            for x in 5..<8 where x == 5 || x == 7 || y == 6 || y == 9 { b[y * width + x] = white }
        }
        // The second palette has white first and the old colours in reverse, so equal colours have other indices.
        let paletteB = [white] + base.reversed()
        let frameA = quantized(a, width: width, height: height, palette: base)
        let frameB = quantized(b, width: width, height: height, palette: paletteB, delay: 6)
        let composed = compose([frameA, frameB], width: width, height: height)
        try #require(composed.count == 2)
        let second = composed[1]
        #expect(second.x == 5 && second.y == 6 && second.width == 3 && second.height == 4)
        #expect(second.palette == paletteB)
        #expect(second.transparentIndex == 7)
        #expect(second.transparentIndex == frameB.palette.transparentIndex)
        #expect(second.delay == 6)
        var expected = [UInt8](repeating: 0, count: 12)
        for y in 0..<4 {
            for x in 0..<3 where x == 1 && (y == 1 || y == 2) { expected[y * 3 + x] = 7 }
        }
        #expect(second.indices == expected)
    }

    @Test func identicalFramesMerge() throws {
        let palette: [SIMD3<UInt8>] = [SIMD3(250, 10, 10), SIMD3(10, 250, 10), SIMD3(10, 10, 250)]
        let a = quantized(Self.stripes, width: 8, height: 6, palette: palette, delay: 7)
        // The same picture with its palette in another order is the same frame.
        let aAgain = quantized(Self.stripes, width: 8, height: 6, palette: palette.reversed(), delay: 6)
        let a3 = quantized(Self.stripes, width: 8, height: 6, palette: palette, delay: 7)
        var changed = Self.stripes
        changed[47] = SIMD3(1, 2, 3)
        let b = quantized(changed, width: 8, height: 6, palette: palette + [SIMD3(1, 2, 3)], delay: 7)
        var composer = GIFComposer(width: 8, height: 6)
        #expect(composer.add(a) == nil)
        #expect(composer.add(aAgain) == nil)
        #expect(composer.add(a3) == nil)
        let afterB = composer.add(b)
        let first = try #require(afterB)
        #expect(first.delay == 20)
        #expect(first.indices == a.indices)
        let last = composer.finish()
        let second = try #require(last)
        #expect(second.delay == 7)
        #expect(second.x == 7 && second.y == 5 && second.width == 1 && second.height == 1)
        #expect(second.indices == [3])
    }

    @Test func allIdenticalFramesBecomeOneFrameWithTheWholeDelay() throws {
        let palette: [SIMD3<UInt8>] = [SIMD3(250, 10, 10), SIMD3(10, 250, 10), SIMD3(10, 10, 250)]
        let delays = GIFDelays.delays(frameCount: 150, fps: 15)
        var composer = GIFComposer(width: 8, height: 6)
        for delay in delays {
            #expect(composer.add(quantized(Self.stripes, width: 8, height: 6, palette: palette, delay: delay)) == nil)
        }
        let last = composer.finish()
        let only = try #require(last)
        #expect(only.delay == 1_000)
        #expect(only.x == 0 && only.y == 0 && only.width == 8 && only.height == 6)
        #expect(only.transparentIndex == nil)
        let shown = GIFTestDecoder.frames(try gifData([only], width: 8, height: 6))
        try #require(shown.count == 1)
        #expect(shown[0].delay == 1_000)
        #expect(shown[0].canvas == Self.stripes)
    }

    /// More unchanged time than a graphic control holds (65 535 hundredths): a one-pixel transparent frame carries the
    /// rest, so the delays still add up to the duration.
    @Test func mergedDelayStaysWithinTheGIFLimit() throws {
        let palette: [SIMD3<UInt8>] = [SIMD3(250, 10, 10), SIMD3(10, 250, 10), SIMD3(10, 10, 250)]
        let frame = quantized(Self.stripes, width: 8, height: 6, palette: palette, delay: 10)
        let composed = compose([QuantizedFrame](repeating: frame, count: 7_000), width: 8, height: 6)
        try #require(composed.count == 2)
        #expect(composed[0].delay == 65_530)
        #expect(composed[0].delay <= GIFComposer.maxDelay)
        #expect(composed[1].delay == 4_470)
        #expect(composed[1].width == 1 && composed[1].height == 1)
        let transparent = try #require(composed[1].transparentIndex)
        #expect(composed[1].indices == [UInt8(transparent)])
        let shown = GIFTestDecoder.frames(try gifData(composed, width: 8, height: 6))
        #expect(shown.map(\.delay) == [65_530, 4_470])
        #expect(shown.allSatisfy { $0.canvas == Self.stripes })
    }

    @Test func composedFramesEqualTheQuantizedOnes() throws {
        let width = 37, height = 23
        var random = SplitMix64(seed: 2_111)
        var pool: [SIMD3<UInt8>] = []
        while pool.count < 255 {
            let color = SIMD3(
                UInt8.random(in: 0...255, using: &random), UInt8.random(in: 0...255, using: &random),
                UInt8.random(in: 0...255, using: &random))
            if !pool.contains(color) { pool.append(color) }
        }
        let delays = GIFDelays.delays(frameCount: 60, fps: 15)
        var image = [SIMD3<UInt8>](repeating: pool[0], count: width * height)
        var frames: [QuantizedFrame] = []
        for n in 0..<60 {
            switch n == 0 ? 0 : Int.random(in: 0..<6, using: &random) {
            case 0:  // noise over the whole frame
                for i in image.indices { image[i] = pool[Int.random(in: 0..<pool.count, using: &random)] }
            case 1:  // the same picture
                break
            default:  // one to three rectangles of one colour each, some against the edges
                for _ in 0..<Int.random(in: 1...3, using: &random) {
                    let x0 = Int.random(in: 0..<width, using: &random), y0 = Int.random(in: 0..<height, using: &random)
                    let x1 = Int.random(in: x0..<width, using: &random), y1 = Int.random(in: y0..<height, using: &random)
                    let color = pool[Int.random(in: 0..<pool.count, using: &random)]
                    for y in y0...y1 { for x in x0...x1 { image[y * width + x] = color } }
                }
            }
            // Every frame its own palette: the colours it uses and some it does not, in a new order, up to 255.
            var used: [SIMD3<UInt8>] = []
            var seen = Set<SIMD3<UInt8>>()
            for color in image where seen.insert(color).inserted { used.append(color) }
            let unused = pool.filter { !seen.contains($0) }.shuffled(using: &random)
            let palette = (used + unused.prefix(Int.random(in: 0...unused.count, using: &random))).shuffled(using: &random)
            frames.append(quantized(image, width: width, height: height, palette: palette, delay: delays[n]))
        }

        let composed = compose(frames, width: width, height: height)
        #expect(composed.count < frames.count, "some frames repeat and merge")
        #expect(composed.dropFirst().contains { $0.width < width || $0.height < height }, "some frames are cropped")
        #expect(composed.dropFirst().allSatisfy { $0.transparentIndex == $0.palette.count })
        let data = try gifData(composed, width: width, height: height)
        let source = try #require(CGImageSourceCreateWithData(data as CFData, nil))
        #expect(CGImageSourceGetCount(source) == composed.count)

        // Each canvas is shown for the frames whose delays add up to its own.
        let shown = GIFTestDecoder.frames(data)
        #expect(shown.count == composed.count)
        var next = 0
        var wrong: [Int] = []
        for canvas in shown {
            var delay = 0
            while delay < canvas.delay && next < frames.count {
                if canvas.canvas != colors(of: frames[next]) { wrong.append(next) }
                delay += frames[next].delay
                next += 1
            }
            #expect(delay == canvas.delay)
        }
        #expect(next == frames.count)
        #expect(wrong.isEmpty, "frames shown wrong: \(wrong)")
    }

    @Test func aFrameWithFewColorsIsLossless() throws {
        let width = 40, height = 30
        var random = SplitMix64(seed: 21)
        // 200 colours, each alone in its bucket of 5 bits per channel, with random low bits.
        let buckets = Array((0..<ColorHistogram.bucketCount).shuffled(using: &random).prefix(200))
        let palette: [SIMD3<UInt8>] = buckets.map { bucket in
            SIMD3(
                UInt8(bucket >> 10 & 31) << 3 | UInt8.random(in: 0...7, using: &random),
                UInt8(bucket >> 5 & 31) << 3 | UInt8.random(in: 0...7, using: &random),
                UInt8(bucket & 31) << 3 | UInt8.random(in: 0...7, using: &random))
        }
        let image = (0..<(width * height)).map { palette[$0 % 200] }.shuffled(using: &random)
        var bgra: [UInt8] = []
        for pixel in image { bgra += [pixel.z, pixel.y, pixel.x, 255] }
        let histogram = bgra.withUnsafeBytes { ColorHistogram(bgra: $0, width: width, height: height, bytesPerRow: width * 4) }

        let built = PaletteBuilder.build(histogram, quality: .balanced)
        #expect(built.colors.count == 200)
        #expect(built.exactCount == 200)
        #expect(Set(built.colors) == Set(palette))
        let frame = quantized(image, width: width, height: height, palette: built.colors)
        let composed = compose([frame], width: width, height: height)
        try #require(composed.count == 1)
        let shown = GIFTestDecoder.frames(try gifData(composed, width: width, height: height))
        try #require(shown.count == 1)
        #expect(shown[0].canvas == image)
    }
}
