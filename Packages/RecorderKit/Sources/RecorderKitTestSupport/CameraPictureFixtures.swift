// SPDX-License-Identifier: GPL-3.0-or-later
import CoreMedia
import CoreVideo
import Foundation
import Metal
import ProjectFormat
import SyntheticCapture

/// Cameras, masks and `.cube`s to draw the camera's picture with (plan 2b task I10, phase 2 design §6.1 to §6.3), as
/// pixels (`bgra`), as textures (`texture`), as video (a `VideoSegmentSpec.transform`, `writeMask`) and as files.
///
/// - **Quadrants:** a camera whose top-left quarter is red, top-right green, bottom-left blue and bottom-right white,
///   so where a framing's crop falls shows by its colours.
/// - **A person:** a head, a neck and shoulders, in skin, hair and a shirt, over a checkerboard of two colours with sharp
///   edges (`person`), and its mask (`personMask`), the person white over black with an edge as soft as a mask of
///   Vision's is, in a frame of any size: the same shape at any resolution, so a mask of fewer pixels than its camera
///   still falls on the person.
public enum CameraPictureFixtures {
    /// A colour as BGRA bytes, as a `.bgra8Unorm` texture and a 32BGRA pixel buffer hold it.
    public typealias BGRA = SIMD4<UInt8>

    public static let red: BGRA = [0, 0, 255, 255]
    public static let green: BGRA = [0, 255, 0, 255]
    public static let blue: BGRA = [255, 0, 0, 255]
    public static let white: BGRA = [255, 255, 255, 255]

    /// The quadrants' colour of pixel (`x`, `y`) of a frame `width` × `height`.
    public static func quadrant(_ x: Int, _ y: Int, width: Int, height: Int) -> BGRA {
        switch (x < width / 2, y < height / 2) {
        case (true, true): red
        case (false, true): green
        case (true, false): blue
        case (false, false): white
        }
    }

    /// The checkerboard behind the person: squares of a twelfth of the frame's height.
    public static let checkerA: BGRA = [200, 120, 40, 255]  // a blue
    public static let checkerB: BGRA = [60, 200, 230, 255]  // a yellow
    public static let skin: BGRA = [140, 170, 220, 255]
    public static let hair: BGRA = [40, 60, 90, 255]
    public static let shirt: BGRA = [70, 60, 60, 255]

    /// How far (in fractions of the frame's height) the point (`u`, `v`) is outside the person (negative inside), in a
    /// frame of aspect `aspect` (width over height), `u` across its width and `v` down its height, each 0 to 1. A head
    /// (a circle), a neck and shoulders (an ellipse running out of the frame's bottom), in the middle of the frame.
    public static func personDistance(u: Double, v: Double, aspect: Double) -> Double {
        let p = SIMD2(u * aspect, v), centre = aspect / 2
        func ellipse(_ c: SIMD2<Double>, _ r: SIMD2<Double>) -> Double {
            let q = (p - c) / r
            return ((q * q).sum().squareRoot() - 1) * min(r.x, r.y)
        }
        let head = ellipse(SIMD2(centre, 0.37), SIMD2(0.17, 0.21))
        let shoulders = ellipse(SIMD2(centre, 1.1), SIMD2(0.44, 0.40))
        let neckOffset = SIMD2(abs(p.x - centre) - 0.07, max(0.5 - p.y, p.y - 0.85))
        let neck = (SIMD2(max(neckOffset.x, 0), max(neckOffset.y, 0)) * SIMD2(max(neckOffset.x, 0), max(neckOffset.y, 0))).sum()
            .squareRoot() + min(max(neckOffset.x, neckOffset.y), 0)
        return min(head, shoulders, neck)
    }

    /// How much of pixel (`x`, `y`) of a frame `width` × `height` is the person, 0 to 1, its edge `softness` pixels wide.
    public static func personCoverage(_ x: Int, _ y: Int, width: Int, height: Int, softness: Double = 1) -> Double {
        let h = Double(height)
        let d = personDistance(u: (Double(x) + 0.5) / Double(width), v: (Double(y) + 0.5) / h, aspect: Double(width) / h)
        return min(max(0.5 - d * h / softness, 0), 1)
    }

