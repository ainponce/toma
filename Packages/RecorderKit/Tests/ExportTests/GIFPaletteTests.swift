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

/// A colour with each channel at random in `range`.
private func randomColor(in range: ClosedRange<UInt8> = 0...255, using random: inout SplitMix64) -> SIMD3<UInt8> {
    SIMD3(UInt8.random(in: range, using: &random), UInt8.random(in: range, using: &random), UInt8.random(in: range, using: &random))
}

/// An sRGB colour in 0...1 at random.
private func randomUnitColor(using random: inout SplitMix64) -> SIMD3<Float> {
    SIMD3(Float.random(in: 0...1, using: &random), Float.random(in: 0...1, using: &random), Float.random(in: 0...1, using: &random))
}

/// The largest difference between two colours, channel by channel.
private func maxDifference(_ a: SIMD3<Float>, _ b: SIMD3<Float>) -> Float {
    max(abs(a.x - b.x), abs(a.y - b.y), abs(a.z - b.z))
}

/// A BGRA frame of `rows` (each a row of RGB pixels, all of the same length), with `padding` bytes of `filler` after
/// each row: what the histogram must never read.
private func bgraFrame(_ rows: [[SIMD3<UInt8>]], padding: Int = 0, filler: UInt8 = 0xA5) -> (bytes: [UInt8], bytesPerRow: Int) {
    let width = rows.first?.count ?? 0
    let bytesPerRow = width * 4 + padding
    var bytes: [UInt8] = []
    bytes.reserveCapacity(bytesPerRow * rows.count)
    for row in rows {
        precondition(row.count == width)
        for pixel in row { bytes += [pixel.z, pixel.y, pixel.x, 255] }
        bytes += [UInt8](repeating: filler, count: padding)
    }
    return (bytes, bytesPerRow)
}

private func histogram(rows: [[SIMD3<UInt8>]], padding: Int = 0, filler: UInt8 = 0xA5) -> ColorHistogram {
    let frame = bgraFrame(rows, padding: padding, filler: filler)
    return frame.bytes.withUnsafeBytes {
        ColorHistogram(bgra: $0, width: rows.first?.count ?? 0, height: rows.count, bytesPerRow: frame.bytesPerRow)
    }
}

/// The histogram of `pixels` in one row: where they are does not change it.
private func histogram(_ pixels: [SIMD3<UInt8>]) -> ColorHistogram { histogram(rows: [pixels]) }

/// `count` pixels of a gradient that never fills a bucket alone (red runs 0...255 and green steps every 256 pixels,
/// so a bucket gets at most 128 of them, of 64 different colours) and keeps blue at 128 (bucket 16).
private func gradient(_ count: Int) -> [SIMD3<UInt8>] {
    (0..<count).map { k in SIMD3(UInt8(k % 256), UInt8((k / 256) % 256), 128) }
}

/// 10 000 random sRGB colours go to OKLab and back unchanged; white is L 1 with no chroma, black is 0.
@Test func oklabRoundTrips() {
    var random = SplitMix64(seed: 18)
    var worst: Float = 0
    for _ in 0..<10_000 {
        let color = randomUnitColor(using: &random)
        worst = max(worst, maxDifference(OKLab.toSRGB(OKLab.fromSRGB(color)), color))
    }
    #expect(worst <= 1e-5, "worst round trip \(worst)")
    let white = OKLab.fromSRGB(SIMD3(1, 1, 1))
    #expect(maxDifference(white, SIMD3(1, 0, 0)) <= 1e-4, "white \(white)")
    #expect(OKLab.fromSRGB(.zero) == .zero)
    #expect(abs(OKLab.distance(white, .zero) - 1) <= 1e-4)
    #expect(OKLab.distance(SIMD3(0.5, 0.1, -0.2), SIMD3(0.5, 0.1, -0.2)) == 0)
}

