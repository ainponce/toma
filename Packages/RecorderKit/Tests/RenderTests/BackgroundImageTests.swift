// SPDX-License-Identifier: GPL-3.0-or-later
import CoreGraphics
import CoreVideo
import Foundation
import ImageIO
import Metal
import MetalPerformanceShaders
import ProjectFormat
import RecorderKitTestSupport
// @testable for `FrameRenderer.backgroundImages`, `BackgroundImages` and `Compositor.library`: the blur's counter, its
// two paths and the process's decode counter.
@testable import Render
import Testing

// The stage's background from an image: the user's own (`assets/`) or the desktop picture the take saved
// (`wallpapers/`), covering the stage and blurred once per size; Toma classic when it is missing or unreadable.

private let size = SIMD2(320, 180)
private let hash = "0123456789abcdef0123456789abcdef"
private let otherHash = "fedcba9876543210fedcba9876543210"
/// The `CGDirectDisplayID`s of the take's two displays, unlike their track IDs, so a photo is found by the display.
private let firstDisplay: UInt32 = 69_734_208
private let secondDisplay: UInt32 = 731_409

/// Runs `body` on a thread of its own and waits for it without holding a Swift concurrency thread: drawing decodes
/// the image and waits for the GPU, which block (`offThePool` in DocumentRenderTests). `body` checks nothing itself:
/// an expectation off the test's task would not be the test's, so it returns what the test checks.
private func offThePool<T: Sendable>(_ body: @escaping @Sendable () throws -> T) async throws -> T {
    try await withCheckedThrowingContinuation { continuation in
        Thread { continuation.resume(with: Result(catching: body)) }.start()
    }
}

/// `<dir>/Demo.toma` with a take of one second from `base` on two displays, `display-1` (`firstDisplay`) and
/// `display-2` (`secondDisplay`), whose video files are missing: no screen is drawn, so every pixel of a frame is the
/// background, and nothing but the background is read.
private func backgroundProject(in dir: URL) throws -> LoadedProject {
    let package = ProjectPackage(url: dir.appendingPathComponent("Demo.toma", isDirectory: true))
    try FileManager.default.createDirectory(at: package.takeDirectory(takeID), withIntermediateDirectories: true)
    let tracks = [("display-1", firstDisplay), ("display-2", secondDisplay)].map { id, display in
        displayTrack(
            id: id, displayID: display, globalFrame: Rect(x: 0, y: 0, width: 1920, height: 1080),
            segments: [segment(track: id, start: base, end: base.adding(seconds: 1))])
    }
    return makeProject(package, take: makeTake(tracks: tracks))
}

/// Writes `data` at `relativePath` of `package`, making the folders it needs.
private func put(_ data: Data, at relativePath: String, in package: ProjectPackage) throws {
    let url = package.url.appendingPathComponent(relativePath, isDirectory: false)
    try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    try data.write(to: url)
}

/// An opaque sRGB image whose pixel at (`x`, `y`) from the top-left corner has the RGB bytes `color(x, y)`, encoded as
/// `type` (`public.png`, `public.jpeg`).
private func encodedImage(
    width: Int, height: Int, as type: String = "public.png", _ color: (Int, Int) -> SIMD3<UInt8>
) throws -> Data {
    let space = try #require(CGColorSpace(name: CGColorSpace.sRGB))
    let context = try #require(CGContext(
        data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4, space: space,
        bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue))
    let pixels = try #require(context.data).bindMemory(to: UInt8.self, capacity: width * height * 4)
    for y in 0..<height {
        for x in 0..<width {
            let rgb = color(x, y), i = (y * width + x) * 4
            (pixels[i], pixels[i + 1], pixels[i + 2], pixels[i + 3]) = (rgb.x, rgb.y, rgb.z, 255)
        }
    }
    let image = try #require(context.makeImage())
    let data = NSMutableData()
    let destination = try #require(CGImageDestinationCreateWithData(data, type as CFString, 1, nil))
    CGImageDestinationAddImage(destination, image, nil)
    try #require(CGImageDestinationFinalize(destination))
    return data as Data
}

