// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation

/// The colours of a frame (design §7.2, step 2), in 32 768 buckets of 5 bits per channel. Per bucket and channel it
/// keeps the sum of the 3 low bits and of their squares: integers, so the result does not depend on the order the
/// pixels are added in, and the mean and the variance of each bucket come out of them.
///
/// The bucket of a colour is `r >> 3 << 10 | g >> 3 << 5 | b >> 3` (red the highest); in `lowSums` and `lowSquares`,
/// x is red, y green and z blue. `init(bgra:width:height:bytesPerRow:)` is the CPU reference of the GPU histogram.
public struct ColorHistogram: Equatable, Sendable {
    /// 2^15: 5 bits of red, green and blue.
    public static let bucketCount = 32_768
    /// How many pixels fall in each bucket.
    public var counts: [UInt32]
    /// Per bucket, the sums of the 3 low bits of red, green and blue.
    public var lowSums: [SIMD3<UInt32>]
    /// Per bucket, the sums of the squares of those low bits.
    public var lowSquares: [SIMD3<UInt32>]
    public var pixelCount: Int
}

extension ColorHistogram {
    /// The most pixels a histogram holds: a bucket's sum of squares (49 per pixel at most) fits in 32 bits.
    static let maxPixels = Int(UInt32.max / 49)

    /// The histogram of a BGRA frame of 8 bits per channel; alpha is not read (the render is opaque), nor the bytes
    /// after `width` pixels in a row.
    public init(bgra: UnsafeRawBufferPointer, width: Int, height: Int, bytesPerRow: Int) {
        precondition(width >= 0 && height >= 0 && bytesPerRow >= width * 4)
        precondition(width * height <= Self.maxPixels, "a frame of \(width) × \(height) overflows the sums")
        precondition(height == 0 || bgra.count >= (height - 1) * bytesPerRow + width * 4)
        var counts = [UInt32](repeating: 0, count: Self.bucketCount)
        var lowSums = [SIMD3<UInt32>](repeating: .zero, count: Self.bucketCount)
        var lowSquares = [SIMD3<UInt32>](repeating: .zero, count: Self.bucketCount)
        for y in 0..<height {
            let row = y * bytesPerRow
            for x in 0..<width {
                let pixel = row + x * 4
                let b = bgra[pixel], g = bgra[pixel + 1], r = bgra[pixel + 2]
                let bucket = Int(r >> 3) << 10 | Int(g >> 3) << 5 | Int(b >> 3)
                let low = SIMD3(UInt32(r & 7), UInt32(g & 7), UInt32(b & 7))
                counts[bucket] &+= 1
                lowSums[bucket] &+= low
                lowSquares[bucket] &+= low &* low
            }
        }
        self.init(counts: counts, lowSums: lowSums, lowSquares: lowSquares, pixelCount: width * height)
    }

    /// The buckets with pixels, in order.
    func occupiedBuckets() -> [Int] { counts.indices.filter { counts[$0] > 0 } }

    /// The lowest colour of a bucket: its 5 bits of each channel, shifted back up.
    static func base(of bucket: Int) -> SIMD3<UInt32> {
        SIMD3(UInt32(bucket >> 10 & 31) << 3, UInt32(bucket >> 5 & 31) << 3, UInt32(bucket & 31) << 3)
    }

    /// The mean colour of an occupied bucket, sRGB in 0...1.
    func mean(of bucket: Int) -> SIMD3<Float> {
        let count = Float(counts[bucket])
        let mean = SIMD3<Float>(Self.base(of: bucket)) + SIMD3<Float>(lowSums[bucket]) / count
        return mean / 255
    }

    /// The mean colour of an occupied bucket rounded to 8 bits (halves up), in integers.
    func roundedMean(of bucket: Int) -> SIMD3<UInt8> {
        let count = counts[bucket]
        let low = (lowSums[bucket] &* 2 &+ count) / (count * 2)
        return SIMD3<UInt8>(truncatingIfNeeded: Self.base(of: bucket) &+ low)
    }

