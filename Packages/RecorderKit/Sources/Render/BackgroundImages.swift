// SPDX-License-Identifier: GPL-3.0-or-later
import CoreGraphics
import Metal
import MetalPerformanceShaders
import ProjectFormat
import Synchronization

/// The textures of one renderer's background images (`BackgroundLayer.image`) and blurred wallpapers: for each frame, a
/// texture of the output's size in which the image already covers the stage (aspect fill, centred), or the wallpaper's
/// mesh gradient is drawn over it without its grain, already blurred, made once per (background, output size, σ) and
/// reused while the frames ask for the same: the textures of the last two sizes asked for are kept, so a preview that
/// goes from one size to another and back (`PreviewQuality`, a pause at the export's size) does not blur again.
///
/// - The image is read only through the package's safe readers (`ProjectPackage.asset(_:)`, `wallpaper(take:displayID:)`)
///   and taken from the process's cache (`BackgroundImageCache`), where it is decoded once while any renderer holds
///   it: the preview's and the export's renderers draw the same pixels even where ImageIO would decode a JPEG or a HEIC
///   differently twice (in hardware or in software). A missing or unreadable image gives no texture, and every
///   renderer the classic gradient for it; that, and an image whose texture Metal could not make, are kept until
///   `forgetUnreadable()` (a new scene), so no frame reads or decodes it again before then.
/// - The image is uploaded as the bytes of a fixed sRGB `CGContext` to an `.rgba8Unorm` texture, never an `_srgb` one,
///   which would linearize them when sampled (and the compositor writes the bytes as they are), with mipmaps so an
///   image larger than the stage is reduced to it without aliasing.
/// - The blur is `MPSImageGaussianBlur` with `edgeMode = .clamp`: the default `.zero` brings black in from outside the
///   image and, with σ of hundreds of pixels, darkens the stage's whole border. Where Metal Performance Shaders does
///   not support the device (`MPSSupportsMTLDevice`: a paravirtualized one in CI), the shaders' own separable Gaussian
///   (`blurFragment`), sampling with `clamp_to_edge`, on a reduced copy of the stage past `shaderBlurMaxSigma`.
///
/// Not thread-safe: `FrameRenderer` uses it with its lock held. What it draws runs on a command queue of its own and is
/// waited for, so the texture it returns is complete for a frame drawn on any queue.
final class BackgroundImages {
    /// How an image is blurred.
    enum Blur: Sendable {
        /// `MPSImageGaussianBlur`.
        case performanceShaders
        /// `blurFragment`, in two passes.
        case shader
    }

    /// The blur used: `.performanceShaders` where the device supports it, unless the initializer was told otherwise.
    let blur: Blur
    /// How many images have been blurred, for tests.
    private(set) var blurCount = 0

    private let device: any MTLDevice
    private let library: any MTLLibrary
    private let package: ProjectPackage
    private let commandQueue: any MTLCommandQueue
    /// Made the first time an image is drawn: a renderer whose frames show none never builds them.
    private var pipelines: Pipelines?
    /// The image last asked for: the cache's entry, held so another renderer of it shares the decoded pixels, and its
    /// texture (`nil` when it is missing or unreadable), or why Metal could not make it.
    private var source: (
        source: BackgroundImage.Source, entry: BackgroundImageCache.Entry, texture: Result<(any MTLTexture)?, any Error>
    )?
    /// The textures last made for frames, and what they are of: the latest last, one for each of the last two sizes.
    private var prepared: [(content: Content, outputSize: SIMD2<Int>, texture: any MTLTexture)] = []
    /// How many sizes `prepared` keeps.
    private static let keptSizes = 2

    /// What a texture for frames shows.
    private enum Content: Equatable {
        case image(BackgroundImage)
        case wallpaper(WallpaperPreset, blurSigma: Double)
    }

    private struct Pipelines {
        let cover: any MTLRenderPipelineState
        let wallpaperMesh: any MTLRenderPipelineState
        /// The shader blur's passes: across, into a half-float texture, then down, into the result.
        let blurAcross: (any MTLRenderPipelineState)?
        let blurDown: (any MTLRenderPipelineState)?
        let mipSampler: any MTLSamplerState
    }