/// An image of one colour, `rgb`.
private func plainImage(_ rgb: SIMD3<UInt8>, width: Int = 64, height: Int = 36) throws -> Data {
    try encodedImage(width: width, height: height) { _, _ in rgb }
}

/// The legacy document of `project` with `background` and `blur`, showing `initial` (a track) first.
private func document(_ project: LoadedProject, _ background: Background, blur: Double = 0, initial: String = "display-1") -> EditDocument {
    var document = EditDocument.legacy(for: project)
    document.style.background = background
    document.style.backgroundBlur = blur
    document.screens.initial = [takeID: initial]
    return document
}

/// The frame at 0.5 s of `document`, `outputSize` big, as BGRA bytes.
private func render(_ project: LoadedProject, _ document: EditDocument, outputSize: SIMD2<Int> = size) async throws -> [UInt8] {
    let renderer = try FrameRenderer(project: project, document: document, outputSize: outputSize)
    return try await offThePool { try renderer.renderBytes(at: 0.5) }
}

private struct PixelBufferUnavailable: Error {
    let status: CVReturn
}

/// The frame at `time` drawn as the export draws it, into a 32BGRA pixel buffer, as BGRA bytes without row padding.
private func exported(_ renderer: FrameRenderer, at time: Double) throws -> [UInt8] {
    var created: CVPixelBuffer?
    let attributes = [kCVPixelBufferIOSurfacePropertiesKey: [:] as CFDictionary, kCVPixelBufferMetalCompatibilityKey: true] as CFDictionary
    let status = CVPixelBufferCreate(
        kCFAllocatorDefault, renderer.outputSize.x, renderer.outputSize.y, kCVPixelFormatType_32BGRA, attributes, &created)
    guard status == kCVReturnSuccess, let pixelBuffer = created else { throw PixelBufferUnavailable(status: status) }
    try renderer.render(at: time, into: pixelBuffer)
    return packedBytes(of: pixelBuffer)
}

/// The RGBA bytes of a `.rgba8Unorm` texture that the CPU can read.
private func bytes(of texture: any MTLTexture) -> [UInt8] {
    var bytes = [UInt8](repeating: 0, count: texture.width * texture.height * 4)
    texture.getBytes(
        &bytes, bytesPerRow: texture.width * 4, from: MTLRegionMake2D(0, 0, texture.width, texture.height), mipmapLevel: 0)
    return bytes
}

/// The BGRA bytes `rgb` makes in a frame.
private func bgra(_ rgb: SIMD3<UInt8>) -> SIMD4<Float> {
    SIMD4(Float(rgb.z), Float(rgb.y), Float(rgb.x), 255)
}

/// An image black on its left half and white on its right half, the edge between columns `width / 2 − 1` and
/// `width / 2`.
private func hardEdge(width: Int, height: Int) throws -> Data {
    try encodedImage(width: width, height: height) { x, _ in x < width / 2 ? [0, 0, 0] : [255, 255, 255] }
}

/// The byte a Gaussian blur of σ `sigma` pixels makes at column `x` of a hard edge from black to white at `edge` (in
/// pixels from the left): 255 × Φ((x + ½ − edge) / σ), at the pixel's centre.
private func blurredEdge(at x: Int, edge: Double, sigma: Double) -> Double {
    255 * 0.5 * erfc(-((Double(x) + 0.5 - edge) / sigma) / 2.0.squareRoot())
}

/// The red bytes of row `y` of tightly packed 4-byte pixels `width` wide.
private func redRow(_ bytes: [UInt8], width: Int, y: Int) -> [Int] {
    (0..<width).map { Int(bytes[(y * width + $0) * 4]) }
}

/// The blurs this device can run: the shader's, and Metal Performance Shaders' where it supports the device.
private func blurs(on device: any MTLDevice) -> [BackgroundImages.Blur] {
    MPSSupportsMTLDevice(device) ? [.shader, .performanceShaders] : [.shader]
}

/// What `BackgroundImages` with `blur` makes of `image` for frames `outputSize` big, as RGBA bytes.
private func prepared(
    _ image: BackgroundImage, outputSize: SIMD2<Int>, blur: BackgroundImages.Blur, in package: ProjectPackage, device: any MTLDevice
) async throws -> [UInt8]? {
    let library = try Compositor(device: device).library
    return try await offThePool {
        let images = try BackgroundImages(device: device, library: library, package: package, blur: blur)
        return try images.texture(for: image, outputSize: outputSize).map(bytes(of:))
    }
}

