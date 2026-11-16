// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import Metal
import Render

/// The GIF's two steps on the GPU (design §7.2, steps 2 and 4): a frame's colour histogram, and the mapping of each
/// pixel to a palette index with an ordered dither.
///
/// Both are encoded into the caller's command buffer and read after it completes, so several frames can be in flight
/// on the same quantizer: it holds only its compiled pipelines, and every pass its own buffers. A pass makes all its
/// buffers before its one compute encoder, so when Metal cannot make one it throws
/// `RenderError.metalResourceUnavailable` having encoded nothing (as `Compositor.encode` does). Results never depend
/// on how the GPU schedules its threads: the histogram adds integers with 32-bit atomics, the indices are a function
/// of each pixel and its position alone, and the mapping's error is summed in integers per threadgroup and then, on
/// the CPU, in `Int64` in the order of the threadgroups.
///
/// The frame is the render's: `.bgra8Unorm`, read as the bytes the render wrote (`round(c × 255)` of what a shader
/// reads gives them back exactly).
public final class GIFQuantizer: @unchecked Sendable {
    /// The ordered dither's threshold map (plan decision 18): the 8 × 8 Bayer matrix, row `y` and column `x` at
    /// `y × 8 + x`, each value `i` as `(i + 0.5) / 64`. A pixel at `(x, y)` takes `m` at `(x mod 8, y mod 8)`.
    ///
    /// The matrix doubles from `[0]`: each cell `v` of the one of side `n` becomes the 2 × 2 block
    /// `[[4v, 4v + 2], [4v + 3, 4v + 1]]`, so bit `k` of `x` and `y` (with `b = x_k XOR y_k`, `y_k`) adds
    /// `(2b + y_k) × 4^(2 − k)`.
    public static let thresholdMap: [Float] = (0..<thresholdSide * thresholdSide).map { i in
        let x = i % thresholdSide, y = i / thresholdSide
        let rank = (0..<3).reduce(0) { rank, k in
            let xk = x >> k & 1, yk = y >> k & 1
            return rank + (2 * (xk ^ yk) + yk) << (2 * (2 - k))
        }
        return (Float(rank) + 0.5) / Float(thresholdSide * thresholdSide)
    }

    /// The side of `thresholdMap`.
    static let thresholdSide = 8
    /// Pixels of a row each thread of the histogram adds: it adds a run of them in one bucket with one set of atomics,
    /// which keeps a flat screen (one bucket for most of the frame) from queueing every pixel on the same atomics.
    static let histogramRun = 8
    /// The mapping's threadgroups are this side squared: 256 threads, so a threadgroup's sum of the error times 10⁶
    /// (at most about 10⁶ a pixel: the distance from black to white) fits in 32 bits.
    static let mapGroupSide = 16
    /// The error is summed in integers of this many units per OKLab unit.
    static let errorScale = 1_000_000.0

    private let histogramPipeline: any MTLComputePipelineState
    private let mapPipeline: any MTLComputePipelineState

    /// Compiles the kernels. Throws the compiler's error if they do not build, and `RenderError` if Metal cannot make a
    /// pipeline with threadgroups as large as the mapping's.
    public init(device: any MTLDevice) throws {
        precondition(MemoryLayout<PaletteEntry>.stride == 16, "PaletteEntry must keep the layout of the shader's struct: 16 bytes")
        precondition(MemoryLayout<MapUniforms>.stride == 16, "MapUniforms must keep the layout of the shader's struct: 16 bytes")
        let options = MTLCompileOptions()
        options.mathMode = .safe
        let library = try device.makeLibrary(source: Self.shaderSource, options: options)
        func pipeline(_ name: String, threads: Int) throws -> any MTLComputePipelineState {
            guard let function = library.makeFunction(name: name) else { throw RenderError.missingShaderFunction(name) }
            let descriptor = MTLComputePipelineDescriptor()
            descriptor.computeFunction = function
            descriptor.maxTotalThreadsPerThreadgroup = threads
            let pipeline = try device.makeComputePipelineState(descriptor: descriptor, options: [], reflection: nil)
            guard pipeline.maxTotalThreadsPerThreadgroup >= threads else {
                throw RenderError.metalResourceUnavailable("\(name) with \(threads) threads per threadgroup")
            }
            return pipeline
        }
        histogramPipeline = try pipeline("gifHistogram", threads: 256)
        mapPipeline = try pipeline("gifMap", threads: Self.mapGroupSide * Self.mapGroupSide)
    }