    /// The largest σ, in texels, the shader blur works at. Past it, it blurs a mipmap level of the stage, reduced by the
    /// smallest power of two that brings σ within it, and scales the result back up: a pass then reads at most
    /// 2 × ⌈3 × 16⌉ + 1 = 97 taps a pixel, however large σ is, where a 4K stage at σ ≈ 154 would read 925. A blur that
    /// wide has nothing finer than the reduction to lose (`shaderBlurMatchesPerformanceShaders`).
    static let shaderBlurMaxSigma = 16.0

    /// - Parameters:
    ///   - library: the compiled `ShaderSource` (`Compositor.library`).
    ///   - blur: `nil` for Metal Performance Shaders where `MPSSupportsMTLDevice(device)`, the shader blur otherwise.
    /// - Throws: `RenderError.metalResourceUnavailable` without a command queue.
    init(device: any MTLDevice, library: any MTLLibrary, package: ProjectPackage, blur: Blur? = nil) throws {
        guard let commandQueue = device.makeCommandQueue() else {
            throw RenderError.metalResourceUnavailable("background command queue")
        }
        self.device = device
        self.library = library
        self.package = package
        self.commandQueue = commandQueue
        self.blur = blur ?? (MPSSupportsMTLDevice(device) ? .performanceShaders : .shader)
    }

    /// How many times the process has decoded the image of `source` in `package` since the cache last had nothing of it,
    /// for tests: once while renderers share it.
    static func decodeCount(of source: BackgroundImage.Source, in package: ProjectPackage) -> Int {
        BackgroundImageCache.shared.decodeCount(of: BackgroundImageCache.Key(source, in: package))
    }

    /// The texture of `background` for frames `outputSize` big (`.rgba8Unorm`, that size), or `nil` when its image is
    /// missing or cannot be read. Made the first time it is asked for and kept until another background or size is.
    /// - Throws: `RenderError` if Metal cannot make what it needs or the GPU fails.
    func texture(for background: BackgroundImage, outputSize: SIMD2<Int>) throws -> (any MTLTexture)? {
        let content = Content.image(background)
        if let texture = preparedTexture(of: content, outputSize: outputSize) { return texture }
        guard let image = try sourceTexture(of: background.source) else { return nil }
        return try prepare(content, outputSize: outputSize, blurredBy: background.blurSigma) { encoder, pipelines in
            // The image covers the stage: aspect fill, centred.
            let stage = Rect(x: 0, y: 0, width: Double(outputSize.x), height: Double(outputSize.y))
            let fill = Compositor.aspectFill(SIMD2(Double(image.width), Double(image.height)), in: stage)
            var uniforms = CoverUniforms(targetSize: SIMD2<Float>(outputSize), uvOrigin: fill.origin, uvSize: fill.size, padding: .zero)
            encoder.setRenderPipelineState(pipelines.cover)
            encoder.setFragmentBytes(&uniforms, length: MemoryLayout<CoverUniforms>.stride, index: 0)
            encoder.setFragmentTexture(image, index: 0)
            encoder.setFragmentSamplerState(pipelines.mipSampler, index: 0)
        }
    }

    /// The mesh gradient of `preset` over a stage `outputSize` big, without its grain, blurred by `blurSigma` output
    /// pixels (`.rgba8Unorm`, that size): what `Compositor` adds the grain to for a blurred wallpaper. Made the first time
    /// it is asked for and kept until another background or size is.
    /// - Throws: `RenderError` if Metal cannot make what it needs or the GPU fails.
    func texture(forWallpaper preset: WallpaperPreset, blurSigma: Double, outputSize: SIMD2<Int>) throws -> any MTLTexture {
        let content = Content.wallpaper(preset, blurSigma: blurSigma)
        if let texture = preparedTexture(of: content, outputSize: outputSize) { return texture }
        // No image is shown: its memory goes.
        source = nil
        return try prepare(content, outputSize: outputSize, blurredBy: blurSigma) { encoder, pipelines in
            var uniforms = WallpaperUniforms(
                stageSize: SIMD2<Float>(outputSize), count: UInt32(preset.points.count), padding: 0)
            encoder.setRenderPipelineState(pipelines.wallpaperMesh)
            encoder.setFragmentBytes(&uniforms, length: MemoryLayout<WallpaperUniforms>.stride, index: 0)
            preset.points.withUnsafeBytes { encoder.setFragmentBytes($0.baseAddress!, length: $0.count, index: 1) }
            preset.colors.withUnsafeBytes { encoder.setFragmentBytes($0.baseAddress!, length: $0.count, index: 2) }
        }
    }

