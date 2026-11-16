// SPDX-License-Identifier: GPL-3.0-or-later
@testable import Export
import Foundation
import Metal
import RecorderKitTestSupport
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

/// An RGB frame, row by row, without padding.
private struct Frame {
    var width: Int
    var height: Int
    var pixels: [SIMD3<UInt8>]

    init(width: Int, height: Int, pixel: (Int, Int) -> SIMD3<UInt8>) {
        self.width = width
        self.height = height
        pixels = (0..<height).flatMap { y in (0..<width).map { x in pixel(x, y) } }
    }

    subscript(x: Int, y: Int) -> SIMD3<UInt8> {
        get { pixels[y * width + x] }
        set { pixels[y * width + x] = newValue }
    }

    /// BGRA, 4 bytes a pixel, alpha 255: the render's `.bgra8Unorm`.
    var bgra: [UInt8] { pixels.flatMap { [$0.z, $0.y, $0.x, 255] } }

    var histogram: ColorHistogram {
        bgra.withUnsafeBytes { ColorHistogram(bgra: $0, width: width, height: height, bytesPerRow: width * 4) }
    }
}

private func randomColor(using random: inout SplitMix64) -> SIMD3<UInt8> {
    SIMD3(UInt8.random(in: 0...255, using: &random), UInt8.random(in: 0...255, using: &random), UInt8.random(in: 0...255, using: &random))
}

/// Noise everywhere.
private func noise(width: Int, height: Int, seed: UInt64) -> Frame {
    var random = SplitMix64(seed: seed)
    return Frame(width: width, height: height) { _, _ in randomColor(using: &random) }
}

/// What a screen looks like: flat rectangles of a few colours (window backgrounds, text, bars) over a gradient, with a
/// band of noise (a photo). Runs of one colour cross the boundaries of the histogram's runs of pixels.
private func screenLike(width: Int, height: Int, seed: UInt64) -> Frame {
    var random = SplitMix64(seed: seed)
    let flats: [SIMD3<UInt8>] = [SIMD3(250, 250, 250), SIMD3(30, 30, 34), SIMD3(0, 122, 255), SIMD3(236, 236, 236), SIMD3(255, 59, 48)]
    let rectangles: [(x: Range<Int>, y: Range<Int>, color: Int)] = (0..<12).map { i in
        let x = Int.random(in: 0..<(width * 3 / 4), using: &random), y = Int.random(in: 0..<(height * 3 / 4), using: &random)
        let w = Int.random(in: 3...(width / 3), using: &random), h = Int.random(in: 1...(height / 3), using: &random)
        return (x..<min(width, x + w), y..<min(height, y + h), i % flats.count)
    }
    return Frame(width: width, height: height) { x, y in
        if let rectangle = rectangles.last(where: { $0.x.contains(x) && $0.y.contains(y) }) { return flats[rectangle.color] }
        if y % 7 == 3 { return randomColor(using: &random) }
        return SIMD3(UInt8(x * 255 / max(1, width - 1)), UInt8(y * 255 / max(1, height - 1)), UInt8((x + y) % 256))
    }
}

/// The nearest palette colour in OKLab of each colour, computed on the CPU, the lower index on ties, with its distance.
private func nearest(_ colors: [SIMD3<UInt8>], in palette: GIFPalette) -> [(index: Int, distance: Float)] {
    let labs = palette.colors.map { OKLab.fromSRGB(SIMD3<Float>($0) / 255) }
    let pl = labs.map(\.x), pa = labs.map(\.y), pb = labs.map(\.z)
    return pl.withUnsafeBufferPointer { pl in
        pa.withUnsafeBufferPointer { pa in
            pb.withUnsafeBufferPointer { pb in
                colors.map { color in
                    let lab = OKLab.fromSRGB(SIMD3<Float>(color) / 255)
                    let l = lab.x, a = lab.y, b = lab.z
                    var best = 0
                    var bestSquare = Float.infinity
                    for c in 0..<pl.count {
                        let dl = l - pl[c], da = a - pa[c], db = b - pb[c]
                        let square = dl * dl + da * da + db * db
                        if square < bestSquare {
                            bestSquare = square
                            best = c
                        }
                    }
                    return (best, bestSquare.squareRoot())
                }
            }
        }
    }
}