    /// The camera's pixel (`x`, `y`) of a frame `width` × `height`: the person (hair over the top of the head, a shirt
    /// below the neck) over the checkerboard, antialiased.
    public static func person(_ x: Int, _ y: Int, width: Int, height: Int) -> BGRA {
        let side = max(height / 12, 1)
        let behind = (x / side + y / side) % 2 == 0 ? checkerA : checkerB
        let v = (Double(y) + 0.5) / Double(height)
        let own = v < 0.27 ? hair : v > 0.72 ? shirt : skin
        let a = personCoverage(x, y, width: width, height: height)
        func channel(_ i: Int) -> UInt8 { UInt8((Double(own[i]) * a + Double(behind[i]) * (1 - a)).rounded()) }
        return BGRA(channel(0), channel(1), channel(2), 255)
    }

    /// The person's mask of pixel (`x`, `y`) of a mask `width` × `height`: 255 on the person, 0 off it, its edge 1.5
    /// pixels of the mask wide.
    public static func personMask(_ x: Int, _ y: Int, width: Int, height: Int) -> UInt8 {
        UInt8((personCoverage(x, y, width: width, height: height, softness: 1.5) * 255).rounded())
    }

    /// A `.bgra8Unorm` texture `width` × `height` whose pixel (`x`, `y`) is `bgra(x, y)`, readable by the shaders.
    public static func texture(
        _ device: any MTLDevice, width: Int, height: Int, bgra: (_ x: Int, _ y: Int) -> BGRA
    ) throws -> any MTLTexture {
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm, width: width, height: height, mipmapped: false)
        descriptor.usage = [.shaderRead]
        descriptor.storageMode = .shared
        guard let texture = device.makeTexture(descriptor: descriptor) else { throw TestSupportError.missing("texture") }
        var bytes = [UInt8](repeating: 0, count: width * height * 4)
        for y in 0..<height {
            for x in 0..<width {
                let pixel = bgra(x, y), i = (y * width + x) * 4
                (bytes[i], bytes[i + 1], bytes[i + 2], bytes[i + 3]) = (pixel.x, pixel.y, pixel.z, pixel.w)
            }
        }
        texture.replace(region: MTLRegionMake2D(0, 0, width, height), mipmapLevel: 0, withBytes: bytes, bytesPerRow: width * 4)
        return texture
    }

    /// A gray mask as a texture: its pixel (`x`, `y`) `value(x, y)` in all three channels, as a mask's video decodes.
    public static func maskTexture(
        _ device: any MTLDevice, width: Int, height: Int, value: (_ x: Int, _ y: Int) -> UInt8
    ) throws -> any MTLTexture {
        try texture(device, width: width, height: height) { x, y in
            let v = value(x, y)
            return [v, v, v, 255]
        }
    }

    /// `sample` with each pixel painted `bgra(x, y, width, height)` (for a `VideoSegmentSpec.transform`).
    public static func painting(
        _ sample: CMSampleBuffer, _ bgra: (_ x: Int, _ y: Int, _ width: Int, _ height: Int) -> BGRA
    ) -> CMSampleBuffer {
        let pixelBuffer = CMSampleBufferGetImageBuffer(sample)!
        CVPixelBufferLockBaseAddress(pixelBuffer, [])
        defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, []) }
        let width = CVPixelBufferGetWidth(pixelBuffer), height = CVPixelBufferGetHeight(pixelBuffer)
        let base = CVPixelBufferGetBaseAddress(pixelBuffer)!
        for y in 0..<height {
            let row = base.advanced(by: y * CVPixelBufferGetBytesPerRow(pixelBuffer)).assumingMemoryBound(to: UInt8.self)
            for x in 0..<width {
                let pixel = bgra(x, y, width, height)
                (row[4 * x], row[4 * x + 1], row[4 * x + 2], row[4 * x + 3]) = (pixel.x, pixel.y, pixel.z, pixel.w)
            }
        }
        return sample
    }

    /// The BGRA bytes of a frame `width` × `height` whose pixel (`x`, `y`) is `bgra(x, y)`, rows without padding: to paint
    /// many frames alike with `copying`.
    public static func bytes(width: Int, height: Int, bgra: (_ x: Int, _ y: Int) -> BGRA) -> [UInt8] {
        var bytes = [UInt8](repeating: 0, count: width * height * 4)
        for y in 0..<height {
            for x in 0..<width {
                let pixel = bgra(x, y), i = (y * width + x) * 4
                (bytes[i], bytes[i + 1], bytes[i + 2], bytes[i + 3]) = (pixel.x, pixel.y, pixel.z, pixel.w)
            }
        }
        return bytes
    }

    /// `sample` with its frame replaced by `bytes` (`bytes(width:height:bgra:)` of its size).
    public static func copying(_ sample: CMSampleBuffer, bytes: [UInt8]) -> CMSampleBuffer {
        let pixelBuffer = CMSampleBufferGetImageBuffer(sample)!
        CVPixelBufferLockBaseAddress(pixelBuffer, [])
        defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, []) }
        let width = CVPixelBufferGetWidth(pixelBuffer), height = CVPixelBufferGetHeight(pixelBuffer)
        precondition(bytes.count == width * height * 4, "CameraPictureFixtures: \(bytes.count) bytes for a frame of \(width) × \(height)")
        let base = CVPixelBufferGetBaseAddress(pixelBuffer)!
        bytes.withUnsafeBytes { source in
            for y in 0..<height {
                base.advanced(by: y * CVPixelBufferGetBytesPerRow(pixelBuffer))
                    .copyMemory(from: source.baseAddress!.advanced(by: y * width * 4), byteCount: width * 4)
            }
        }
        return sample
    }

    /// Writes a person's mask as the analysis caches keep one (plan 2b decision 4): an HEVC video at `url` (whose folder
    /// is made), its frames those of a camera segment written from `start` (`seconds` of `framesPerSecond`, at the same
    /// presentation times, the first at 0), each `width` × `height`, gray: frame `n` (counting from `firstFrame`) with
    /// `value(n, x, y)` in all three channels. Written by a `TakeBuilder` of its own in `scratch`, as a camera's segment is,
    /// then moved to `url`.
    public nonisolated(nonsending) static func writeMask(
        to url: URL, scratch: URL, start: HostTime, seconds: Double, framesPerSecond: Int = 30, width: Int, height: Int,
        firstFrame: Int = 0, value: @escaping @Sendable (_ frame: Int, _ x: Int, _ y: Int) -> UInt8
    ) async throws {
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        let builder = try TakeBuilder(in: scratch, name: "Mask-\(UUID().uuidString.prefix(8))")
        let source = TrackSource(name: "Synthetic Mask", deviceUniqueID: "synthetic-mask")
        try await builder.addVideoTrack(
            id: "mask", kind: .camera, source: source,
            segments: [VideoSegmentSpec(
                start: start, seconds: seconds, framesPerSecond: framesPerSecond, width: width, height: height,
                transform: { index, sample in
                    painting(sample) { x, y, _, _ in
                        let v = value(firstFrame + index, x, y)
                        return [v, v, v, 255]
                    }
                })])
        let project = try builder.write()
        let segment = try project.take.track("mask").flatMap(\.segments.first).unwrapped("the mask's segment")
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.moveItem(at: project.package.fileURL(segment.file), to: url)
        try FileManager.default.removeItem(at: project.package.url)
    }

    /// The `.cube` of `size` points a side whose point (r, g, b) holds `value(r, g, b)` (each 0 to 1 across the cube), with
    /// `domain` (`DOMAIN_MIN` and `DOMAIN_MAX`, left out when 0 and 1).
    public static func cube(
        size: Int, domain: (min: Double, max: Double) = (0, 1), _ value: (SIMD3<Double>) -> SIMD3<Double>
    ) -> String {
        var text = "TITLE \"Toma test\"\nLUT_3D_SIZE \(size)\n"
        if domain != (0, 1) {
            text += "DOMAIN_MIN \(domain.min) \(domain.min) \(domain.min)\nDOMAIN_MAX \(domain.max) \(domain.max) \(domain.max)\n"
        }
        let last = Double(size - 1)
        for b in 0..<size {
            for g in 0..<size {
                for r in 0..<size {
                    let c = value(SIMD3(Double(r), Double(g), Double(b)) / last)
                    text += String(format: "%.6f %.6f %.6f\n", c.x, c.y, c.z)
                }
            }
        }
        return text
    }

    /// Writes `text` as the package's `.cube` `assets/<name>.cube` (the folder made) and returns that path, as
    /// `CameraColor.lut` holds it. `name` is 32 lowercase hex digits.
    @discardableResult
    public static func writeCube(
        _ text: String, in package: ProjectPackage, name: String = "0123456789abcdef0123456789abcdef"
    ) throws -> String {
        let path = "assets/\(name).cube"
        try FileManager.default.createDirectory(at: package.fileURL("assets"), withIntermediateDirectories: true)
        try Data(text.utf8).write(to: package.fileURL(path))
        return path
    }
}

extension Optional {
    /// The value, or `TestSupportError.missing(what)`.
    fileprivate func unwrapped(_ what: String) throws -> Wrapped {
        guard let self else { throw TestSupportError.missing(what) }
        return self
    }
}