    /// Lets go of an image that is missing or cannot be read, or whose texture could not be made, so the next frame that
    /// shows it looks for it again: for a new scene (`FrameRenderer.setScene(_:)`), after which a file put back or
    /// imported again is drawn.
    func forgetUnreadable() {
        guard let current = source else { return }
        if case .success(.some) = current.texture { return }
        source = nil
    }

    /// The texture kept for `content` at `outputSize`, now the latest; `nil` if none is.
    private func preparedTexture(of content: Content, outputSize: SIMD2<Int>) -> (any MTLTexture)? {
        guard let index = prepared.firstIndex(where: { $0.content == content && $0.outputSize == outputSize }) else { return nil }
        let found = prepared.remove(at: index)
        prepared.append(found)
        return found.texture
    }

    /// The texture of the image of `source`, uploaded once while it is the one asked for; `nil` when it is missing or
    /// cannot be read, which is kept too, so a missing file is not looked for again on every frame, as is the error of a
    /// texture Metal could not make (thrown again without decoding or uploading it again), until `forgetUnreadable()`.
    private func sourceTexture(of source: BackgroundImage.Source) throws -> (any MTLTexture)? {
        if let current = self.source, current.source == source { return try current.texture.get() }
        // The previous image's memory goes before the next one is decoded.
        self.source = nil
        prepared.removeAll { if case .image = $0.content { true } else { false } }
        let entry = BackgroundImageCache.shared.entry(for: source, in: package)
        let texture = Result { try entry.image().map(upload) }
        self.source = (source, entry, texture)
        return try texture.get()
    }