/// The four corners of an image `size` big.
private func corners(of size: SIMD2<Int>) -> [(x: Int, y: Int)] {
    [(0, 0), (size.x - 1, 0), (0, size.y - 1), (size.x - 1, size.y - 1)]
}

@Test func documentImageReachesTheFrame() throws {
    let tracks = [("display-1", firstDisplay), ("display-2", secondDisplay)].map { id, display in
        displayTrack(id: id, displayID: display, globalFrame: nil, segments: [segment(track: id, start: base, end: base.adding(seconds: 1))])
    }
    let window = displayTrack(id: "window-7", kind: .window, globalFrame: nil, segments: [])
    let take = makeTake(tracks: tracks + [window])
    func frame(_ background: Background, blur: Double = 0, initial: String = "display-1") -> RenderFrame {
        var document = EditDocument.legacy(take: take, events: [])
        document.style.background = background
        document.style.backgroundBlur = blur
        document.screens.initial = [takeID: initial]
        return FrameEvaluator(take: take, events: [], document: document, outputSize: [320, 180]).frame(at: 0.5)
    }
    let file = "assets/\(hash).png"
    // σ = blur × 0.04 × the output width.
    #expect(frame(.image(file: file), blur: 0.5).background == .image(BackgroundImage(source: .asset(file), blurSigma: 6.4)))
    #expect(frame(.image(file: file)).background == .image(BackgroundImage(source: .asset(file), blurSigma: 0)))
    // The blur is 0 to 1.
    #expect(frame(.image(file: file), blur: 3).background == .image(BackgroundImage(source: .asset(file), blurSigma: 12.8)))
    #expect(frame(.image(file: file), blur: -1).background == .image(BackgroundImage(source: .asset(file), blurSigma: 0)))
    #expect(frame(.image(file: file), blur: .nan).background == .image(BackgroundImage(source: .asset(file), blurSigma: 0)))
    // The desktop is the photo of the display the take shows first.
    #expect(frame(.desktop, blur: 1, initial: "display-2").background
        == .image(BackgroundImage(source: .desktop(take: takeID, displayID: secondDisplay), blurSigma: 12.8)))
    // The gradient carried for an image is Toma classic, what is drawn when the image cannot be.
    let classic = frame(.tomaClassic)
    let image = frame(.image(file: file))
    #expect((image.gradientStart, image.gradientEnd, image.gradientAngleDegrees)
        == (classic.gradientStart, classic.gradientEnd, classic.gradientAngleDegrees))
    // A window has no display, so no desktop photo: Toma classic.
    #expect(frame(.desktop, initial: "window-7") == frame(.tomaClassic, initial: "window-7"))
    // A wallpaper is blurred by the same σ.
    let lake = try #require(WallpaperPreset.preset(id: "lake-1"))
    #expect(frame(.wallpaper("lake-1"), blur: 0.5).background == .wallpaper(lake, blurSigma: 6.4))
    #expect(frame(.wallpaper("lake-1")).background == .wallpaper(lake))
}

@Test(.enabled(if: MetalCondition.isAvailable || MetalCondition.isRequired))
func imageCoversTheStageCentered() async throws {
    try await withTemporaryDirectory { dir in
        let project = try backgroundProject(in: dir)
        let file = "assets/\(hash).png"
        // 400×100: green in the middle half, red at both ends.
        try put(
            try encodedImage(width: 400, height: 100) { x, _ in (100..<300).contains(x) ? [0, 255, 0] : [255, 0, 0] },
            at: file, in: project.package)
        let frame = try await render(project, document(project, .image(file: file)))
        // At 16:9 the image shows its middle 4/9 across, all of its height: green everywhere, nothing red.
        #expect(isClose(pixel(frame, width: size.x, x: size.x / 2, y: size.y / 2), [0, 255, 0, 255], tolerance: 1))
        for y in 0..<size.y {
            for x in 0..<size.x {
                let p = pixel(frame, width: size.x, x: x, y: y)
                #expect(isClose(p, [0, 255, 0, 255], tolerance: 1), "at (\(x), \(y)): \(p)")
            }
        }
    }
}