    /// `count² × variance` of each channel of an occupied bucket, in 8-bit units: `count Σx² − (Σx)²` of the low bits
    /// (the high bits are the same for every pixel in it). Exact, in integers.
    func scaledVariance(of bucket: Int) -> SIMD3<UInt64> {
        let count = UInt64(counts[bucket])
        let sums = SIMD3<UInt64>(truncatingIfNeeded: lowSums[bucket])
        let squares = SIMD3<UInt64>(truncatingIfNeeded: lowSquares[bucket])
        return squares &* count &- sums &* sums
    }

    /// Every pixel of the bucket is the same colour.
    func isUniform(_ bucket: Int) -> Bool { scaledVariance(of: bucket) == .zero }

    /// The variance of each channel of the bucket is at most 1 in 8 bits: a flat colour, maybe with a little noise.
    func isNearlyUniform(_ bucket: Int) -> Bool {
        let count = UInt64(counts[bucket])
        let variance = scaledVariance(of: bucket)
        return variance.x <= count * count && variance.y <= count * count && variance.z <= count * count
    }
}

/// The GIF's Quality (design §7.1): colours per frame, how strong the ordered dither is and how far a frame may be from
/// the previous palette before a new one is built. The values are the provisional ones of plan decision 17, tuned on
/// the corpus in Task 25.
public enum GIFQuality: String, Codable, Sendable, CaseIterable {
    case light, balanced, high

    /// Colours per frame, the transparent index included.
    public var maxColors: Int {
        switch self {
        case .light: 128
        case .balanced, .high: 256
        }
    }

    /// The dither's offset is `(m − 0.5) × ditherStrength / 16` in sRGB, `m` the threshold map.
    public var ditherStrength: Float {
        switch self {
        case .light, .high: 1.0
        case .balanced: 0.75
        }
    }

    /// The largest mean error in OKLab of a frame mapped to the previous palette that still reuses it.
    public var reuseMeanError: Double {
        switch self {
        case .light: 0.025
        case .balanced: 0.015
        case .high: 0.010
        }
    }
}

/// The rules of a new palette and of reusing one (design §7.2, step 3).
public enum PaletteRules {
    /// At most this many exact colours.
    public static let maxExactColors = 32
    /// The share of the frame a nearly uniform bucket covers to be an exact colour.
    public static let exactCoverage = 0.005
    /// A pixel farther than this in OKLab from its palette colour has a large error.
    public static let largeError = 0.06
    /// A palette is reused only while fewer than this share of the pixels have a large error.
    public static let largeErrorLimit = 0.02
}

/// The colours of a frame. The first `exactCount` are exact (a pixel of that colour maps to it without dither); there
/// are never more than `maxColors − 1`, so `transparentIndex`, the one after the last, is free in every palette
/// (plan decision 16).
public struct GIFPalette: Equatable, Sendable {
    public var colors: [SIMD3<UInt8>]
    public var exactCount: Int
    public var transparentIndex: Int { colors.count }

    public init(colors: [SIMD3<UInt8>], exactCount: Int) {
        self.colors = colors
        self.exactCount = exactCount
    }
}

/// How well a palette fits a frame: the mean distance in OKLab from each pixel to the colour it maps to, and the share
/// of the pixels farther than `PaletteRules.largeError`.
public struct PaletteError: Equatable, Sendable {
    public var meanOKLab: Double
    public var largeErrorFraction: Double

    public init(meanOKLab: Double, largeErrorFraction: Double) {
        self.meanOKLab = meanOKLab
        self.largeErrorFraction = largeErrorFraction
    }
}

/// A frame's palette (design §7.2, step 3), a pure function of its histogram and the quality.
public enum PaletteBuilder {
    /// Rounds of k-means after the median cut.
    static let kMeansRounds = 2