    /// `image` as an `.rgba8Unorm` texture with mipmaps.
    private func upload(_ image: DecodedBackgroundImage) throws -> any MTLTexture {
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .rgba8Unorm, width: image.width, height: image.height, mipmapped: true)
        descriptor.usage = .shaderRead
        descriptor.storageMode = .shared
        guard let texture = device.makeTexture(descriptor: descriptor) else {
            throw RenderError.metalResourceUnavailable("background image texture")
        }
        image.bytes.withUnsafeBytes { bytes in
            texture.replace(
                region: MTLRegionMake2D(0, 0, image.width, image.height), mipmapLevel: 0, withBytes: bytes.baseAddress!,
                bytesPerRow: image.width * 4)
        }
        try run { commandBuffer in
            guard let blit = commandBuffer.makeBlitCommandEncoder() else {
                throw RenderError.metalResourceUnavailable("background mipmap encoder")
            }
            blit.generateMipmaps(for: texture)
            blit.endEncoding()
        }
        return texture
    }

    /// A texture `outputSize` big that `setUp` fills (it sets a pipeline drawing `gradientVertex`, and its inputs, for one
    /// triangle over the target), blurred by `sigma` output pixels: none at 0 or a value that is not a number, at most
    /// the output's longer side, past which nothing changes. It is kept as `prepared`, for `content`.
    private func prepare(
        _ content: Content, outputSize: SIMD2<Int>, blurredBy sigma: Double,
        setUp: (any MTLRenderCommandEncoder, Pipelines) -> Void
    ) throws -> any MTLTexture {
        let pipelines = try self.pipelines ?? makePipelines()
        self.pipelines = pipelines
        let blurs = sigma.isFinite && sigma > 0
        let longerSide = Double(max(outputSize.x, outputSize.y))
        let sigma = min(sigma, longerSide)
        // The shader blur's mipmap level: 0, the stage itself, up to `shaderBlurMaxSigma`.
        let level = blurs && blur == .shader ? Self.shaderBlurLevel(sigma: sigma, size: outputSize) : 0
        let covered = try makeTexture(.rgba8Unorm, size: outputSize, storage: .shared, mipmapped: level > 0)
        let result = blurs ? try makeTexture(.rgba8Unorm, size: outputSize, storage: .shared) : covered
        try run { commandBuffer in
            let encoder = try renderPass(into: covered, commandBuffer: commandBuffer)
            setUp(encoder, pipelines)
            encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
            encoder.endEncoding()
            guard blurs else { return }
            switch blur {
            case .performanceShaders:
                let kernel = MPSImageGaussianBlur(device: device, sigma: Float(sigma))
                kernel.edgeMode = .clamp
                kernel.encode(commandBuffer: commandBuffer, sourceTexture: covered, destinationTexture: result)
            case .shader:
                try shaderBlur(covered, into: result, sigma: sigma, level: level, pipelines: pipelines, commandBuffer)
            }
        }
        if blurs { blurCount += 1 }
        // One texture for each size (a blur's σ follows the size, so the same background is another content at another
        // size): this one replaces that size's, and a third size's makes the oldest go.
        prepared.removeAll { $0.outputSize == outputSize }
        if prepared.count >= Self.keptSizes { prepared.removeFirst() }
        prepared.append((content, outputSize, result))
        return result
    }

    /// The mipmap level of a stage `size` big that the shader blur works on for `sigma` texels of the stage: the first at
    /// which σ / 2^level is at most `shaderBlurMaxSigma`, never past the stage's last level.
    static func shaderBlurLevel(sigma: Double, size: SIMD2<Int>) -> Int {
        let lastLevel = Int(log2(Double(max(size.x, size.y))).rounded(.down))
        var level = 0
        while level < lastLevel, sigma / Double(1 << level) > shaderBlurMaxSigma { level += 1 }
        return level
    }

    /// The shader blur of `source` (the stage, with mipmaps when `level` > 0) into `target`, the same size: at `level` 0
    /// in two passes over it; otherwise in two passes over a copy of that mipmap level, with σ reduced as much, whose
    /// result is scaled back up into `target` (bilinear).
    private func shaderBlur(
        _ source: any MTLTexture, into target: any MTLTexture, sigma: Double, level: Int, pipelines: Pipelines,
        _ commandBuffer: any MTLCommandBuffer
    ) throws {
        guard let blurAcross = pipelines.blurAcross, let blurDown = pipelines.blurDown else {
            preconditionFailure("BackgroundImages: the shader blur's pipelines are made with it")
        }
        let size = SIMD2(max(1, source.width >> level), max(1, source.height >> level))
        let reducedSigma = sigma / Double(1 << level)
        let radius = Int32(min((3 * reducedSigma).rounded(.up), Double(max(size.x, size.y))))
        let across = try makeTexture(.rgba16Float, size: size, storage: .private)
        guard level > 0 else {
            try blurPass(source, into: across, direction: [1, 0], sigma: reducedSigma, radius: radius, pipeline: blurAcross, commandBuffer)
            try blurPass(across, into: target, direction: [0, 1], sigma: reducedSigma, radius: radius, pipeline: blurDown, commandBuffer)
            return
        }
        let reduced = try makeTexture(.rgba8Unorm, size: size, storage: .private)
        let blurred = try makeTexture(.rgba8Unorm, size: size, storage: .private)
        guard let blit = commandBuffer.makeBlitCommandEncoder() else {
            throw RenderError.metalResourceUnavailable("background blur reduction")
        }
        blit.generateMipmaps(for: source)
        blit.copy(
            from: source, sourceSlice: 0, sourceLevel: level, sourceOrigin: MTLOrigin(x: 0, y: 0, z: 0),
            sourceSize: MTLSize(width: size.x, height: size.y, depth: 1), to: reduced, destinationSlice: 0, destinationLevel: 0,
            destinationOrigin: MTLOrigin(x: 0, y: 0, z: 0))
        blit.endEncoding()
        try blurPass(reduced, into: across, direction: [1, 0], sigma: reducedSigma, radius: radius, pipeline: blurAcross, commandBuffer)
        try blurPass(across, into: blurred, direction: [0, 1], sigma: reducedSigma, radius: radius, pipeline: blurDown, commandBuffer)
        // Back up to the stage's size.
        var uniforms = CoverUniforms(
            targetSize: SIMD2<Float>(Float(target.width), Float(target.height)), uvOrigin: .zero, uvSize: .one, padding: .zero)
        let encoder = try renderPass(into: target, commandBuffer: commandBuffer)
        encoder.setRenderPipelineState(pipelines.cover)
        encoder.setFragmentBytes(&uniforms, length: MemoryLayout<CoverUniforms>.stride, index: 0)
        encoder.setFragmentTexture(blurred, index: 0)
        encoder.setFragmentSamplerState(pipelines.mipSampler, index: 0)
        encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
        encoder.endEncoding()
    }

    /// One pass of the shader blur from `source` into `target`, both the same size.
    private func blurPass(
        _ source: any MTLTexture, into target: any MTLTexture, direction: SIMD2<Float>, sigma: Double, radius: Int32,
        pipeline: any MTLRenderPipelineState, _ commandBuffer: any MTLCommandBuffer
    ) throws {
        var uniforms = BlurUniforms(direction: direction, sigma: Float(sigma), radius: radius)
        let encoder = try renderPass(into: target, commandBuffer: commandBuffer)
        encoder.setRenderPipelineState(pipeline)
        encoder.setFragmentBytes(&uniforms, length: MemoryLayout<BlurUniforms>.stride, index: 0)
        encoder.setFragmentTexture(source, index: 0)
        encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
        encoder.endEncoding()
    }

    private func makePipelines() throws -> Pipelines {
        func function(_ name: String) throws -> any MTLFunction {
            guard let function = library.makeFunction(name: name) else { throw RenderError.missingShaderFunction(name) }
            return function
        }
        // Each draws one triangle over the whole target.
        func pipeline(_ fragment: String, format: MTLPixelFormat) throws -> any MTLRenderPipelineState {
            let descriptor = MTLRenderPipelineDescriptor()
            descriptor.vertexFunction = try function("gradientVertex")
            descriptor.fragmentFunction = try function(fragment)
            descriptor.colorAttachments[0].pixelFormat = format
            return try device.makeRenderPipelineState(descriptor: descriptor)
        }
        let sampler = MTLSamplerDescriptor()
        sampler.minFilter = .linear
        sampler.magFilter = .linear
        sampler.mipFilter = .linear
        sampler.sAddressMode = .clampToEdge
        sampler.tAddressMode = .clampToEdge
        guard let mipSampler = device.makeSamplerState(descriptor: sampler) else {
            throw RenderError.metalResourceUnavailable("background image sampler")
        }
        let shaderBlur = blur == .shader
        return Pipelines(
            cover: try pipeline("coverFragment", format: .rgba8Unorm),
            wallpaperMesh: try pipeline("wallpaperMeshFragment", format: .rgba8Unorm),
            blurAcross: shaderBlur ? try pipeline("blurFragment", format: .rgba16Float) : nil,
            blurDown: shaderBlur ? try pipeline("blurFragment", format: .rgba8Unorm) : nil,
            mipSampler: mipSampler)
    }

    private func makeTexture(
        _ format: MTLPixelFormat, size: SIMD2<Int>, storage: MTLStorageMode, mipmapped: Bool = false
    ) throws -> any MTLTexture {
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: format, width: size.x, height: size.y, mipmapped: mipmapped)
        descriptor.usage = [.renderTarget, .shaderRead, .shaderWrite]
        descriptor.storageMode = storage
        guard let texture = device.makeTexture(descriptor: descriptor) else {
            throw RenderError.metalResourceUnavailable("background texture")
        }
        return texture
    }

    /// A render pass that writes every pixel of `target`: what was there before is not loaded.
    private func renderPass(into target: any MTLTexture, commandBuffer: any MTLCommandBuffer) throws -> any MTLRenderCommandEncoder {
        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = target
        pass.colorAttachments[0].loadAction = .dontCare
        pass.colorAttachments[0].storeAction = .store
        guard let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: pass) else {
            throw RenderError.metalResourceUnavailable("background render pass")
        }
        encoder.label = "BackgroundImages"
        return encoder
    }

    /// Encodes with `body` into a command buffer of this object's queue, commits it and waits for the GPU.
    private func run(_ body: (any MTLCommandBuffer) throws -> Void) throws {
        guard let commandBuffer = commandQueue.makeCommandBuffer() else {
            throw RenderError.metalResourceUnavailable("background command buffer")
        }
        commandBuffer.label = "BackgroundImages"
        try body(commandBuffer)
        commandBuffer.commit()
        commandBuffer.waitUntilCompleted()
        guard commandBuffer.status == .completed else {
            throw RenderError.gpuFailed(commandBuffer.error.map { String(describing: $0) } ?? "status \(commandBuffer.status.rawValue)")
        }
    }
}