    /// Encodes the histogram of `texture` (`.bgra8Unorm`, alpha not read) into `commandBuffer`, with buffers cleared on
    /// the CPU. Read it with `result()` once the command buffer has completed without error. Throws
    /// `RenderError.metalResourceUnavailable`, having encoded nothing, if Metal cannot make a buffer or the encoder.
    public func histogram(of texture: any MTLTexture, into commandBuffer: any MTLCommandBuffer) throws -> HistogramPass {
        Self.check(texture)
        let pixelCount = texture.width * texture.height
        precondition(pixelCount <= ColorHistogram.maxPixels, "a frame of \(texture.width) × \(texture.height) overflows the sums")
        let buckets = ColorHistogram.bucketCount
        // Per bucket: a count, and the sums and squares as 4 words (red, green, blue, unused), SIMD3<UInt32>'s layout.
        let counts = try Self.buffer(commandBuffer.device, length: buckets * 4, cleared: true)
        let lowSums = try Self.buffer(commandBuffer.device, length: buckets * 16, cleared: true)
        let lowSquares = try Self.buffer(commandBuffer.device, length: buckets * 16, cleared: true)

        let encoder = try Self.computeEncoder(commandBuffer)
        encoder.setComputePipelineState(histogramPipeline)
        encoder.setTexture(texture, index: 0)
        encoder.setBuffer(counts, offset: 0, index: 0)
        encoder.setBuffer(lowSums, offset: 0, index: 1)
        encoder.setBuffer(lowSquares, offset: 0, index: 2)
        let width = histogramPipeline.threadExecutionWidth
        encoder.dispatchThreads(
            MTLSize(width: (texture.width + Self.histogramRun - 1) / Self.histogramRun, height: texture.height, depth: 1),
            threadsPerThreadgroup: MTLSize(width: width, height: max(1, 256 / width), depth: 1))
        encoder.endEncoding()
        return HistogramPass(
            commandBuffer: commandBuffer, counts: counts, lowSums: lowSums, lowSquares: lowSquares, pixelCount: pixelCount)
    }

    /// Encodes the mapping of `texture` (`.bgra8Unorm`) to `palette` into `commandBuffer`. A pixel equal to one of the
    /// palette's exact colours takes its index, undithered; any other, the nearest colour in OKLab, by brute force over
    /// the whole palette (plan decision 19; the lower index on ties), of the pixel plus `(m − 0.5) × dither / 16` on
    /// each channel (plan decision 17), clamped to 0...1, with `m` the threshold map at `(x mod 8, y mod 8)`; with
    /// `dither` 0, the nearest. The error of a pixel is its distance in OKLab, undithered, to the colour it maps to.
    /// Read the indices and the error once the command buffer has completed without error. Throws
    /// `RenderError.metalResourceUnavailable`, having encoded nothing, if Metal cannot make a buffer or the encoder.
    ///
    /// `texture` is the whole output frame: the threshold map is anchored at its origin, so a pixel that does not change
    /// keeps its index from frame to frame. Crop after mapping, never before (a cropped texture would shift the pattern
    /// and make still areas shimmer).
    public func map(
        _ texture: any MTLTexture, palette: GIFPalette, dither: Float, into commandBuffer: any MTLCommandBuffer
    ) throws -> MapPass {
        Self.check(texture)
        precondition((1...255).contains(palette.colors.count), "a GIF palette has 1...255 colours and the transparent index")
        precondition((0...palette.colors.count).contains(palette.exactCount), "more exact colours than colours")
        precondition(dither.isFinite && dither >= 0, "dither \(dither)")
        let entries = palette.colors.map { color in
            let lab = OKLab.fromSRGB(SIMD3<Float>(color) / 255)
            return PaletteEntry(l: lab.x, a: lab.y, b: lab.z, rgb: UInt32(color.x) << 16 | UInt32(color.y) << 8 | UInt32(color.z))
        }
        var uniforms = MapUniforms(
            colorCount: UInt32(palette.colors.count), exactCount: UInt32(palette.exactCount), dither: dither,
            largeError: Float(PaletteRules.largeError))
        let side = Self.mapGroupSide
        let groups = MTLSize(width: (texture.width + side - 1) / side, height: (texture.height + side - 1) / side, depth: 1)
        let pixelCount = texture.width * texture.height
        // Every index and every threadgroup's slot is written by the kernel; only the count of large errors starts at 0.
        let indices = try Self.buffer(commandBuffer.device, length: pixelCount, cleared: false)
        let errorPartials = try Self.buffer(commandBuffer.device, length: groups.width * groups.height * 4, cleared: false)
        let largeErrors = try Self.buffer(commandBuffer.device, length: 4, cleared: true)

        let encoder = try Self.computeEncoder(commandBuffer)
        encoder.setComputePipelineState(mapPipeline)
        encoder.setTexture(texture, index: 0)
        // At most 255 × 16 bytes: within setBytes's 4 KB.
        encoder.setBytes(entries, length: entries.count * MemoryLayout<PaletteEntry>.stride, index: 0)
        encoder.setBytes(&uniforms, length: MemoryLayout<MapUniforms>.stride, index: 1)
        encoder.setBuffer(indices, offset: 0, index: 2)
        encoder.setBuffer(errorPartials, offset: 0, index: 3)
        encoder.setBuffer(largeErrors, offset: 0, index: 4)
        // Whole threadgroups: every thread reaches the reduction's barriers; those past the frame add 0.
        encoder.dispatchThreadgroups(groups, threadsPerThreadgroup: MTLSize(width: side, height: side, depth: 1))
        encoder.endEncoding()
        return MapPass(
            commandBuffer: commandBuffer, indexBuffer: indices, errorPartials: errorPartials, largeErrors: largeErrors,
            pixelCount: pixelCount)
    }