    /// If the frame has at most `maxColors − 1` occupied buckets and every one is uniform, those colours, all exact
    /// (plan decision 15: the frame maps without loss). If not, up to `maxExactColors` exact colours, the nearly uniform
    /// buckets covering at least `exactCoverage` of the frame each, largest first; then a median cut in OKLab weighted
    /// by pixel count over the other buckets until the palette has `maxColors − 1` colours (or one per bucket), and two
    /// rounds of k-means over those buckets, the exact colours fixed. Ties go to the lower bucket index (and, between
    /// colours at the same distance, to the lower palette index).
    public static func build(_ histogram: ColorHistogram, quality: GIFQuality) -> GIFPalette {
        let limit = quality.maxColors - 1
        let occupied = histogram.occupiedBuckets()
        if occupied.count <= limit && occupied.allSatisfy(histogram.isUniform) {
            let colors = largestFirst(occupied, histogram).map(histogram.roundedMean(of:))
            return GIFPalette(colors: colors, exactCount: colors.count)
        }

        let minimumCount = PaletteRules.exactCoverage * Double(histogram.pixelCount)
        let candidates = occupied.filter { Double(histogram.counts[$0]) >= minimumCount && histogram.isNearlyUniform($0) }
        let exactBuckets = largestFirst(candidates, histogram).prefix(min(PaletteRules.maxExactColors, limit))
        let exactColors = exactBuckets.map(histogram.roundedMean(of:))

        let exactSet = Set(exactBuckets)
        let samples = Samples(histogram, buckets: occupied.filter { !exactSet.contains($0) })
        var centroids = medianCut(samples, boxes: limit - exactColors.count)
        let fixed = exactColors.map { OKLab.fromSRGB(SIMD3<Float>($0) / 255) }
        for _ in 0..<kMeansRounds { centroids = kMeansRound(samples, fixed: fixed, moving: centroids) }
        return GIFPalette(colors: exactColors + centroids.map(byteColor), exactCount: exactColors.count)
    }

    /// Whether the previous palette stays for a frame mapped to it with `error`: the mean error within the quality's
    /// threshold and fewer than `largeErrorLimit` of the pixels with a large error.
    public static func shouldReuse(_ error: PaletteError, quality: GIFQuality) -> Bool {
        error.meanOKLab <= quality.reuseMeanError && error.largeErrorFraction < PaletteRules.largeErrorLimit
    }

    /// Buckets from the most pixels to the fewest, the lower index first on ties.
    private static func largestFirst(_ buckets: [Int], _ histogram: ColorHistogram) -> [Int] {
        buckets.sorted { a, b in
            histogram.counts[a] != histogram.counts[b] ? histogram.counts[a] > histogram.counts[b] : a < b
        }
    }

    /// An OKLab colour in 8-bit sRGB, clamped to the gamut.
    private static func byteColor(_ lab: SIMD3<Float>) -> SIMD3<UInt8> {
        let rgb = OKLab.toSRGB(lab).clamped(lowerBound: .zero, upperBound: .one)
        return SIMD3<UInt8>((rgb * 255).rounded(.toNearestOrAwayFromZero))
    }
}

extension PaletteBuilder {
    /// The buckets the median cut and k-means work on, in bucket order: the mean colour of each in OKLab, by channel,
    /// and its pixel count.
    struct Samples {
        var l: [Float] = []
        var a: [Float] = []
        var b: [Float] = []
        var weights: [Double] = []

        init(_ histogram: ColorHistogram, buckets: [Int]) {
            for bucket in buckets {
                let lab = OKLab.fromSRGB(histogram.mean(of: bucket))
                l.append(lab.x)
                a.append(lab.y)
                b.append(lab.z)
                weights.append(Double(histogram.counts[bucket]))
            }
        }

        var count: Int { weights.count }
        subscript(_ i: Int) -> SIMD3<Double> { SIMD3(Double(l[i]), Double(a[i]), Double(b[i])) }
        func coordinate(_ i: Int, axis: Int) -> Float { axis == 0 ? l[i] : axis == 1 ? a[i] : b[i] }
    }