/// `OKLab.shaderSource` compiles, and the GPU converts with the same numbers as the CPU (one source of coefficients).
@Test(.enabled(if: MetalCondition.isAvailable || MetalCondition.isRequired))
func oklabShaderMatchesTheCPU() throws {
    let device = try #require(MTLCreateSystemDefaultDevice())
    let source = OKLab.shaderSource + """

        kernel void oklabTest(device const float4 *colors [[buffer(0)]], device float4 *labs [[buffer(1)]],
                              uint i [[thread_position_in_grid]]) {
            float3 lab = oklabFromSRGB(colors[i].rgb);
            labs[i] = float4(lab, oklabDistance(lab, float3(1.0f, 0.0f, 0.0f)));
        }
        """
    let library = try device.makeLibrary(source: source, options: nil)
    let pipeline = try device.makeComputePipelineState(function: try #require(library.makeFunction(name: "oklabTest")))

    var random = SplitMix64(seed: 20)
    var colors: [SIMD4<Float>] = (0..<4_096).map { _ in SIMD4(randomUnitColor(using: &random), 0) }
    colors += [SIMD4(0, 0, 0, 0), SIMD4(1, 1, 1, 0), SIMD4(0.04045, 0.04, 0.05, 0), SIMD4(1, 0, 0, 0)]
    let length = colors.count * MemoryLayout<SIMD4<Float>>.stride
    let input = try #require(device.makeBuffer(bytes: colors, length: length, options: .storageModeShared))
    let output = try #require(device.makeBuffer(length: length, options: .storageModeShared))
    let queue = try #require(device.makeCommandQueue())
    let commands = try #require(queue.makeCommandBuffer())
    let encoder = try #require(commands.makeComputeCommandEncoder())
    encoder.setComputePipelineState(pipeline)
    encoder.setBuffer(input, offset: 0, index: 0)
    encoder.setBuffer(output, offset: 0, index: 1)
    encoder.dispatchThreads(
        MTLSize(width: colors.count, height: 1, depth: 1), threadsPerThreadgroup: MTLSize(width: 64, height: 1, depth: 1))
    encoder.endEncoding()
    commands.commit()
    commands.waitUntilCompleted()

    let labs = output.contents().bindMemory(to: SIMD4<Float>.self, capacity: colors.count)
    var worst: Float = 0
    for (i, color) in colors.enumerated() {
        let cpu = OKLab.fromSRGB(SIMD3(color.x, color.y, color.z))
        let gpu = labs[i]
        worst = max(worst, maxDifference(SIMD3(gpu.x, gpu.y, gpu.z), cpu))
        worst = max(worst, abs(gpu.w - OKLab.distance(cpu, SIMD3(1, 0, 0))))
    }
    #expect(worst <= 1e-5, "worst GPU − CPU \(worst)")
}

/// Integer sums per bucket: the same frame with its rows in another order (and other padding) gives the same histogram,
/// and a hand-made bucket holds exactly its counts, low-bit sums and squares (red in the highest 5 bits of the index).
@Test func histogramIsIntegerAndOrderFree() {
    var random = SplitMix64(seed: 7)
    // Channels in 100...139: five buckets each, so every bucket holds many pixels.
    let rows: [[SIMD3<UInt8>]] = (0..<61).map { _ in (0..<97).map { _ in randomColor(in: 100...139, using: &random) } }
    let original = histogram(rows: rows, padding: 12, filler: 0x11)
    let shuffled = histogram(rows: rows.shuffled(using: &random), padding: 28, filler: 0xEE)
    #expect(original == shuffled)
    #expect(original == histogram(rows: rows.reversed()))
    #expect(original.pixelCount == 97 * 61)
    #expect(original.counts.reduce(0, +) == 97 * 61)
    #expect(original.counts.count == ColorHistogram.bucketCount && original.lowSums.count == ColorHistogram.bucketCount)
    #expect(original.lowSquares.count == ColorHistogram.bucketCount)

    // (13, 200, 7), (14, 201, 0) and (8, 207, 6) all fall in bucket (1, 25, 0) = 1 << 10 | 25 << 5 | 0.
    let small = histogram(rows: [[SIMD3(13, 200, 7), SIMD3(14, 201, 0)], [SIMD3(8, 207, 6), SIMD3(255, 0, 64)]], padding: 4)
    let bucket = 1 << 10 | 25 << 5
    #expect(small.counts[bucket] == 3)
    #expect(small.lowSums[bucket] == SIMD3<UInt32>(5 + 6 + 0, 0 + 1 + 7, 7 + 0 + 6))
    #expect(small.lowSquares[bucket] == SIMD3<UInt32>(25 + 36 + 0, 0 + 1 + 49, 49 + 0 + 36))
    let other = 31 << 10 | 0 << 5 | 8
    #expect(small.counts[other] == 1)
    #expect(small.lowSums[other] == SIMD3<UInt32>(7, 0, 0) && small.lowSquares[other] == SIMD3<UInt32>(49, 0, 0))
    #expect(small.pixelCount == 4 && small.counts.reduce(0, +) == 4)
}

/// Three flat colours of 2 % to 5 % of the frame and a gradient: the three are exact, largest first, at indices 0...2.
@Test func exactColorsComeFirst() {
    let flats: [SIMD3<UInt8>] = [SIMD3(230, 40, 20), SIMD3(20, 90, 220), SIMD3(250, 250, 250)]
    let sizes = [3_500, 2_100, 1_400]  // of 67 000: 5.2 %, 3.1 %, 2.1 %
    var pixels = gradient(60_000)
    for (flat, size) in zip(flats, sizes) { pixels += [SIMD3<UInt8>](repeating: flat, count: size) }
    let palette = PaletteBuilder.build(histogram(pixels), quality: .balanced)
    #expect(palette.exactCount == 3)
    #expect(Array(palette.colors.prefix(3)) == flats)
    #expect(palette.colors.count == 255)
}

/// A flat colour with ±1 of noise (variance 2/3 in 8 bits) is still exact, at its mean.
@Test func nearlyFlatColorsAreExactAtTheirMean() {
    var pixels = gradient(60_000)
    for k in 0..<3_000 {
        let jitter = UInt8(k % 3)  // 0, 1, 2 around 1: the mean is (61, 121, 201)
        pixels.append(SIMD3(60 + jitter, 122 - jitter, 200 + jitter))
    }
    let palette = PaletteBuilder.build(histogram(pixels), quality: .balanced)
    #expect(palette.exactCount == 1)
    #expect(palette.colors.first == SIMD3(61, 121, 201))
}

/// 40 flat colours of different sizes, all over 0.5 %, with a gradient: the 32 largest are exact, largest first.
@Test func moreThan32FlatColorsKeepTheLargest() {
    let flats: [SIMD3<UInt8>] = (0..<40).map { (i: Int) -> SIMD3<UInt8> in
        let red: Int = (i % 8) * 32 + 3, green: Int = (i / 8) * 40 + 5
        return SIMD3(UInt8(red), UInt8(green), 200)
    }
    var pixels = gradient(91_140)
    for (i, flat) in flats.enumerated() { pixels += [SIMD3<UInt8>](repeating: flat, count: 1_000 + 37 * i) }
    #expect(pixels.count == 160_000)  // the smallest flat colour is 0.625 %
    let palette = PaletteBuilder.build(histogram(pixels), quality: .balanced)
    #expect(palette.exactCount == PaletteRules.maxExactColors)
    #expect(Array(palette.colors.prefix(32)) == Array(flats.reversed().prefix(32)))
    #expect(palette.colors.count == 255)
}

/// 200 uniform colours in different buckets are the whole palette, all exact, largest first; with Light (127 colours
/// at most) they are too many, and the palette is built as for any frame.
@Test func fewUniformColorsAreTheWholePalette() {
    let colors: [SIMD3<UInt8>] = (0..<200).map { (i: Int) -> SIMD3<UInt8> in
        let red: Int = (i % 8) * 32 + 1, green: Int = (i / 8 % 8) * 32 + 2, blue: Int = (i / 64) * 32 + 3
        return SIMD3(UInt8(red), UInt8(green), UInt8(blue))
    }
    var pixels: [SIMD3<UInt8>] = []
    for (i, color) in colors.enumerated() { pixels += [SIMD3<UInt8>](repeating: color, count: 10 + i) }
    let frame = histogram(pixels)
    for quality in [GIFQuality.balanced, .high] {
        let palette = PaletteBuilder.build(frame, quality: quality)
        #expect(palette.colors == colors.reversed(), "\(quality)")
        #expect(palette.exactCount == 200, "\(quality)")
        #expect(palette.transparentIndex == 200, "\(quality)")
    }
    let light = PaletteBuilder.build(frame, quality: .light)
    #expect(light.colors.count == 127)
    #expect(light.exactCount == PaletteRules.maxExactColors)
}

/// A gradient of 4 096 colours: Balanced and High give 255 colours, Light 127; the last index is the transparent one.
@Test func paletteLeavesOneIndexForTransparency() {
    let rows: [[SIMD3<UInt8>]] = (0..<64).map { y in (0..<64).map { x in SIMD3(UInt8(x * 4), UInt8(y * 4), 100) } }
    let frame = histogram(rows: rows)
    for (quality, count) in [(GIFQuality.balanced, 255), (.high, 255), (.light, 127)] {
        let palette = PaletteBuilder.build(frame, quality: quality)
        #expect(palette.colors.count == count, "\(quality)")
        #expect(palette.transparentIndex == count, "\(quality)")
        #expect(palette.exactCount == 0, "\(quality)")
        #expect(palette.colors.count == quality.maxColors - 1, "\(quality)")
    }
}

/// The same frame twice, and in another row order: the same colours in the same order, never over the limit.
@Test func buildIsDeterministic() {
    var random = SplitMix64(seed: 99)
    let flats: [SIMD3<UInt8>] = (0..<12).map { _ in randomColor(using: &random) }
    // Rows of noise, rows of a flat colour and rows of a gradient.
    let rows: [[SIMD3<UInt8>]] = (0..<90).map { y in
        (0..<160).map { x in
            switch y % 3 {
            case 0: randomColor(using: &random)
            case 1: flats[(x / 16 + y) % flats.count]
            default: SIMD3(UInt8(x), UInt8(y * 2), UInt8((x + y) % 256))
            }
        }
    }
    let frame = histogram(rows: rows)
    let reordered = histogram(rows: rows.shuffled(using: &random), padding: 8)
    for quality in GIFQuality.allCases {
        let first = PaletteBuilder.build(frame, quality: quality)
        #expect(first == PaletteBuilder.build(frame, quality: quality), "\(quality)")
        #expect(first == PaletteBuilder.build(reordered, quality: quality), "\(quality)")
        #expect(first.colors.count == quality.maxColors - 1, "\(quality)")
        #expect(first.exactCount <= PaletteRules.maxExactColors, "\(quality)")
    }
}

/// Reuse while the mean error is within the quality's threshold and fewer than 3 % of the pixels are far off; the
/// constants of plan decision 17 as gifQuant-1 froze them (Task 25).
@Test func reuseFollowsTheThresholds() {
    #expect(PaletteBuilder.shouldReuse(PaletteError(meanOKLab: 0.010, largeErrorFraction: 0.01), quality: .balanced))
    #expect(!PaletteBuilder.shouldReuse(PaletteError(meanOKLab: 0.020, largeErrorFraction: 0.01), quality: .balanced))
    #expect(!PaletteBuilder.shouldReuse(PaletteError(meanOKLab: 0.010, largeErrorFraction: 0.03), quality: .balanced))
    #expect(PaletteBuilder.shouldReuse(PaletteError(meanOKLab: 0.010, largeErrorFraction: 0.029), quality: .balanced))

    #expect(GIFQuality.allCases.map(\.maxColors) == [128, 256, 256])
    #expect(GIFQuality.allCases.map(\.ditherStrength) == [0.75, 0.5, 0.75])
    #expect(GIFQuality.allCases.map(\.reuseMeanError) == [0.025, 0.015, 0.015])
    #expect(PaletteRules.maxExactColors == 32 && PaletteRules.exactCoverage == 0.005)
    #expect(PaletteRules.largeError == 0.06 && PaletteRules.largeErrorLimit == 0.03)
}