/// `CoverUniforms` in `ShaderSource.metal`: 32 bytes.
private struct CoverUniforms {
    var targetSize: SIMD2<Float>
    var uvOrigin: SIMD2<Float>
    var uvSize: SIMD2<Float>
    var padding: SIMD2<Float>
}

/// `BlurUniforms` in `ShaderSource.metal`: 16 bytes.
private struct BlurUniforms {
    var direction: SIMD2<Float>
    var sigma: Float
    var radius: Int32
}

/// A background image as every renderer uploads it: `width × height` pixels of 8-bit RGBA, rows from the top, in sRGB,
/// opaque (what is transparent in the file is over black, as the frame is cleared).
struct DecodedBackgroundImage: Sendable {
    let width: Int
    let height: Int
    let bytes: [UInt8]
}

/// The process's decoded background images, by package and image: each is decoded once while some renderer holds its
/// entry, and every renderer that asks for it meanwhile gets the same pixels, so the preview and an export of a project
/// draw the same image. An entry nobody holds goes, with its memory; asked for again, the image is decoded again.
///
/// The key is the package's path with the asset's file, or the take and the display: take IDs repeat from project to
/// project, and a frame is a function of its own package alone, never of what another project's file of the same name
/// held. The size the image is decoded to is the one `ProjectPackage` decodes every asset and photo to.
final class BackgroundImageCache: Sendable {
    static let shared = BackgroundImageCache()