    /// Samples of the median cut, with their weighted mean and spread.
    struct Box {
        /// Indices into the samples.
        var members: [Int]
        var weight: Double = 0
        var mean = SIMD3<Double>.zero
        /// Per axis, the weighted sum of squared distances to the mean.
        var spread = SIMD3<Double>.zero
        var error: Double { spread.sum() }

        init(_ members: [Int], _ samples: Samples) {
            self.members = members
            var sum = SIMD3<Double>.zero
            for i in members {
                weight += samples.weights[i]
                sum += samples[i] * samples.weights[i]
            }
            mean = sum / weight
            for i in members {
                let d = samples[i] - mean
                spread += d * d * samples.weights[i]
            }
        }
    }

    /// Splits the box with the most error at the weighted median of its widest axis until there are `count` boxes (or
    /// none can be split); the colours are the boxes' means.
    static func medianCut(_ samples: Samples, boxes count: Int) -> [SIMD3<Float>] {
        guard count > 0, samples.count > 0 else { return [] }
        var boxes = [Box(Array(0..<samples.count), samples)]
        while boxes.count < count {
            var chosen = 0
            for i in boxes.indices where boxes[i].error > boxes[chosen].error { chosen = i }
            guard boxes[chosen].error > 0 else { break }
            let (low, high) = split(boxes[chosen], samples)
            boxes[chosen] = low
            boxes.append(high)
        }
        return boxes.map { SIMD3<Float>($0.mean) }
    }

    /// The box cut in two along its axis of most spread: the samples in order along it (by bucket on ties), the
    /// first part up to the one where half the weight is reached, each part with at least one.
    private static func split(_ box: Box, _ samples: Samples) -> (Box, Box) {
        let spread = box.spread
        let axis = spread.x >= spread.y && spread.x >= spread.z ? 0 : spread.y >= spread.z ? 1 : 2
        let ordered = box.members.sorted { i, j in
            let ci = samples.coordinate(i, axis: axis), cj = samples.coordinate(j, axis: axis)
            return ci != cj ? ci < cj : i < j
        }
        var cut = 1
        var weight = samples.weights[ordered[0]]
        while cut < ordered.count - 1 && weight < box.weight / 2 {
            weight += samples.weights[ordered[cut]]
            cut += 1
        }
        return (Box(Array(ordered[..<cut]), samples), Box(Array(ordered[cut...]), samples))
    }

    /// One round of k-means: each sample goes to the nearest colour, fixed or moving (the lower palette index on ties),
    /// and each moving colour moves to the weighted mean of its samples (it stays where it was without any).
    static func kMeansRound(_ samples: Samples, fixed: [SIMD3<Float>], moving: [SIMD3<Float>]) -> [SIMD3<Float>] {
        guard !moving.isEmpty else { return moving }
        let centers = fixed + moving
        let cl = centers.map(\.x), ca = centers.map(\.y), cb = centers.map(\.z)
        var sums = [SIMD3<Double>](repeating: .zero, count: moving.count)
        var weights = [Double](repeating: 0, count: moving.count)
        cl.withUnsafeBufferPointer { cl in
            ca.withUnsafeBufferPointer { ca in
                cb.withUnsafeBufferPointer { cb in
                    for i in 0..<samples.count {
                        let l = samples.l[i], a = samples.a[i], b = samples.b[i]
                        var nearest = 0
                        var best = Float.infinity
                        for c in 0..<centers.count {
                            let dl = l - cl[c], da = a - ca[c], db = b - cb[c]
                            let distance = dl * dl + da * da + db * db
                            if distance < best {
                                best = distance
                                nearest = c
                            }
                        }
                        guard nearest >= fixed.count else { continue }
                        sums[nearest - fixed.count] += samples[i] * samples.weights[i]
                        weights[nearest - fixed.count] += samples.weights[i]
                    }
                }
            }
        }
        return moving.indices.map { weights[$0] > 0 ? SIMD3<Float>(sums[$0] / weights[$0]) : moving[$0] }
    }
}