    private static func check(_ texture: any MTLTexture) {
        precondition(texture.pixelFormat == Compositor.pixelFormat, "the GIF reads \(Compositor.pixelFormat) frames, not \(texture.pixelFormat)")
        precondition(texture.usage.contains(.shaderRead), "the frame must be readable by shaders")
    }

    /// A buffer the CPU reads back, shared; `cleared` sets it to 0 on the CPU (the GPU has not seen it yet).
    private static func buffer(_ device: any MTLDevice, length: Int, cleared: Bool) throws -> any MTLBuffer {
        guard let buffer = device.makeBuffer(length: length, options: .storageModeShared) else {
            throw RenderError.metalResourceUnavailable("GIF buffer of \(length) bytes")
        }
        if cleared { memset(buffer.contents(), 0, length) }
        return buffer
    }

    private static func computeEncoder(_ commandBuffer: any MTLCommandBuffer) throws -> any MTLComputeCommandEncoder {
        guard let encoder = commandBuffer.makeComputeCommandEncoder() else {
            throw RenderError.metalResourceUnavailable("GIF compute encoder")
        }
        return encoder
    }
}

/// A frame's histogram on the GPU, from `GIFQuantizer.histogram(of:into:)`.
public struct HistogramPass {
    let commandBuffer: any MTLCommandBuffer
    let counts: any MTLBuffer
    let lowSums: any MTLBuffer
    let lowSquares: any MTLBuffer
    let pixelCount: Int

    /// The histogram, equal to `ColorHistogram(bgra:width:height:bytesPerRow:)` of the same frame. Only after the
    /// command buffer completed: the caller first checks it for `.error` (the GPU can fail one at run time, and its
    /// buffers then hold nothing usable) and reports that as its own typed error; reading before completion traps.
    public func result() -> ColorHistogram {
        precondition(commandBuffer.status == .completed, "the histogram is read after its command buffer completed")
        let buckets = ColorHistogram.bucketCount
        let bucketCounts = Array(UnsafeBufferPointer(start: counts.contents().assumingMemoryBound(to: UInt32.self), count: buckets))
        func triples(_ buffer: any MTLBuffer) -> [SIMD3<UInt32>] {
            let words = UnsafeBufferPointer(start: buffer.contents().assumingMemoryBound(to: UInt32.self), count: buckets * 4)
            return (0..<buckets).map { SIMD3(words[$0 * 4], words[$0 * 4 + 1], words[$0 * 4 + 2]) }
        }
        return ColorHistogram(
            counts: bucketCounts, lowSums: triples(lowSums), lowSquares: triples(lowSquares), pixelCount: pixelCount)
    }
}