@Suite(.enabled(if: MetalCondition.isAvailable || MetalCondition.isRequired)) struct GIFQuantizerTests {
    let device: any MTLDevice
    let queue: any MTLCommandQueue
    let quantizer: GIFQuantizer

    init() throws {
        device = try #require(MTLCreateSystemDefaultDevice())
        queue = try #require(device.makeCommandQueue())
        quantizer = try GIFQuantizer(device: device)
    }

    /// `frame` as the render's texture: `.bgra8Unorm`, read by shaders.
    private func texture(_ frame: Frame) throws -> any MTLTexture {
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .bgra8Unorm, width: frame.width, height: frame.height, mipmapped: false)
        descriptor.usage = [.shaderRead]
        descriptor.storageMode = .shared
        let texture = try #require(device.makeTexture(descriptor: descriptor))
        frame.bgra.withUnsafeBytes {
            texture.replace(
                region: MTLRegionMake2D(0, 0, frame.width, frame.height), mipmapLevel: 0,
                withBytes: $0.baseAddress!, bytesPerRow: frame.width * 4)
        }
        return texture
    }

    /// Encodes with `encode` into a new command buffer, commits it and waits, without blocking a thread, until the GPU
    /// is done.
    private func run<Pass>(_ encode: (any MTLCommandBuffer) -> Pass) async throws -> Pass {
        let commands = try #require(queue.makeCommandBuffer())
        let pass = encode(commands)
        commands.commit()
        await commands.completed()
        #expect(commands.status == .completed, "\(String(describing: commands.error))")
        return pass
    }

    private func histogram(_ frame: Frame) async throws -> ColorHistogram {
        let texture = try texture(frame)
        return try await run { quantizer.histogram(of: texture, into: $0) }.result()
    }

    private func map(_ frame: Frame, _ palette: GIFPalette, dither: Float) async throws -> (indices: [UInt8], error: PaletteError) {
        let texture = try texture(frame)
        let pass = try await run { quantizer.map(texture, palette: palette, dither: dither, into: $0) }
        return (pass.indices(), pass.error())
    }

    /// The 8 × 8 Bayer matrix (row y, column x), each `i` as `(i + 0.5) / 64`: the threshold map at `(x mod 8, y mod 8)`.
    @Test func thresholdMapIsBayer8x8() {
        let bayer = [
            0, 32, 8, 40, 2, 34, 10, 42,
            48, 16, 56, 24, 50, 18, 58, 26,
            12, 44, 4, 36, 14, 46, 6, 38,
            60, 28, 52, 20, 62, 30, 54, 22,
            3, 35, 11, 43, 1, 33, 9, 41,
            51, 19, 59, 27, 49, 17, 57, 25,
            15, 47, 7, 39, 13, 45, 5, 37,
            63, 31, 55, 23, 61, 29, 53, 21,
        ]
        #expect(GIFQuantizer.thresholdMap == bayer.map { (Float($0) + 0.5) / 64 })
    }

    /// Random frames of 640 × 360 and 1920 × 1080, a screen-like one with long runs of one colour and an odd size: the
    /// GPU's histogram is the CPU's, bucket by bucket.
    @Test func gpuHistogramEqualsTheCPUOne() async throws {
        let frames = [
            noise(width: 640, height: 360, seed: 1), noise(width: 1920, height: 1080, seed: 2),
            screenLike(width: 1280, height: 720, seed: 3), screenLike(width: 37, height: 23, seed: 4),
        ]
        for frame in frames {
            let gpu = try await histogram(frame)
            let cpu = frame.histogram
            #expect(gpu.pixelCount == cpu.pixelCount, "\(frame.width) × \(frame.height)")
            #expect(gpu.counts == cpu.counts, "\(frame.width) × \(frame.height)")
            #expect(gpu.lowSums == cpu.lowSums, "\(frame.width) × \(frame.height)")
            #expect(gpu.lowSquares == cpu.lowSquares, "\(frame.width) × \(frame.height)")
            #expect(gpu == cpu, "\(frame.width) × \(frame.height)")
        }
    }

    /// Pixels equal to an exact colour go to its index with full dither, at every position of the threshold map, even
    /// with colours of the palette on both sides of them; the same colours not marked exact are dithered.
    @Test func exactColorsAreMappedWithoutDither() async throws {
        let exact: [SIMD3<UInt8>] = [SIMD3(100, 100, 100), SIMD3(200, 40, 40), SIMD3(250, 250, 250)]
        // Neighbours 4 to 6 steps away on each side of each exact colour, which the dither (up to ±7.7 steps) reaches.
        let neighbours: [SIMD3<UInt8>] = [
            SIMD3(95, 95, 95), SIMD3(105, 105, 105), SIMD3(194, 34, 34), SIMD3(206, 46, 46), SIMD3(244, 244, 244),
            SIMD3(255, 255, 255), SIMD3(0, 0, 0), SIMD3(0, 200, 0),
        ]
        var random = SplitMix64(seed: 5)
        let frame = Frame(width: 64, height: 48) { x, y in
            x < 48 ? exact[(x / 16 + y / 16) % exact.count] : randomColor(using: &random)
        }
        let palette = GIFPalette(colors: exact + neighbours, exactCount: exact.count)
        let mapped = try await map(frame, palette, dither: 1)
        for y in 0..<frame.height {
            for x in 0..<48 {
                let expected = exact.firstIndex(of: frame[x, y])!
                #expect(Int(mapped.indices[y * frame.width + x]) == expected, "(\(x), \(y))")
            }
        }

        let notExact = try await map(frame, GIFPalette(colors: exact + neighbours, exactCount: 0), dither: 1)
        var dithered = 0
        for y in 0..<frame.height {
            for x in 0..<48 where Int(notExact.indices[y * frame.width + x]) != exact.firstIndex(of: frame[x, y])! { dithered += 1 }
        }
        #expect(dithered > 48 * frame.height / 8, "only \(dithered) dithered pixels")
    }

    /// Without dither every index is the nearest palette colour in OKLab, as computed on the CPU, but where the two
    /// distances differ by under 1e-5 (the GPU's `float` against the CPU's `Double`): those are counted, under 0.01 %.
    /// The error is the CPU's mean distance to the chosen colours and the share of them farther than `largeError`.
    @Test func noDitherIsTheNearest() async throws {
        let frame = screenLike(width: 640, height: 360, seed: 6)
        var random = SplitMix64(seed: 7)
        var noisy = noise(width: 640, height: 360, seed: 8)
        for i in noisy.pixels.indices where Int.random(in: 0..<3, using: &random) == 0 { noisy.pixels[i] = frame.pixels[i] }
        let palette = PaletteBuilder.build(frame.histogram, quality: .balanced)
        #expect(palette.exactCount > 0 && palette.colors.count == 255)

        let mapped = try await map(noisy, palette, dither: 0)
        let reference = nearest(noisy.pixels, in: palette)
        let labs = palette.colors.map { OKLab.fromSRGB(SIMD3<Float>($0) / 255) }
        var ties = 0
        var sum = 0.0
        var large = 0
        for (i, pixel) in noisy.pixels.enumerated() {
            let index = Int(mapped.indices[i])
            let distance = OKLab.distance(OKLab.fromSRGB(SIMD3<Float>(pixel) / 255), labs[index])
            sum += Double(distance)
            if Double(distance) > PaletteRules.largeError { large += 1 }
            guard index != reference[i].index else { continue }
            #expect(abs(distance - reference[i].distance) < 1e-5, "pixel \(i): \(index) against \(reference[i].index)")
            ties += 1
        }
        #expect(Double(ties) < 0.0001 * Double(noisy.pixels.count), "\(ties) ties")
        let count = Double(noisy.pixels.count)
        #expect(abs(mapped.error.meanOKLab - sum / count) < 1e-6, "\(mapped.error.meanOKLab) against \(sum / count)")
        #expect(abs(mapped.error.largeErrorFraction - Double(large) / count) <= Double(ties + 2) / count)
        #expect(mapped.error.largeErrorFraction > 0.01, "a palette of a screen fits noise badly")
    }

    /// A 1080p frame mapped to black and white: the error times 10⁶ adds up to about 10¹², far past 32 bits, and still
    /// comes out as the CPU's mean.
    @Test func errorIsTheMeanPast32Bits() async throws {
        // 4 096 random colours over the frame, so the CPU converts each once.
        var random = SplitMix64(seed: 9)
        let colors = (0..<4_096).map { _ in randomColor(using: &random) }
        var counts = [Int](repeating: 0, count: colors.count)
        let frame = Frame(width: 1920, height: 1080) { _, _ in
            let i = Int.random(in: 0..<colors.count, using: &random)
            counts[i] += 1
            return colors[i]
        }
        let palette = GIFPalette(colors: [SIMD3(0, 0, 0), SIMD3(255, 255, 255)], exactCount: 0)
        let mapped = try await map(frame, palette, dither: 0)

        let reference = nearest(colors, in: palette)
        let sum = zip(reference, counts).reduce(0.0) { $0 + Double($1.0.distance) * Double($1.1) }
        let large = zip(reference, counts).reduce(0) { $0 + (Double($1.0.distance) > PaletteRules.largeError ? $1.1 : 0) }
        let count = Double(frame.pixels.count)
        #expect(sum * 1e6 > Double(UInt32.max) * 100)
        #expect(abs(mapped.error.meanOKLab - sum / count) < 1e-6, "\(mapped.error.meanOKLab) against \(sum / count)")
        #expect(mapped.error.largeErrorFraction == Double(large) / count)
    }

    /// Two frames that differ only inside a rectangle, mapped with dither to the same palette: outside it, the same
    /// indices (the ordered dither depends on the pixel and its position only).
    @Test func orderedDitherIsStableForUnchangedPixels() async throws {
        let first = screenLike(width: 640, height: 360, seed: 10)
        var second = first
        let changed = (x: 200..<333, y: 101..<190)
        var random = SplitMix64(seed: 11)
        for y in changed.y { for x in changed.x { second[x, y] = randomColor(using: &random) } }
        let palette = PaletteBuilder.build(first.histogram, quality: .balanced)
        let a = try await map(first, palette, dither: GIFQuality.balanced.ditherStrength)
        let b = try await map(second, palette, dither: GIFQuality.balanced.ditherStrength)
        var differentInside = 0
        for y in 0..<first.height {
            for x in 0..<first.width {
                let i = y * first.width + x
                if changed.x.contains(x) && changed.y.contains(y) {
                    if a.indices[i] != b.indices[i] { differentInside += 1 }
                } else {
                    #expect(a.indices[i] == b.indices[i], "(\(x), \(y))")
                }
            }
        }
        #expect(differentInside > changed.x.count * changed.y.count / 2)

        // The dither is on: it moves pixels the plain nearest colour would not.
        let plain = try await map(first, palette, dither: 0)
        #expect(plain.indices != a.indices)
    }

    /// Two runs, at the same time, of the histogram and of the mapping of a 1080p frame: the same histogram, the same
    /// indices and the same error, also with another quantizer.
    @Test func mappingIsDeterministic() async throws {
        let frame = screenLike(width: 1920, height: 1080, seed: 12)
        let texture = try texture(frame)
        let palette = PaletteBuilder.build(frame.histogram, quality: .high)
        let other = try GIFQuantizer(device: device)
        // Three command buffers on two queues, all in flight together.
        let otherQueue = try #require(device.makeCommandQueue())
        let commands = try [queue, otherQueue, queue].map { try #require($0.makeCommandBuffer()) }
        let histograms = [quantizer.histogram(of: texture, into: commands[0]), other.histogram(of: texture, into: commands[1])]
        let maps = [
            quantizer.map(texture, palette: palette, dither: 1, into: commands[0]),
            quantizer.map(texture, palette: palette, dither: 1, into: commands[1]),
            other.map(texture, palette: palette, dither: 1, into: commands[2]),
        ]
        for buffer in commands { buffer.commit() }
        for buffer in commands {
            await buffer.completed()
            #expect(buffer.status == .completed, "\(String(describing: buffer.error))")
        }
        #expect(histograms[0].result() == histograms[1].result())
        #expect(histograms[0].result() == frame.histogram)
        let first = (maps[0].indices(), maps[0].error())
        for map in maps.dropFirst() {
            #expect(map.indices() == first.0)
            #expect(map.error() == first.1)
        }
        #expect(first.1.meanOKLab > 0)
    }
}