@Test(.enabled(if: MetalCondition.isAvailable || MetalCondition.isRequired))
func blurIsComputedOncePerSize() async throws {
    try await withTemporaryDirectory { dir in
        let project = try backgroundProject(in: dir)
        let file = "assets/\(hash).png"
        try put(try encodedImage(width: 64, height: 36) { x, y in [UInt8(x * 4), UInt8(y * 7), 90] }, at: file, in: project.package)
        let renderer = try FrameRenderer(project: project, document: document(project, .image(file: file), blur: 0.5), outputSize: size)
        let (counts, otherSizes) = try await offThePool { () -> ([Int], [SIMD2<Int>?]) in
            for n in 0..<10 { _ = try renderer.renderBytes(at: Double(n) / 10) }
            let afterTenFrames = renderer.backgroundImages.blurCount
            // Another size: one more blur, then none for it either.
            let other = BackgroundImage(source: .asset(file), blurSigma: 0.5 * 0.04 * 640)
            let textures = try (0..<3).map { _ in try renderer.backgroundImages.texture(for: other, outputSize: [640, 360]) }
            return ([afterTenFrames, renderer.backgroundImages.blurCount], textures.map { $0.map { SIMD2($0.width, $0.height) } })
        }
        #expect(counts == [1, 2])
        #expect(otherSizes == Array(repeating: SIMD2(640, 360), count: 3))
    }
}

@Test(.enabled(if: MetalCondition.isAvailable || MetalCondition.isRequired))
func missingAssetFallsBackToTheGradientInPreviewAndExport() async throws {
    try await withTemporaryDirectory { dir in
        let project = try backgroundProject(in: dir)
        let deleted = "assets/\(hash).png", unreadable = "assets/\(otherHash).png"
        try put(try plainImage([200, 30, 30]), at: deleted, in: project.package)
        try FileManager.default.removeItem(at: project.package.fileURL(deleted))
        try put(Data("not an image".utf8), at: unreadable, in: project.package)
        let classic = try await render(project, document(project, .tomaClassic))
        // A deleted asset, one that does not decode, and a desktop without a photo.
        for background in [Background.image(file: deleted), .image(file: unreadable), .desktop] {
            let edited = document(project, background, blur: 0.5)
            let preview = PreviewRenderer(renderer: try FrameRenderer(project: project, document: edited, outputSize: size))
            let export = try FrameRenderer(project: project, document: edited, outputSize: size)
            let (previewed, exported) = try await offThePool { (try preview.snapshot(at: 0.5), try exported(export, at: 0.5)) }
            #expect(previewed == classic, "\(background)")
            #expect(exported == classic, "\(background)")
        }
    }
}

@Test(.enabled(if: MetalCondition.isAvailable || MetalCondition.isRequired))
func desktopUsesTheFirstShownScreensPhoto() async throws {
    try await withTemporaryDirectory { dir in
        let project = try backgroundProject(in: dir)
        let first: SIMD3<UInt8> = [40, 160, 90], second: SIMD3<UInt8> = [30, 60, 210]
        try put(try plainImage(first), at: "takes/\(takeID)/wallpapers/display-\(firstDisplay).png", in: project.package)
        try put(try plainImage(second), at: "takes/\(takeID)/wallpapers/display-\(secondDisplay).png", in: project.package)
        // display-2 first, then display-1 from 0.25 s on: the photo stays display-2's.
        var edited = document(project, .desktop, initial: "display-2")
        edited.screens.changes = [
            ScreenChange(id: "p-00000001", take: takeID, t: base.adding(seconds: 0.25), track: "display-1", origin: .user),
        ]
        for (frame, rgb) in [
            (try await render(project, edited), second),
            (try await render(project, document(project, .desktop, initial: "display-1")), first),
        ] {
            for y in stride(from: 0, to: size.y, by: 9) {
                for x in stride(from: 0, to: size.x, by: 8) {
                    #expect(isClose(pixel(frame, width: size.x, x: x, y: y), bgra(rgb), tolerance: 1), "at (\(x), \(y))")
                }
            }
        }
    }
}