/// A frame mapped to a palette on the GPU, from `GIFQuantizer.map(_:palette:dither:into:)`.
public struct MapPass {
    let commandBuffer: any MTLCommandBuffer
    let indexBuffer: any MTLBuffer
    let errorPartials: any MTLBuffer
    let largeErrors: any MTLBuffer
    let pixelCount: Int

    /// A palette index per pixel, row by row, without padding. Only after the command buffer completed: the caller
    /// first checks it for `.error` (the GPU can fail one at run time, and its buffers then hold nothing usable) and
    /// reports that as its own typed error; reading before completion traps.
    public func indices() -> [UInt8] {
        precondition(commandBuffer.status == .completed, "the indices are read after their command buffer completed")
        return Array(UnsafeBufferPointer(start: indexBuffer.contents().assumingMemoryBound(to: UInt8.self), count: pixelCount))
    }

    /// The mean distance in OKLab from each pixel to its colour (the threadgroups' sums of `distance × 10⁶`, each
    /// rounded per pixel, added in their order in `Int64`) and the share farther than `PaletteRules.largeError`. Only
    /// after the command buffer completed, checked for `.error` first, as for `indices()`.
    public func error() -> PaletteError {
        precondition(commandBuffer.status == .completed, "the error is read after its command buffer completed")
        let partials = UnsafeBufferPointer(
            start: errorPartials.contents().assumingMemoryBound(to: UInt32.self), count: errorPartials.length / 4)
        var sum: Int64 = 0
        for partial in partials { sum += Int64(partial) }
        let large = largeErrors.contents().load(as: UInt32.self)
        let count = Double(pixelCount)
        return PaletteError(meanOKLab: Double(sum) / GIFQuantizer.errorScale / count, largeErrorFraction: Double(large) / count)
    }
}

extension GIFQuantizer {
    /// A palette colour as the mapping kernel reads it: in OKLab (converted on the CPU, `OKLab.fromSRGB`) and as
    /// `0xRRGGBB`, to find a pixel equal to an exact colour.
    struct PaletteEntry {
        var l: Float
        var a: Float
        var b: Float
        var rgb: UInt32
    }

    struct MapUniforms {
        var colorCount: UInt32
        var exactCount: UInt32
        var dither: Float
        var largeError: Float
    }