    struct Key: Hashable, Sendable {
        enum Source: Hashable, Sendable {
            case asset(String)
            case desktop(take: String, displayID: UInt32)
        }

        let package: String
        let source: Source

        init(_ source: BackgroundImage.Source, in package: ProjectPackage) {
            self.package = package.url.standardizedFileURL.path
            switch source {
            case let .asset(file): self.source = .asset(file)
            case let .desktop(take, displayID): self.source = .desktop(take: take, displayID: displayID)
            }
        }
    }

    /// One image of the cache: decoded the first time it is asked for, by whoever asks first while the others wait.
    final class Entry: Sendable {
        private enum State {
            case pending
            /// `nil` when the image is missing or cannot be read.
            case decoded(DecodedBackgroundImage?)
        }

        let key: Key
        private let package: ProjectPackage
        private let cache: BackgroundImageCache
        private let state = Mutex(State.pending)

        fileprivate init(key: Key, package: ProjectPackage, cache: BackgroundImageCache) {
            self.key = key
            self.package = package
            self.cache = cache
        }

        /// The image, decoded the first time; `nil` when it is missing or cannot be read.
        func image() -> DecodedBackgroundImage? {
            state.withLock { state in
                if case let .decoded(image) = state { return image }
                let image = BackgroundImageCache.decode(key.source, in: package)
                cache.noteDecode(of: key)
                state = .decoded(image)
                return image
            }
        }
    }

    /// An entry, held weakly, and how many times its key has been decoded since the slot was made.
    private struct Slot {
        weak var entry: Entry?
        var decodes = 0
    }

    private let slots = Mutex<[Key: Slot]>([:])

    /// The entry of the image of `source` in `package`: the one some renderer holds, or a new one, not decoded yet.
    func entry(for source: BackgroundImage.Source, in package: ProjectPackage) -> Entry {
        let key = Key(source, in: package)
        return slots.withLock { slots in
            if let entry = slots[key]?.entry { return entry }
            // The other images nobody holds any more leave, with their counts.
            slots = slots.filter { $0.key == key || $0.value.entry != nil }
            let entry = Entry(key: key, package: package, cache: self)
            slots[key, default: Slot()].entry = entry
            return entry
        }
    }

    func decodeCount(of key: Key) -> Int {
        slots.withLock { $0[key]?.decodes ?? 0 }
    }

    private func noteDecode(of key: Key) {
        slots.withLock { $0[key, default: Slot()].decodes += 1 }
    }

    /// The image of `source` through the package's safe reader, drawn into an sRGB context of 8-bit RGBA over opaque
    /// black; `nil` when the reader gives none (missing, a link, not a regular file, too large, not a format allowed,
    /// not decodable) or the context cannot be made.
    private static func decode(_ source: Key.Source, in package: ProjectPackage) -> DecodedBackgroundImage? {
        let image: CGImage?
        switch source {
        case let .asset(file): image = package.asset(file)
        case let .desktop(take, displayID): image = package.wallpaper(take: take, displayID: displayID)
        }
        guard let image, let space = CGColorSpace(name: CGColorSpace.sRGB) else { return nil }
        let width = image.width, height = image.height
        var bytes = [UInt8](repeating: 0, count: width * height * 4)
        let drawn = bytes.withUnsafeMutableBytes { buffer -> Bool in
            guard let context = CGContext(
                data: buffer.baseAddress, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
            else { return false }
            let rect = CGRect(x: 0, y: 0, width: width, height: height)
            context.setFillColor(CGColor(srgbRed: 0, green: 0, blue: 0, alpha: 1))
            context.fill(rect)
            context.interpolationQuality = .none
            context.draw(image, in: rect)
            return true
        }
        return drawn ? DecodedBackgroundImage(width: width, height: height, bytes: bytes) : nil
    }
}