@Test(.enabled(if: MetalCondition.isAvailable || MetalCondition.isRequired))
func symlinkedWallpaperIsNotFollowed() async throws {
    try await withTemporaryDirectory { dir in
        let project = try backgroundProject(in: dir)
        let photo = try plainImage([40, 160, 90])
        let outside = dir.appendingPathComponent("photo.png")
        try photo.write(to: outside)
        try FileManager.default.createDirectory(at: project.package.wallpapersDirectory(take: takeID), withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(
            at: project.package.fileURL("takes/\(takeID)/wallpapers/display-\(firstDisplay).png"), withDestinationURL: outside)
        // The same photo as a regular file is drawn.
        try put(photo, at: "takes/\(takeID)/wallpapers/display-\(secondDisplay).png", in: project.package)
        let regular = try await render(project, document(project, .desktop, initial: "display-2"))
        #expect(isClose(pixel(regular, width: size.x, x: 0, y: 0), bgra([40, 160, 90]), tolerance: 1))

        let linked = try await render(project, document(project, .desktop, initial: "display-1"))
        #expect(linked == (try await render(project, document(project, .tomaClassic))))
    }
}

@Test(.enabled(if: MetalCondition.isAvailable || MetalCondition.isRequired))
func blurZeroDrawsTheImageSharp() async throws {
    try await withTemporaryDirectory { dir in
        let project = try backgroundProject(in: dir)
        let file = "assets/\(hash).png"
        // A board of 1 px squares, the output's size.
        try put(
            try encodedImage(width: size.x, height: size.y) { x, y in (x + y) % 2 == 0 ? [255, 255, 255] : [0, 0, 0] },
            at: file, in: project.package)
        let frame = try await render(project, document(project, .image(file: file)))
        for y in 60..<120 {
            for x in 100..<220 {
                let value: UInt8 = (x + y) % 2 == 0 ? 255 : 0
                #expect(pixel(frame, width: size.x, x: x, y: y) == [value, value, value, 255], "at (\(x), \(y))")
            }
        }
    }
}

@Test(.enabled(if: MetalCondition.isAvailable || MetalCondition.isRequired))
func blurredEdgesAreNotDarkened() async throws {
    try await withTemporaryDirectory { dir in
        let project = try backgroundProject(in: dir)
        let file = "assets/\(hash).png"
        let rgb: SIMD3<UInt8> = [200, 120, 40]
        try put(try plainImage(rgb, width: 400, height: 300), at: file, in: project.package)
        let image = BackgroundImage(source: .asset(file), blurSigma: 1 * 0.04 * Double(size.x))
        let device = try #require(MTLCreateSystemDefaultDevice())
        let library = try Compositor(device: device).library
        var blurs: [BackgroundImages.Blur] = [.shader]
        if MPSSupportsMTLDevice(device) { blurs.append(.performanceShaders) }
        for blur in blurs {
            let package = project.package
            let (blurCount, drawn) = try await offThePool { () -> (Int, [UInt8]?) in
                let images = try BackgroundImages(device: device, library: library, package: package, blur: blur)
                let texture = try images.texture(for: image, outputSize: size)
                return (images.blurCount, texture.map(bytes(of:)))
            }
            #expect(blurCount == 1, "\(blur)")
            let blurred = try #require(drawn, "\(blur)")
            let center = pixel(blurred, width: size.x, x: size.x / 2, y: size.y / 2)
            #expect(isClose(center, SIMD4(Float(rgb.x), Float(rgb.y), Float(rgb.z), 255), tolerance: 1), "\(blur): \(center)")
            for corner in corners(of: size) {
                let p = pixel(blurred, width: size.x, x: corner.x, y: corner.y)
                #expect(isClose(p, SIMD4<Float>(center), tolerance: 1), "\(blur) at \(corner): \(p)")
            }
        }
        // And in a frame, with the renderer's own blur.
        let frame = try await render(project, document(project, .image(file: file), blur: 1))
        for corner in corners(of: size) {
            #expect(isClose(pixel(frame, width: size.x, x: corner.x, y: corner.y), bgra(rgb), tolerance: 1), "at \(corner)")
        }
    }
}

@Test(.enabled(if: MetalCondition.isAvailable || MetalCondition.isRequired))
func previewAndExportShareTheDecodedImage() async throws {
    try await withTemporaryDirectory { dir in
        let project = try backgroundProject(in: dir)
        let file = "assets/\(hash).jpg"
        try put(
            try encodedImage(width: 640, height: 360, as: "public.jpeg") { x, y in [UInt8(x % 256), UInt8(y % 256), UInt8((x + y) % 256)] },
            at: file, in: project.package)
        let edited = document(project, .image(file: file), blur: 0.3)
        let preview = PreviewRenderer(renderer: try FrameRenderer(project: project, document: edited, outputSize: size))
        let export = try FrameRenderer(project: project, document: edited, outputSize: size)
        // Both at once, as when an export runs with the editor open.
        async let previewed = offThePool { try preview.snapshot(at: 0.5) }
        async let exportedFrame = offThePool { try exported(export, at: 0.5) }
        let frames = try await (previewed, exportedFrame)
        #expect(BackgroundImages.decodeCount(of: .asset(file), in: project.package) == 1)
        #expect(frames.0 == frames.1)
        withExtendedLifetime((preview, export)) {}
    }
}

@Test(.enabled(if: MetalCondition.isAvailable || MetalCondition.isRequired))
func blurFollowsSigmaInOutputPixels() async throws {
    try await withTemporaryDirectory { dir in
        let project = try backgroundProject(in: dir)
        let file = "assets/\(hash).png"
        // The edge at column 320 of 640, so at the middle of the stage at either size, whole texels apart.
        try put(try hardEdge(width: 640, height: 360), at: file, in: project.package)
        let device = try #require(MTLCreateSystemDefaultDevice())
        // Blur 0.5: σ = 0.5 × 0.04 × W, 6.4 output pixels at 320 wide and 12.8 at 640.
        for outputSize in [SIMD2(320, 180), SIMD2(640, 360)] {
            let sigma = 0.5 * 0.04 * Double(outputSize.x)
            let edge = Double(outputSize.x) / 2
            var rows: [BackgroundImages.Blur: [Int]] = [:]
            for blur in blurs(on: device) {
                let drawn = try await prepared(
                    BackgroundImage(source: .asset(file), blurSigma: sigma), outputSize: outputSize, blur: blur, in: project.package,
                    device: device)
                let row = redRow(try #require(drawn), width: outputSize.x, y: outputSize.y / 2)
                rows[blur] = row
                // The profile across the edge is the Gaussian's: within ±3 at 0, ±½, ±1, ±2 and ±3 σ.
                for k in [-3.0, -2, -1, -0.5, 0, 0.5, 1, 2, 3] {
                    let x = Int((edge + k * sigma).rounded(.down))
                    let expected = blurredEdge(at: x, edge: edge, sigma: sigma)
                    #expect(abs(Double(row[x]) - expected) <= 3, "\(blur) at \(outputSize.x) wide, x \(x): \(row[x]) for \(expected)")
                }
            }
            // And the two blurs agree, pixel for pixel, within ±2.
            if let shader = rows[.shader], let performanceShaders = rows[.performanceShaders] {
                let largest = zip(shader, performanceShaders).map { abs($0 - $1) }.max() ?? 0
                #expect(largest <= 2, "at \(outputSize.x) wide: \(largest)")
            }
        }
    }
}

@Test func shaderBlurIsBounded() {
    // Up to 16 texels the stage itself is blurred; past it, a level reduced by the smallest power of two that brings σ
    // within 16, so a pass reads at most 2 × ⌈3 × 16⌉ + 1 taps.
    #expect(BackgroundImages.shaderBlurLevel(sigma: 16, size: [3840, 2160]) == 0)
    #expect(BackgroundImages.shaderBlurLevel(sigma: 16.1, size: [3840, 2160]) == 1)
    #expect(BackgroundImages.shaderBlurLevel(sigma: 51.2, size: [1280, 720]) == 2)
    // 4K at blur 1: σ ≈ 154 is blurred at level 4, σ 9.6, 59 taps a pass instead of 925.
    #expect(BackgroundImages.shaderBlurLevel(sigma: 0.04 * 3840, size: [3840, 2160]) == 4)
    // Never past the last level.
    #expect(BackgroundImages.shaderBlurLevel(sigma: 10_000, size: [64, 36]) == 6)
}

@Test(.enabled(if: MetalCondition.isAvailable || MetalCondition.isRequired))
func shaderBlurMatchesPerformanceShaders() async throws {
    try await withTemporaryDirectory { dir in
        let project = try backgroundProject(in: dir)
        let file = "assets/\(hash).png"
        let outputSize = SIMD2(1280, 720)
        try put(try hardEdge(width: outputSize.x, height: outputSize.y), at: file, in: project.package)
        let device = try #require(MTLCreateSystemDefaultDevice())
        // Blur 1 at 1280 wide: σ = 51.2, which the shader blurs at level 2 (σ 12.8).
        let image = BackgroundImage(source: .asset(file), blurSigma: 0.04 * Double(outputSize.x))
        #expect(BackgroundImages.shaderBlurLevel(sigma: image.blurSigma, size: outputSize) == 2)
        var rows: [BackgroundImages.Blur: [Int]] = [:]
        for blur in blurs(on: device) {
            let drawn = try #require(try await prepared(image, outputSize: outputSize, blur: blur, in: project.package, device: device))
            let row = redRow(drawn, width: outputSize.x, y: outputSize.y / 2)
            rows[blur] = row
            // The reduction leaves the Gaussian's profile within ±3.
            for x in stride(from: 0, to: outputSize.x, by: 8) {
                let expected = blurredEdge(at: x, edge: Double(outputSize.x) / 2, sigma: image.blurSigma)
                #expect(abs(Double(row[x]) - expected) <= 3, "\(blur) at x \(x): \(row[x]) for \(expected)")
            }
        }
        // The reduced shader blur is within ±2 of Metal Performance Shaders' at every pixel of the row.
        if let shader = rows[.shader], let performanceShaders = rows[.performanceShaders] {
            let largest = zip(shader, performanceShaders).map { abs($0 - $1) }.max() ?? 0
            #expect(largest <= 2, "\(largest)")
        }
    }
}

@Test(.enabled(if: MetalCondition.isAvailable || MetalCondition.isRequired))
func wallpaperWithoutBlurIsTheDirectDraw() async throws {
    try await withTemporaryDirectory { dir in
        let project = try backgroundProject(in: dir)
        let aurora = try #require(WallpaperPreset.preset(id: "aurora-1"))
        let sharpRenderer = try FrameRenderer(project: project, document: document(project, .wallpaper("aurora-1")), outputSize: size)
        let blurredRenderer = try FrameRenderer(
            project: project, document: document(project, .wallpaper("aurora-1"), blur: 0.5), outputSize: size)
        let device = sharpRenderer.device
        let compositor = try Compositor(device: device)
        let (sharp, sharpBlurs, blurred, blurredBlurs, direct) = try await offThePool {
            () -> ([UInt8], Int, [[UInt8]], Int, [UInt8]) in
            let sharp = try sharpRenderer.renderBytes(at: 0.5)
            let blurred = try [0.1, 0.5, 0.9].map { try blurredRenderer.renderBytes(at: $0) }
            let direct = try sharpRenderer.renderOffscreen { target, commandBuffer in
                compositor.encodeWallpaper(aurora, tileSize: nil, into: target, commandBuffer: commandBuffer)
            }
            return (sharp, sharpRenderer.backgroundImages.blurCount, blurred, blurredRenderer.backgroundImages.blurCount, direct)
        }
        // Blur 0 is today's direct draw, byte for byte, without a texture.
        #expect(sharp == direct)
        #expect(sharpBlurs == 0)
        // With a blur it is another image, blurred once for every frame.
        #expect(blurred[1] != sharp)
        #expect(blurred.allSatisfy { $0 == blurred[0] })
        #expect(blurredBlurs == 1)
    }
}

@Test(.enabled(if: MetalCondition.isAvailable || MetalCondition.isRequired))
func blurredWallpaperIsSmoothAndKeepsItsGrain() async throws {
    let device = try #require(MTLCreateSystemDefaultDevice())
    let compositor = try Compositor(device: device)
    let library = compositor.library
    // Black on the left, white on the right, points far off the stage: a mesh edge about 2 px wide at column 160.
    let edge = WallpaperPreset(id: "test-1", points: [[-2, 0.5], [3, 0.5]], colors: [[0, 0, 0, 1], [1, 1, 1, 1]])
    let sigma = 1 * 0.04 * Double(size.x)
    let (sharp, blurred) = try await withTemporaryDirectory { dir in
        let package = ProjectPackage(url: dir.appendingPathComponent("Demo.toma", isDirectory: true))
        return try await offThePool { () -> ([UInt8], [UInt8]) in
            let images = try BackgroundImages(device: device, library: library, package: package)
            let mesh = try images.texture(forWallpaper: edge, blurSigma: sigma, outputSize: size)
            let cursor = try CursorSprite.makeTexture(device: device)
            let style = StyleV0()
            func frame(_ background: BackgroundLayer) -> RenderFrame {
                RenderFrame(
                    outputSize: size, gradientStart: style.gradientStart, gradientEnd: style.gradientEnd,
                    gradientAngleDegrees: style.gradientAngleDegrees, background: background)
            }
            let renderer = { (background: BackgroundLayer, image: (any MTLTexture)?) throws -> [UInt8] in
                let descriptor = MTLTextureDescriptor.texture2DDescriptor(
                    pixelFormat: .bgra8Unorm, width: size.x, height: size.y, mipmapped: false)
                descriptor.usage = [.renderTarget, .shaderRead]
                descriptor.storageMode = .shared
                let target = device.makeTexture(descriptor: descriptor)!
                let commandBuffer = device.makeCommandQueue()!.makeCommandBuffer()!
                try compositor.encode(
                    frame(background), screen: nil, camera: nil, cursor: cursor, backgroundImage: image, into: target,
                    commandBuffer: commandBuffer)
                commandBuffer.commit()
                commandBuffer.waitUntilCompleted()
                var bytes = [UInt8](repeating: 0, count: size.x * size.y * 4)
                target.getBytes(&bytes, bytesPerRow: size.x * 4, from: MTLRegionMake2D(0, 0, size.x, size.y), mipmapLevel: 0)
                return bytes
            }
            return (try renderer(.wallpaper(edge), nil), try renderer(.wallpaper(edge, blurSigma: sigma), mesh))
        }
    }
    // The mean of each column over every row, which averages the grain out.
    func profile(_ bytes: [UInt8]) -> [Double] {
        (0..<size.x).map { x in Double((0..<size.y).map { Int(bytes[($0 * size.x + x) * 4]) }.reduce(0, +)) / Double(size.y) }
    }
    let sharpProfile = profile(sharp), blurredProfile = profile(blurred)
    // The sharp edge jumps (its steepest step is 255 / (4 × its 1.9 px logistic scale), about 33); the blurred one is a
    // smooth band of the Gaussian's width, rising a little at every column (at most 255 / (σ √2π), about 8).
    let band = 120..<200
    let steps = band.dropLast().map { blurredProfile[$0 + 1] - blurredProfile[$0] }
    #expect(steps.allSatisfy { $0 > -1 && $0 <= 9 }, "\(steps)")
    #expect(band.dropLast().map { sharpProfile[$0 + 1] - sharpProfile[$0] }.max()! > 25)
    for k in [-1.0, 1] {
        let x = Int((160 + k * sigma).rounded(.down))
        let expected = blurredEdge(at: x, edge: 160, sigma: sigma)
        #expect(abs(blurredProfile[x] - expected) <= 6, "at \(x): \(blurredProfile[x]) for \(expected)")
        #expect(abs(sharpProfile[x] - expected) > 30, "at \(x)")
    }
    // The grain is not blurred: where the mesh is flat, the blurred wallpaper is the sharp one's pixels, grain and all.
    for y in 0..<size.y {
        for x in Array(0..<100) + Array(220..<size.x) {
            #expect(pixel(blurred, width: size.x, x: x, y: y) == pixel(sharp, width: size.x, x: x, y: y), "at (\(x), \(y))")
        }
    }
    #expect((0..<100).map { pixel(blurred, width: size.x, x: $0, y: 90).x }.max()! >= 4)
}