    /// The kernels, after `OKLab.shaderSource`.
    ///
    /// - `gifHistogram`: one thread per run of `histogramRun` pixels of a row; consecutive pixels in the same bucket are
    ///   summed in the thread and added with one atomic per word (a channel with nothing to add is skipped).
    /// - `gifMap`: one thread per pixel in threadgroups of `mapGroupSide`²; each threadgroup adds its pixels'
    ///   `round(error × 10⁶)` and its count of large errors in threadgroup memory, by halves; the first thread writes
    ///   the sum to the threadgroup's slot (`y × groups across + x`) and adds the count to one atomic.
    static let shaderSource = OKLab.shaderSource + """

        constant uint gifHistogramRun = \(histogramRun);
        constant uint gifThresholdSide = \(thresholdSide);
        constant float gifThresholdMap[\(thresholdMap.count)] = {
            \(thresholdMap.map(OKLab.metal).joined(separator: ", "))
        };

        struct GIFPaletteEntry {
            packed_float3 lab;
            uint rgb;
        };

        struct GIFMapUniforms {
            uint colorCount;
            uint exactCount;
            float dither;
            float largeError;
        };

        // The 8-bit channels the render wrote.
        static uint3 gifBytes(float3 color) {
            return uint3(rint(color * 255.0f));
        }

        static void gifHistogramAdd(device atomic_uint *counts, device atomic_uint *lowSums, device atomic_uint *lowSquares,
                                    uint bucket, uint count, uint3 sums, uint3 squares) {
            atomic_fetch_add_explicit(&counts[bucket], count, memory_order_relaxed);
            for (uint c = 0; c < 3; c++) {
                if (sums[c] != 0) {
                    atomic_fetch_add_explicit(&lowSums[bucket * 4 + c], sums[c], memory_order_relaxed);
                    atomic_fetch_add_explicit(&lowSquares[bucket * 4 + c], squares[c], memory_order_relaxed);
                }
            }
        }

        kernel void gifHistogram(texture2d<float, access::read> frame [[texture(0)]],
                                 device atomic_uint *counts [[buffer(0)]],
                                 device atomic_uint *lowSums [[buffer(1)]],
                                 device atomic_uint *lowSquares [[buffer(2)]],
                                 uint2 position [[thread_position_in_grid]]) {
            uint first = position.x * gifHistogramRun;
            uint end = min(first + gifHistogramRun, frame.get_width());
            if (position.y >= frame.get_height() || first >= end) {
                return;
            }
            uint bucket = 0xFFFFFFFF;
            uint count = 0;
            uint3 sums = 0;
            uint3 squares = 0;
            for (uint x = first; x < end; x++) {
                uint3 rgb = gifBytes(frame.read(uint2(x, position.y)).rgb);
                uint pixelBucket = (rgb.r >> 3) << 10 | (rgb.g >> 3) << 5 | (rgb.b >> 3);
                if (pixelBucket != bucket) {
                    if (count != 0) {
                        gifHistogramAdd(counts, lowSums, lowSquares, bucket, count, sums, squares);
                    }
                    bucket = pixelBucket;
                    count = 0;
                    sums = 0;
                    squares = 0;
                }
                uint3 low = rgb & 7;
                count += 1;
                sums += low;
                squares += low * low;
            }
            gifHistogramAdd(counts, lowSums, lowSquares, bucket, count, sums, squares);
        }

        kernel void gifMap(texture2d<float, access::read> frame [[texture(0)]],
                           constant GIFPaletteEntry *palette [[buffer(0)]],
                           constant GIFMapUniforms &uniforms [[buffer(1)]],
                           device uchar *indices [[buffer(2)]],
                           device uint *errorPartials [[buffer(3)]],
                           device atomic_uint *largeErrors [[buffer(4)]],
                           uint2 position [[thread_position_in_grid]],
                           uint2 group [[threadgroup_position_in_grid]],
                           uint2 groups [[threadgroups_per_grid]],
                           uint slot [[thread_index_in_threadgroup]],
                           uint2 size [[threads_per_threadgroup]]) {
            uint width = frame.get_width();
            uint fixedError = 0;
            uint large = 0;
            if (position.x < width && position.y < frame.get_height()) {
                float3 color = frame.read(position).rgb;
                uint3 rgb = gifBytes(color);
                uint packed = rgb.r << 16 | rgb.g << 8 | rgb.b;
                uint chosen = uniforms.colorCount;
                for (uint i = 0; i < uniforms.exactCount; i++) {
                    if (palette[i].rgb == packed) {
                        chosen = i;
                        break;
                    }
                }
                float3 lab = oklabFromSRGB(color);
                if (chosen == uniforms.colorCount) {
                    float3 target = lab;
                    if (uniforms.dither != 0.0f) {
                        float m = gifThresholdMap[(position.y % gifThresholdSide) * gifThresholdSide + position.x % gifThresholdSide];
                        target = oklabFromSRGB(saturate(color + (m - 0.5f) * uniforms.dither / 16.0f));
                    }
                    float best = INFINITY;
                    for (uint i = 0; i < uniforms.colorCount; i++) {
                        float3 d = target - float3(palette[i].lab);
                        float square = dot(d, d);
                        if (square < best) {
                            best = square;
                            chosen = i;
                        }
                    }
                }
                float error = oklabDistance(lab, float3(palette[chosen].lab));
                indices[position.y * width + position.x] = uchar(chosen);
                fixedError = uint(rint(error * \(OKLab.metal(Float(errorScale)))));
                large = error > uniforms.largeError ? 1 : 0;
            }

            threadgroup uint errors[\(mapGroupSide * mapGroupSide)];
            threadgroup uint larges[\(mapGroupSide * mapGroupSide)];
            errors[slot] = fixedError;
            larges[slot] = large;
            for (uint step = size.x * size.y / 2; step > 0; step /= 2) {
                threadgroup_barrier(mem_flags::mem_threadgroup);
                if (slot < step) {
                    errors[slot] += errors[slot + step];
                    larges[slot] += larges[slot + step];
                }
            }
            if (slot == 0) {
                errorPartials[group.y * groups.x + group.x] = errors[0];
                if (larges[0] != 0) {
                    atomic_fetch_add_explicit(largeErrors, larges[0], memory_order_relaxed);
                }
            }
        }

        """
}
