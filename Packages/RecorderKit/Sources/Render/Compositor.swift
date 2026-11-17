// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import Metal
import ProjectFormat
import Synchronization

/// Draws a `RenderFrame` into a `.bgra8Unorm` target: the stage (the background, the shadow, the window frame, the screen
/// — over the one being left during a change of screen — and the cursor), the click effects and the camera (its shadow,
/// its picture and its border), in that order, blended premultiplied "over"; before it, for a screen sampled with
/// mipmaps, a blit pass that makes them.
///
/// - Without a motion blur, in one render pass that starts by clearing the target: the stage through the frame's zoom
///   camera (`RenderFrame.stage`), exactly as without a zoom when it has none or is at rest.
/// - With one (`RenderFrame.subframes` or `cursorSamples`, design §7.2), in one render pass too, whose subsample and sum
///   stay in tile memory (`memoryless`), so nothing goes to memory between the subsamples: each subframe draws the stage
///   through its own transform into attachment 0 over the one before (its background is opaque and covers the target,
///   so nothing needs clearing), and a drawing over the whole target adds it, times 1/N, to the sum in `rgba16Float`
///   (attachment 1) by programmable blending, in their order. With cursor samples instead, the stage is drawn once and
///   each sample is added to the sum. A last drawing writes the average (or the cursor's average over the stage) to the
///   target, attachment 2. The click effects, once through the stage at the frame's time and never blurred (plan
///   decision 26), and the camera are drawn over it in the same pass.
///
/// The shaders are compiled and the pipelines built once, in `init`. The same frame and source textures
/// always give the same bytes on the same GPU.
public final class Compositor: @unchecked Sendable {
    /// The only target format: preview and export must write the same bytes, so never an `_srgb` format.
    public static let pixelFormat = MTLPixelFormat.bgra8Unorm
    /// The format of the motion blur's sum of its subsamples.
    static let sumFormat = MTLPixelFormat.rgba16Float

    /// The compiled shaders (`ShaderSource`), for what draws into textures of its own (`BackgroundImages`).
    let library: any MTLLibrary
    private let device: any MTLDevice
    /// What draws the stage straight into the target.
    private let direct: StagePipelines
    /// What draws the stage into a subsample of the motion blur's pass.
    private let subsample: StagePipelines
    private let clickEffectPipeline: any MTLRenderPipelineState
    /// What draws the camera straight into the target.
    private let directCamera: CameraPipelines
    /// The rest of the motion blur's pass.
    private let blur: BlurPipelines
    private let screenSampler: any MTLSamplerState
    /// Linear between the texels and between the mipmap levels: the cursor, the title and a screen with mipmaps.
    private let trilinearSampler: any MTLSamplerState
    private let mipmappedCopies: MipmappedCopies

    /// Throws the compiler's error if the shaders do not build, and `RenderError` if Metal cannot make a
    /// pipeline or sampler.
    public init(device: any MTLDevice) throws {
        precondition(MemoryLayout<QuadUniforms>.stride == 88, "QuadUniforms must keep the layout of the shaders' struct: 88 bytes")
        precondition(
            MemoryLayout<WindowBarUniforms>.stride == 112, "WindowBarUniforms must keep the layout of the shaders' struct: 112 bytes")
        precondition(
            MemoryLayout<ClickEffectUniforms>.stride == 32, "ClickEffectUniforms must keep the layout of the shaders' struct: 32 bytes")
        precondition(MemoryLayout<ShadowUniforms>.stride == 32, "ShadowUniforms must keep the layout of the shaders' struct: 32 bytes")
        precondition(MemoryLayout<StageMapping>.stride == 16, "StageMapping must keep the layout of the shaders' struct: 16 bytes")
        precondition(
            MemoryLayout<CameraBorderUniforms>.stride == 32, "CameraBorderUniforms must keep the layout of the shaders' struct: 32 bytes")
        let options = MTLCompileOptions()
        options.mathMode = .safe
        let library = try device.makeLibrary(source: ShaderSource.metal, options: options)
        func function(_ name: String) throws -> any MTLFunction {
            guard let function = library.makeFunction(name: name) else { throw RenderError.missingShaderFunction(name) }
            return function
        }
        func pipeline(
            vertex: String, fragment: String, blending: Blending, into attachments: Attachments = .target
        ) throws -> any MTLRenderPipelineState {
            let descriptor = MTLRenderPipelineDescriptor()
            descriptor.vertexFunction = try function(vertex)
            descriptor.fragmentFunction = try function(fragment)
            let written: Int
            switch attachments {
            case .target:
                descriptor.colorAttachments[0].pixelFormat = Self.pixelFormat
                written = 0
            case let .blurPass(index):
                for (i, format) in [Self.pixelFormat, Self.sumFormat, Self.pixelFormat].enumerated() {
                    descriptor.colorAttachments[i].pixelFormat = format
                    if i != index { descriptor.colorAttachments[i].writeMask = [] }
                }
                written = index
            }
            let color = descriptor.colorAttachments[written]!
            switch blending {
            case .none:
                break
            case .over, .add:
                color.isBlendingEnabled = true
                color.rgbBlendOperation = .add
                color.alphaBlendOperation = .add
                color.sourceRGBBlendFactor = .one
                color.sourceAlphaBlendFactor = .one
                color.destinationRGBBlendFactor = blending == .over ? .oneMinusSourceAlpha : .one
                color.destinationAlphaBlendFactor = blending == .over ? .oneMinusSourceAlpha : .one
            }
            return try device.makeRenderPipelineState(descriptor: descriptor)
        }
        func stagePipelines(into attachments: Attachments) throws -> StagePipelines {
            try StagePipelines(
                gradient: pipeline(vertex: "gradientVertex", fragment: "gradientFragment", blending: .none, into: attachments),
                stageGradient: pipeline(vertex: "gradientVertex", fragment: "stageGradientFragment", blending: .none, into: attachments),
                wallpaper: pipeline(vertex: "quadVertex", fragment: "wallpaperFragment", blending: .none, into: attachments),
                backgroundImage: pipeline(
                    vertex: "gradientVertex", fragment: "backgroundImageFragment", blending: .none, into: attachments),
                blurredWallpaper: pipeline(
                    vertex: "gradientVertex", fragment: "blurredWallpaperFragment", blending: .none, into: attachments),
                screen: pipeline(vertex: "quadVertex", fragment: "screenFragment", blending: .over, into: attachments),
                mipmappedScreen: pipeline(vertex: "quadVertex", fragment: "mipmappedScreenFragment", blending: .over, into: attachments),
                shadow: pipeline(vertex: "quadVertex", fragment: "shadowFragment", blending: .over, into: attachments),
                sprite: pipeline(vertex: "quadVertex", fragment: "spriteFragment", blending: .over, into: attachments),
                cursor: pipeline(vertex: "quadVertex", fragment: "cursorFragment", blending: .over, into: attachments),
                windowBar: pipeline(vertex: "quadVertex", fragment: "windowBarFragment", blending: .over, into: attachments))
        }
        self.library = library
        self.device = device
        direct = try stagePipelines(into: .target)
        subsample = try stagePipelines(into: .blurPass(writing: 0))
        clickEffectPipeline = try pipeline(vertex: "quadVertex", fragment: "clickEffectFragment", blending: .over)
        directCamera = try CameraPipelines(
            picture: direct.screen,
            bordered: pipeline(vertex: "quadVertex", fragment: "borderedCameraFragment", blending: .over),
            shadow: pipeline(vertex: "quadVertex", fragment: "cameraShadowFragment", blending: .over))
        blur = try BlurPipelines(
            accumulate: pipeline(vertex: "gradientVertex", fragment: "accumulateFragment", blending: .none, into: .blurPass(writing: 1)),
            cursorSample: pipeline(vertex: "quadVertex", fragment: "cursorSampleFragment", blending: .add, into: .blurPass(writing: 1)),
            resolve: pipeline(vertex: "gradientVertex", fragment: "resolveFragment", blending: .none, into: .blurPass(writing: 2)),
            resolveCursor: pipeline(
                vertex: "gradientVertex", fragment: "resolveCursorFragment", blending: .none, into: .blurPass(writing: 2)),
            clickEffect: pipeline(
                vertex: "quadVertex", fragment: "clickEffectTargetFragment", blending: .over, into: .blurPass(writing: 2)),
            camera: CameraPipelines(
                picture: pipeline(vertex: "quadVertex", fragment: "cameraTargetFragment", blending: .over, into: .blurPass(writing: 2)),
                bordered: pipeline(
                    vertex: "quadVertex", fragment: "borderedCameraTargetFragment", blending: .over, into: .blurPass(writing: 2)),
                shadow: pipeline(
                    vertex: "quadVertex", fragment: "cameraShadowTargetFragment", blending: .over, into: .blurPass(writing: 2))))

        let sampler = MTLSamplerDescriptor()
        sampler.minFilter = .linear
        sampler.magFilter = .linear
        sampler.sAddressMode = .clampToEdge
        sampler.tAddressMode = .clampToEdge
        guard let screenSampler = device.makeSamplerState(descriptor: sampler) else {
            throw RenderError.metalResourceUnavailable("screen sampler")
        }
        sampler.mipFilter = .linear
        guard let trilinearSampler = device.makeSamplerState(descriptor: sampler) else {
            throw RenderError.metalResourceUnavailable("cursor sampler")
        }
        self.screenSampler = screenSampler
        self.trilinearSampler = trilinearSampler
        mipmappedCopies = MipmappedCopies(device: device)
    }

    /// Encodes the frame into `target`, which must be `.bgra8Unorm` (`pixelFormat`). Positions in `frame` map onto the
    /// whole target (they are in pixels of `frame.outputSize`; a background that is not a gradient is read at the stage
    /// point under each of the target's pixels, its grain of the target's pixels). The screen is drawn only when
    /// `frame.screen` is set and `screen` is given, its `crop` filling its rect at its `opacity`: with `mipmapped`,
    /// trilinear from a copy with mipmaps of the crop's whole pixels alone that this makes on the GPU first, so not even
    /// its mipmaps hold anything outside an Area; nothing for a crop that is not finite. The screen being left during a
    /// change of screen (`frame.previousScreen`, with `previousScreen` its frame) is drawn the same way under it. The
    /// shadow (`frame.shadow`) only with the screen, under it and the window frame. The cursor only when `frame.cursor`
    /// is set, shown (opacity above 0) and of some size, with `cursor` the texture of its image (`CursorImages`), which
    /// every cursor of the frame (its subframes', its samples) is drawn with; the click effects over it
    /// (`frame.clickEffects`); the camera only when `frame.camera` is set, shown (opacity above 0) and `camera` is given,
    /// filling its rect without stretching (cropped, centred, to the rect's shape), with its look (its shadow, its picture
    /// flipped, its border) at its opacity in the same pass. An `.image` background is `backgroundImage`, the texture
    /// `BackgroundImages` made of it for this size, or the frame's gradient without one. A `.wallpaper` is drawn
    /// directly without `backgroundImage`; with one, its mesh gradient, blurred or not
    /// (`BackgroundImages.texture(forWallpaper:…)`), the grain is added to it. A window frame's title is `windowTitle`,
    /// the texture `TitleTexture` made of it at the frame's title scale (`TitleTexture.scale(for:)`), drawn at those
    /// bar's pixels (`barPixels`) through the stage; none without one. The stage is drawn through `frame.stage`, and
    /// blurred with `frame.subframes` or `frame.cursorSamples` (see the type's notes). Throws
    /// `RenderError.metalResourceUnavailable`, having encoded nothing, when Metal cannot make the screen's copy or the
    /// blur's tile memory: a frame is never drawn some other way. `screen`, `previousScreen`, `camera`, `cursor`,
    /// `backgroundImage` and `windowTitle` must stay alive until `commandBuffer` completes.
    public func encode(
        _ frame: RenderFrame,
        screen: (any MTLTexture)?,
        previousScreen: (any MTLTexture)? = nil,
        camera: (any MTLTexture)?,
        cursor: any MTLTexture,
        backgroundImage: (any MTLTexture)? = nil,
        windowTitle: (any MTLTexture)? = nil,
        into target: any MTLTexture,
        commandBuffer: any MTLCommandBuffer
    ) throws {
        var counts = DrawCounts()
        try encode(
            frame, screen: screen, previousScreen: previousScreen, camera: camera, cursor: cursor, backgroundImage: backgroundImage,
            windowTitle: windowTitle, into: target, commandBuffer: commandBuffer, counts: &counts)
    }

    /// `encode(_:screen:camera:cursor:backgroundImage:windowTitle:into:commandBuffer:)`, counting what it draws in
    /// `counts`: for tests.
    func encode(
        _ frame: RenderFrame,
        screen: (any MTLTexture)?,
        previousScreen: (any MTLTexture)? = nil,
        camera: (any MTLTexture)?,
        cursor: any MTLTexture,
        backgroundImage: (any MTLTexture)? = nil,
        windowTitle: (any MTLTexture)? = nil,
        into target: any MTLTexture,
        commandBuffer: any MTLCommandBuffer,
        counts: inout DrawCounts
    ) throws {
        // The blur's tile memory, then what the screens are sampled from, their copies with mipmaps made before the render
        // pass.
        let tileMemory = frame.subframes.isEmpty && frame.cursorSamples.isEmpty ? nil : try blurTileMemory(like: target)
        let screenImage = try frame.screen.flatMap { layer in
            try screen.flatMap { try image(of: layer, in: $0, commandBuffer: commandBuffer) }
        }
        let previousImage = try frame.previousScreen.flatMap { layer in
            try previousScreen.flatMap { try image(of: layer, in: $0, commandBuffer: commandBuffer) }
        }
        let textures = StageTextures(
            screen: screenImage, previousScreen: previousImage, cursor: cursor, backgroundImage: backgroundImage,
            windowTitle: windowTitle)
        let targetSize = SIMD2(target.width, target.height)
        let stage = Self.moving(frame.stage, outputSize: frame.outputSize)
        if let tileMemory {
            let encoder = blurPass(into: target, tileMemory: tileMemory, commandBuffer: commandBuffer)
            counts.renderPasses += 1
            if !frame.subframes.isEmpty {
                var weight = Float(1 / Double(frame.subframes.count))
                for subframe in frame.subframes {
                    drawStage(
                        frame, through: Self.moving(subframe.stage, outputSize: frame.outputSize), cursor: subframe.cursor,
                        textures: textures, pipelines: subsample, culling: true, targetSize: targetSize, encoder: encoder,
                        counts: &counts)
                    encoder.setRenderPipelineState(blur.accumulate)
                    encoder.setFragmentBytes(&weight, length: MemoryLayout<Float>.stride, index: 0)
                    encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
                    counts.accumulations += 1
                }
                encoder.setRenderPipelineState(blur.resolve)
            } else {
                drawStage(
                    frame, through: stage, cursor: nil, textures: textures, pipelines: subsample, culling: true, targetSize: targetSize,
                    encoder: encoder, counts: &counts)
                let share = 1 / Double(frame.cursorSamples.count)
                for layer in frame.cursorSamples {
                    drawCursor(
                        layer, through: stage, outputSize: frame.outputSize, share: share, texture: cursor, pipeline: blur.cursorSample,
                        encoder: encoder, counts: &counts)
                }
                encoder.setRenderPipelineState(blur.resolveCursor)
            }
            encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
            drawOverTheStage(
                frame, through: stage, camera: camera, clickEffect: blur.clickEffect, cameraPipelines: blur.camera, encoder: encoder,
                counts: &counts)
            encoder.endEncoding()
            return
        }
        let encoder = renderPass(into: target, commandBuffer: commandBuffer)
        counts.renderPasses += 1
        drawStage(
            frame, through: stage, cursor: frame.cursor, textures: textures, pipelines: direct, targetSize: targetSize, encoder: encoder,
            counts: &counts)
        drawOverTheStage(
            frame, through: stage, camera: camera, clickEffect: clickEffectPipeline, cameraPipelines: directCamera, encoder: encoder,
            counts: &counts)
        encoder.endEncoding()
    }

    /// What `layer` samples of the screen's `frame`: the frame and the layer's crop of it; with `mipmapped`, a copy with
    /// mipmaps of the crop's whole pixels alone, rounded inward (`MipmappedCopies.region(of:width:height:)`), and the crop
    /// as fractions of that copy, so neither the copy nor any of its levels holds anything outside the crop. `nil`, no
    /// screen, for a crop that is not finite.
    private func image(
        of layer: ScreenLayer, in frame: any MTLTexture, commandBuffer: any MTLCommandBuffer
    ) throws -> ScreenImage? {
        let crop = layer.crop
        guard layer.mipmapped else {
            return ScreenImage(
                texture: frame, uvOrigin: SIMD2(Float(crop.x), Float(crop.y)), uvSize: SIMD2(Float(crop.width), Float(crop.height)))
        }
        guard let region = MipmappedCopies.region(of: crop, width: frame.width, height: frame.height) else { return nil }
        let copy = try mipmappedCopies.copy(of: frame, region: region.pixels, commandBuffer: commandBuffer)
        return ScreenImage(texture: copy, uvOrigin: region.uvOrigin, uvSize: region.uvSize)
    }

    /// How many mipmapped copies of the screen were made so far, and how many no frame on the GPU uses: for tests.
    var mipmappedCopiesCount: (made: Int, free: Int) { mipmappedCopies.count }

    /// How many sizes the mipmapped copies no frame on the GPU uses are of: for tests.
    var mipmappedCopiesFreeSizes: Int { mipmappedCopies.freeSizes }

    /// Draws `frame`'s click effects alone over what `target` holds, through `frame.stage`, as `encode` draws them over
    /// its stage: for tests.
    func encodeClickEffects(of frame: RenderFrame, into target: any MTLTexture, commandBuffer: any MTLCommandBuffer) {
        let pass = MTLRenderPassDescriptor()
        let attachment = pass.colorAttachments[0]!
        attachment.texture = target
        attachment.loadAction = .load
        attachment.storeAction = .store
        guard let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: pass) else {
            preconditionFailure("Compositor: the command buffer takes no render pass")
        }
        var counts = DrawCounts()
        drawClickEffects(
            frame.clickEffects, through: Self.moving(frame.stage, outputSize: frame.outputSize), outputSize: frame.outputSize,
            pipeline: clickEffectPipeline, encoder: encoder, counts: &counts)
        encoder.endEncoding()
    }

    /// Draws `preset` alone into all of `target` (`.bgra8Unorm`): in one quad as `encode` draws a frame's wallpaper when
    /// `tileSize` is `nil`, otherwise in one quad per square of `tileSize` pixels (cut at the right and bottom edges). For
    /// tests: nothing in a wallpaper depends on how its drawing is split.
    func encodeWallpaper(_ preset: WallpaperPreset, tileSize: Int?, into target: any MTLTexture, commandBuffer: any MTLCommandBuffer) {
        let encoder = renderPass(into: target, commandBuffer: commandBuffer)
        let size = SIMD2(target.width, target.height)
        let viewport = SIMD2<Float>(Float(size.x), Float(size.y))
        let mapping = StageMapping(nil, outputSize: size, targetSize: size)
        let step = tileSize ?? max(size.x, size.y)
        precondition(step > 0, "Tiles of \(step) pixels")
        for y in stride(from: 0, to: size.y, by: step) {
            for x in stride(from: 0, to: size.x, by: step) {
                let tile = Rect(x: Double(x), y: Double(y), width: Double(min(step, size.x - x)), height: Double(min(step, size.y - y)))
                drawWallpaper(preset, in: tile, mapping: mapping, viewport: viewport, pipelines: direct, encoder: encoder)
            }
        }
        encoder.endEncoding()
    }

    /// `stage`, or `nil` when it is an identity of an output of `outputSize`: a stage at rest is drawn as it is.
    private static func moving(_ stage: StageTransform?, outputSize: SIMD2<Int>) -> StageTransform? {
        stage == .identity(outputSize: outputSize) ? nil : stage
    }

    /// A render pass into `target` (`.bgra8Unorm`) that starts by clearing it to opaque black.
    private func renderPass(into target: any MTLTexture, commandBuffer: any MTLCommandBuffer) -> any MTLRenderCommandEncoder {
        precondition(target.pixelFormat == Self.pixelFormat, "Compositor draws into \(Self.pixelFormat) only, not \(target.pixelFormat)")
        let pass = MTLRenderPassDescriptor()
        let attachment = pass.colorAttachments[0]!
        attachment.texture = target
        attachment.loadAction = .clear
        attachment.clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 1)
        attachment.storeAction = .store
        guard let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: pass) else {
            preconditionFailure("Compositor: the command buffer takes no render pass (already committed, or another encoder is open)")
        }
        encoder.label = "Compositor"
        return encoder
    }

    /// The motion blur's tile memory for a target like `target`: a subsample (`.bgra8Unorm`) and the sum (`sumFormat`),
    /// both `memoryless`. Throws `RenderError.metalResourceUnavailable` when Metal cannot make them.
    private func blurTileMemory(like target: any MTLTexture) throws -> (subsample: any MTLTexture, sum: any MTLTexture) {
        func make(_ format: MTLPixelFormat) throws -> any MTLTexture {
            let descriptor = MTLTextureDescriptor.texture2DDescriptor(
                pixelFormat: format, width: target.width, height: target.height, mipmapped: false)
            descriptor.usage = .renderTarget
            descriptor.storageMode = .memoryless
            guard let texture = device.makeTexture(descriptor: descriptor) else {
                throw RenderError.metalResourceUnavailable("the motion blur's tile memory")
            }
            return texture
        }
        return try (make(Self.pixelFormat), make(Self.sumFormat))
    }

    /// The motion blur's render pass into `target` (`.bgra8Unorm`): attachment 0 the subsample and 1 the sum of
    /// `tileMemory`, the sum cleared to 0; attachment 2 the target, all of which the pass writes.
    private func blurPass(
        into target: any MTLTexture, tileMemory: (subsample: any MTLTexture, sum: any MTLTexture), commandBuffer: any MTLCommandBuffer
    ) -> any MTLRenderCommandEncoder {
        precondition(target.pixelFormat == Self.pixelFormat, "Compositor draws into \(Self.pixelFormat) only, not \(target.pixelFormat)")
        let pass = MTLRenderPassDescriptor()
        let attachments: [(texture: any MTLTexture, load: MTLLoadAction, store: MTLStoreAction)] = [
            (tileMemory.subsample, .dontCare, .dontCare), (tileMemory.sum, .clear, .dontCare), (target, .dontCare, .store),
        ]
        for (index, attachment) in attachments.enumerated() {
            let color = pass.colorAttachments[index]!
            color.texture = attachment.texture
            color.loadAction = attachment.load
            color.storeAction = attachment.store
            color.clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 0)
        }
        guard let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: pass) else {
            preconditionFailure("Compositor: the command buffer takes no render pass (already committed, or another encoder is open)")
        }
        encoder.label = "Compositor motion blur"
        return encoder
    }

    /// Draws the stage of `frame` with `pipelines`: the background, the shadow, the window frame, the screen (over the one
    /// being left, during a change of screen) and `cursorLayer` (design §7.2, steps 1 to 5), through `stage` (as they are
    /// when `nil`). With `culling`, the background and the shadow are drawn only around where the screen (and its window)
    /// covers the target opaquely, clipped by scissor rects: every pixel drawn is the one it would be, and an opaque one
    /// does not show what is under it (the motion blur's subsamples, which draw the stage up to 16 times). Only while the
    /// screen is drawn alone at full opacity: a screen fading in over the one being left, or at any lower opacity, draws
    /// everything under it.
    private func drawStage(
        _ frame: RenderFrame, through stage: StageTransform?, cursor cursorLayer: CursorLayer?, textures: StageTextures,
        pipelines: StagePipelines, culling: Bool = false, targetSize: SIMD2<Int>, encoder: any MTLRenderCommandEncoder,
        counts: inout DrawCounts
    ) {
        let size = frame.outputSize
        let viewport = SIMD2<Float>(Float(size.x), Float(size.y))

        // The stage's layers as they are drawn: through the zoom camera, or as they are.
        let shadow = frame.shadow.map { stage?.drawn($0, outputSize: size) ?? $0 }
        let window = frame.windowFrame.map { stage?.drawn($0, outputSize: size) ?? $0 }
        let screenLayer = frame.screen.map { stage?.drawn($0, outputSize: size) ?? $0 }
        let previousLayer = frame.previousScreen.map { stage?.drawn($0, outputSize: size) ?? $0 }
        let opaque = frame.previousScreen == nil && frame.screen.map { $0.opacity >= 1 } ?? true
        let bands = (culling && opaque && textures.screen != nil ? Self.opaqueInterior(screen: screenLayer, window: window) : nil).map {
            Self.scissorBands(around: $0, outputSize: size, targetSize: targetSize)
        }

        // 1. Background, and 2. the shadow over it, under the window or the screen, with the screen drawn: with
        // `culling`, both in each band in turn.
        counts.backgrounds += 1
        for band in bands.map({ $0.map(Optional.some) }) ?? [nil] {
            if let band { encoder.setScissorRect(band) }
            drawBackground(
                frame, through: stage, textures: textures, targetSize: targetSize, viewport: viewport, pipelines: pipelines,
                encoder: encoder)
            if let shadow, textures.screen != nil {
                drawShadow(shadow, viewport: viewport, pipeline: pipelines.shadow, encoder: encoder)
            }
        }
        if bands != nil { encoder.setScissorRect(MTLScissorRect(x: 0, y: 0, width: targetSize.x, height: targetSize.y)) }

        // 3. Window frame: its bar and buttons, then its title, made for the bar's pixels at the frame's title scale
        // (`TitleTexture.scale(for:)`): those pixels, brought back to the stage, through it. While the window moves, the
        // title is made where it goes (`TitleTexture.source(for:)`) and stretched from there onto its bar now.
        if let window, let unzoomed = frame.windowFrame, window.rect.width > 0, window.rect.height > 0 {
            drawWindowBar(window, viewport: viewport, pipelines: pipelines, encoder: encoder)
            if let windowTitle = textures.windowTitle {
                let scale = TitleTexture.scale(for: frame), source = frame.settledWindowFrame ?? unzoomed
                let box = (scale == 1 ? source : TitleTexture.scaled(source, by: scale)).barPixels
                var origin = SIMD2<Double>(box.origin) / scale, boxSize = SIMD2<Double>(box.size) / scale
                if let settled = frame.settledWindowFrame {
                    let stretch = SIMD2(unzoomed.rect.width / settled.rect.width, unzoomed.barHeight / settled.barHeight)
                    origin = SIMD2(unzoomed.rect.x, unzoomed.rect.y) + (origin - SIMD2(settled.rect.x, settled.rect.y)) * stretch
                    boxSize *= stretch
                }
                drawSprite(
                    windowTitle, origin: stage?.outputPoint(ofStage: origin, outputSize: size) ?? origin,
                    size: boxSize * (stage?.depth ?? 1), pipeline: pipelines.sprite, viewport: viewport, encoder: encoder)
            }
        }

        // 4. Screen, cut by the window around it if there is one: the one being left first, then the one coming over it.
        for (layer, screenImage) in [(previousLayer, textures.previousScreen), (screenLayer, textures.screen)] {
            guard let layer, let screenImage, layer.opacity > 0 else { continue }
            // Only an area's crop is clamped: the whole frame is drawn exactly as before (the golden frames).
            drawImage(
                screenImage.texture, in: layer.rect, cornerRadius: window?.cornerRadius ?? layer.cornerRadius,
                uvOrigin: screenImage.uvOrigin, uvSize: screenImage.uvSize,
                clampsToCrop: layer.crop != Rect(x: 0, y: 0, width: 1, height: 1),
                shape: window.map { ($0.rect, bottomRadius: $0.bottomCornerRadius, imageTopRadius: $0.screenTopCornerRadius) },
                mipmapped: layer.mipmapped, opacity: layer.opacity,
                pipeline: layer.mipmapped ? pipelines.mipmappedScreen : pipelines.screen, viewport: viewport, encoder: encoder)
            counts.screens += 1
        }

        // 5. Cursor, its hotspot at the cursor position, pressed smaller about it, at its opacity.
        if let cursorLayer {
            drawCursor(
                cursorLayer, through: stage, outputSize: size, texture: textures.cursor, pipeline: pipelines.cursor, encoder: encoder,
                counts: &counts)
        }
    }

    /// Draws what goes over the stage of `frame`: its click effects through `stage` (design §7.2, step 6), never blurred,
    /// with `clickEffect`, then the camera in output space (step 7) with `cameraPipelines`.
    private func drawOverTheStage(
        _ frame: RenderFrame, through stage: StageTransform?, camera: (any MTLTexture)?, clickEffect: any MTLRenderPipelineState,
        cameraPipelines: CameraPipelines, encoder: any MTLRenderCommandEncoder, counts: inout DrawCounts
    ) {
        // 6. Click effects, over the cursor.
        drawClickEffects(
            frame.clickEffects, through: stage, outputSize: frame.outputSize, pipeline: clickEffect, encoder: encoder, counts: &counts)

        // 7. Camera, over everything.
        if let layer = frame.camera, let camera {
            drawCamera(layer, texture: camera, outputSize: frame.outputSize, pipelines: cameraPipelines, encoder: encoder, counts: &counts)
        }
    }

    /// Draws the camera `layer` with `texture`, its frame (design §7.2, step 7, and 1c design §14.3), in output space with
    /// `pipelines`: its shadow first, then its picture filling its rect without stretching (cropped, centred, to the
    /// rect's shape), flipped with `mirror` (`u` becomes `1 − u` across that crop), and its border over the picture in the
    /// same drawing, all at its opacity (0 to 1). Nothing of one hidden (its opacity not above 0, or not a number). With
    /// no shadow and no border, the one drawing of 1b, with its values: at opacity 1, the picture exactly as opaque as
    /// ever.
    private func drawCamera(
        _ layer: CameraLayer, texture: any MTLTexture, outputSize: SIMD2<Int>, pipelines: CameraPipelines,
        encoder: any MTLRenderCommandEncoder, counts: inout DrawCounts
    ) {
        let opacity = layer.opacity.isNaN ? 0 : min(layer.opacity, 1)
        guard opacity > 0 else { return }
        let viewport = SIMD2<Float>(Float(outputSize.x), Float(outputSize.y))
        if let shadow = layer.shadow, drawShadow(
            shadow, under: (layer.rect, layer.cornerRadius, opacity), viewport: viewport, pipeline: pipelines.shadow, encoder: encoder)
        {
            counts.cameraShadows += 1
        }
        var fill = Self.aspectFill(SIMD2(Double(texture.width), Double(texture.height)), in: layer.rect)
        if layer.mirror {
            fill = (SIMD2(fill.origin.x + fill.size.x, fill.origin.y), SIMD2(-fill.size.x, fill.size.y))
        }
        let border = layer.border.flatMap { $0.width > 0 && $0.width.isFinite ? $0 : nil }
        drawImage(
            texture, in: layer.rect, cornerRadius: layer.cornerRadius, uvOrigin: fill.origin, uvSize: fill.size, opacity: opacity,
            border: border, pipeline: border == nil ? pipelines.picture : pipelines.bordered, viewport: viewport, encoder: encoder)
        counts.cameras += 1
        if border != nil { counts.cameraBorders += 1 }
    }

    /// Draws the background of `frame` over the whole target, through `stage`: the gradient as today when it is drawn as
    /// it is (`gradientFragment`), and everything else at the stage point under each pixel (`StageMapping`).
    private func drawBackground(
        _ frame: RenderFrame, through stage: StageTransform?, textures: StageTextures, targetSize: SIMD2<Int>,
        viewport: SIMD2<Float>, pipelines: StagePipelines, encoder: any MTLRenderCommandEncoder
    ) {
        let mapping = StageMapping(stage, outputSize: frame.outputSize, targetSize: targetSize)
        func drawFramesGradient() {
            let angle = frame.gradientAngleDegrees * .pi / 180
            drawGradient(
                start: frame.gradientStart, end: frame.gradientEnd, direction: SIMD2(sin(angle), -cos(angle)),
                mapping: stage == nil ? nil : mapping, viewport: viewport, pipelines: pipelines, encoder: encoder)
        }
        switch frame.background {
        case .gradient:
            drawFramesGradient()
        case .image:
            if let backgroundImage = textures.backgroundImage {
                drawBackgroundImage(backgroundImage, mapping: mapping, viewport: viewport, pipelines: pipelines, encoder: encoder)
            } else {
                // The image is missing or cannot be read: the frame carries Toma classic for it.
                drawFramesGradient()
            }
        case let .color(color):
            // Both ends of that colour: every pixel is `mix(color, color, t)`, the colour itself, through any stage.
            drawGradient(
                start: color, end: color, direction: .zero, mapping: nil, viewport: viewport, pipelines: pipelines, encoder: encoder)
        case let .wallpaper(preset, _):
            if let backgroundImage = textures.backgroundImage {
                drawBlurredWallpaper(backgroundImage, mapping: mapping, viewport: viewport, pipelines: pipelines, encoder: encoder)
            } else {
                drawWallpaper(
                    preset, in: Rect(x: 0, y: 0, width: Double(viewport.x), height: Double(viewport.y)), mapping: mapping,
                    viewport: viewport, pipelines: pipelines, encoder: encoder)
            }
        }
    }

    /// Fills the whole target with the gradient from `start` to `end` along `direction` (`gradientFragment`), or at the
    /// stage point under each pixel with `mapping` (`stageGradientFragment`).
    private func drawGradient(
        start: SIMD4<Float>, end: SIMD4<Float>, direction: SIMD2<Float>, mapping: StageMapping?, viewport: SIMD2<Float>,
        pipelines: StagePipelines, encoder: any MTLRenderCommandEncoder
    ) {
        var gradient = GradientUniforms(start: start, end: end, direction: direction, padding: .zero)
        if var mapping {
            var stageSize = viewport
            encoder.setRenderPipelineState(pipelines.stageGradient)
            encoder.setFragmentBytes(&gradient, length: MemoryLayout<GradientUniforms>.stride, index: 0)
            encoder.setFragmentBytes(&mapping, length: MemoryLayout<StageMapping>.stride, index: 1)
            encoder.setFragmentBytes(&stageSize, length: MemoryLayout<SIMD2<Float>>.stride, index: 2)
        } else {
            encoder.setRenderPipelineState(pipelines.gradient)
            encoder.setFragmentBytes(&gradient, length: MemoryLayout<GradientUniforms>.stride, index: 0)
        }
        encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
    }

    /// Fills the whole target with `texture`, a background image made for the stage's size, at the stage point under each
    /// pixel (`backgroundImageFragment`).
    private func drawBackgroundImage(
        _ texture: any MTLTexture, mapping: StageMapping, viewport: SIMD2<Float>, pipelines: StagePipelines,
        encoder: any MTLRenderCommandEncoder
    ) {
        var stageSize = viewport, mapping = mapping
        encoder.setRenderPipelineState(pipelines.backgroundImage)
        encoder.setFragmentBytes(&stageSize, length: MemoryLayout<SIMD2<Float>>.stride, index: 0)
        encoder.setFragmentBytes(&mapping, length: MemoryLayout<StageMapping>.stride, index: 1)
        encoder.setFragmentTexture(texture, index: 0)
        encoder.setFragmentSamplerState(screenSampler, index: 0)
        encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
    }

    /// Fills the whole target with `mesh`, a wallpaper's mesh gradient (blurred or not) made for the stage's size, at the
    /// stage point under each pixel, and the grain of the target's pixels (`blurredWallpaperFragment`).
    private func drawBlurredWallpaper(
        _ mesh: any MTLTexture, mapping: StageMapping, viewport: SIMD2<Float>, pipelines: StagePipelines,
        encoder: any MTLRenderCommandEncoder
    ) {
        var stageSize = viewport, mapping = mapping
        encoder.setRenderPipelineState(pipelines.blurredWallpaper)
        encoder.setFragmentBytes(&stageSize, length: MemoryLayout<SIMD2<Float>>.stride, index: 0)
        encoder.setFragmentBytes(&mapping, length: MemoryLayout<StageMapping>.stride, index: 1)
        encoder.setFragmentTexture(mesh, index: 0)
        encoder.setFragmentSamplerState(screenSampler, index: 0)
        encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
    }

    /// The part of the output that the stage's screen, with its window, covers opaquely, drawn as `screen` and `window`
    /// say: their rounded rect inset by its corners and a pixel, so neither the corners nor the antialiased edges are in
    /// it. With a window, its bar and the screen under it cover it; `nil` when it is empty, or when the screen does not
    /// fill the window under its bar (it always does).
    static func opaqueInterior(screen: ScreenLayer?, window: WindowFrameLayer?) -> Rect? {
        guard let screen, screen.rect.width > 0, screen.rect.height > 0 else { return nil }
        var rect = screen.rect, radius = screen.cornerRadius
        if let window, window.rect.width > 0, window.rect.height > 0 {
            let fills = abs(screen.rect.x - window.rect.x) < 1e-3 && abs(screen.rect.width - window.rect.width) < 1e-3
                && abs(screen.rect.y - (window.rect.y + window.barHeight)) < 1e-3
                && abs(screen.rect.y + screen.rect.height - (window.rect.y + window.rect.height)) < 1e-3
            guard fills else { return nil }
            (rect, radius) = (window.rect, max(window.cornerRadius, window.bottomCornerRadius))
        }
        let inset = (radius.isFinite ? max(radius, 0) : 0) + 1
        guard rect.width > 2 * inset, rect.height > 2 * inset else { return nil }
        return Rect(x: rect.x + inset, y: rect.y + inset, width: rect.width - 2 * inset, height: rect.height - 2 * inset)
    }

    /// The target's pixels (`targetSize`) but those wholly inside `hole` (output pixels of a frame of `outputSize`),
    /// as scissor rects that do not overlap: the bands above and below the hole across the target, and those beside it;
    /// the whole target when no pixel is.
    static func scissorBands(around hole: Rect, outputSize: SIMD2<Int>, targetSize: SIMD2<Int>) -> [MTLScissorRect] {
        let scale = SIMD2<Double>(targetSize) / SIMD2<Double>(outputSize)
        func pixel(_ value: Double, _ rule: FloatingPointRoundingRule, within limit: Int) -> Int {
            Int(min(max(value.rounded(rule), 0), Double(limit)))
        }
        let width = targetSize.x, height = targetSize.y
        let left = pixel(hole.x * scale.x, .up, within: width), right = pixel((hole.x + hole.width) * scale.x, .down, within: width)
        let top = pixel(hole.y * scale.y, .up, within: height), bottom = pixel((hole.y + hole.height) * scale.y, .down, within: height)
        guard left < right, top < bottom else { return [MTLScissorRect(x: 0, y: 0, width: width, height: height)] }
        var bands: [MTLScissorRect] = []
        if top > 0 { bands.append(MTLScissorRect(x: 0, y: 0, width: width, height: top)) }
        if bottom < height { bands.append(MTLScissorRect(x: 0, y: bottom, width: width, height: height - bottom)) }
        if left > 0 { bands.append(MTLScissorRect(x: 0, y: top, width: left, height: bottom - top)) }
        if right < width { bands.append(MTLScissorRect(x: right, y: top, width: width - right, height: bottom - top)) }
        return bands
    }

    /// Draws the part `rect` (output pixels) of `preset` over a stage of the whole output, at the stage point under each
    /// pixel (`wallpaperFragment`).
    private func drawWallpaper(
        _ preset: WallpaperPreset, in rect: Rect, mapping: StageMapping, viewport: SIMD2<Float>, pipelines: StagePipelines,
        encoder: any MTLRenderCommandEncoder
    ) {
        let origin = SIMD2(Float(rect.x), Float(rect.y)), size = SIMD2(Float(rect.width), Float(rect.height))
        var quad = QuadUniforms(
            viewport: viewport, origin: origin, size: size, contentOrigin: origin, contentSize: size, uvOrigin: .zero,
            uvSize: .one, radius: 0)
        var wallpaper = WallpaperUniforms(stageSize: viewport, count: UInt32(preset.points.count), padding: 0)
        var mapping = mapping
        encoder.setRenderPipelineState(pipelines.wallpaper)
        encoder.setVertexBytes(&quad, length: MemoryLayout<QuadUniforms>.stride, index: 0)
        encoder.setFragmentBytes(&wallpaper, length: MemoryLayout<WallpaperUniforms>.stride, index: 0)
        preset.points.withUnsafeBytes { encoder.setFragmentBytes($0.baseAddress!, length: $0.count, index: 1) }
        preset.colors.withUnsafeBytes { encoder.setFragmentBytes($0.baseAddress!, length: $0.count, index: 2) }
        encoder.setFragmentBytes(&mapping, length: MemoryLayout<StageMapping>.stride, index: 3)
        encoder.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
    }

    /// Draws the cursor `layer` (stage coordinates) through `stage` with `texture`, its image: its hotspot at its
    /// position, pressed smaller about it, at its opacity times `share`, its share of an average (`cursorFragment`, or a
    /// sample of the motion blur's, `cursorSampleFragment`). Nothing of one hidden or of no size.
    private func drawCursor(
        _ layer: CursorLayer, through stage: StageTransform?, outputSize: SIMD2<Int>, share: Double = 1, texture: any MTLTexture,
        pipeline: any MTLRenderPipelineState, encoder: any MTLRenderCommandEncoder, counts: inout DrawCounts
    ) {
        let layer = stage?.drawn(layer, outputSize: outputSize) ?? layer
        guard layer.opacity > 0 else { return }
        let height = layer.height * layer.clickScale
        guard height > 0, height.isFinite, layer.aspect > 0, layer.aspect.isFinite else { return }
        let size = SIMD2(height * layer.aspect, height)
        drawSprite(
            texture, origin: layer.hotspot - layer.hotspotFraction * size, size: size, opacity: Float(min(layer.opacity, 1) * share),
            pipeline: pipeline, viewport: SIMD2<Float>(Float(outputSize.x), Float(outputSize.y)), encoder: encoder)
        counts.cursors += 1
    }

    /// Draws `texture`, premultiplied, into the rect at `origin` of `size` (output pixels), all of it, with `pipeline`:
    /// as it is (`spriteFragment`), or at `opacity` (`cursorFragment`, `cursorSampleFragment`).
    private func drawSprite(
        _ texture: any MTLTexture, origin: SIMD2<Double>, size: SIMD2<Double>, opacity: Float? = nil,
        pipeline: any MTLRenderPipelineState, viewport: SIMD2<Float>, encoder: any MTLRenderCommandEncoder
    ) {
        var quad = QuadUniforms(
            viewport: viewport,
            origin: SIMD2<Float>(origin),
            size: SIMD2<Float>(size),
            contentOrigin: SIMD2<Float>(origin),
            contentSize: SIMD2<Float>(size),
            uvOrigin: .zero,
            uvSize: .one,
            radius: 0)
        encoder.setRenderPipelineState(pipeline)
        if var opacity {
            encoder.setFragmentBytes(&opacity, length: MemoryLayout<Float>.stride, index: 0)
        }
        encoder.setVertexBytes(&quad, length: MemoryLayout<QuadUniforms>.stride, index: 0)
        encoder.setFragmentTexture(texture, index: 0)
        encoder.setFragmentSamplerState(trilinearSampler, index: 0)
        encoder.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
    }

    /// Draws `layers` (stage coordinates) through `stage` in order with `pipeline` (`clickEffectFragment`), each over the
    /// square around it that holds its outline and its antialiased edge, the outline 1 px times the stage's depth;
    /// nothing of one at opacity 0 or of no size. With the zoom's camera they are drawn once, never blurred, after the
    /// blur's subsamples are resolved, through the stage's transform at the frame's time (plan decision 26).
    private func drawClickEffects(
        _ layers: [ClickEffectLayer], through stage: StageTransform?, outputSize: SIMD2<Int>, pipeline: any MTLRenderPipelineState,
        encoder: any MTLRenderCommandEncoder, counts: inout DrawCounts
    ) {
        guard !layers.isEmpty else { return }
        let viewport = SIMD2<Float>(Float(outputSize.x), Float(outputSize.y))
        let outlineWidth = Float(stage?.depth ?? 1)
        encoder.setRenderPipelineState(pipeline)
        for layer in layers {
            guard layer.opacity > 0, layer.opacity.isFinite, layer.radius > 0, layer.radius.isFinite, layer.center.x.isFinite,
                  layer.center.y.isFinite
            else { continue }
            let drawn = stage?.drawn(layer, outputSize: outputSize) ?? layer
            let ring = drawn.kind == .ripple
            let thickness = ring && drawn.thickness.isFinite ? max(drawn.thickness, 0) : 0
            // A ring's white, its outline and half a pixel of antialiasing past it; a disc's edge and half a pixel.
            let reach = drawn.radius + thickness / 2 + (ring ? Double(outlineWidth) + 1 : 1)
            let origin = SIMD2<Float>(drawn.center - reach), size = SIMD2<Float>(repeating: Float(2 * reach))
            var quad = QuadUniforms(
                viewport: viewport, origin: origin, size: size, contentOrigin: origin, contentSize: size, uvOrigin: .zero,
                uvSize: .one, radius: 0)
            var uniforms = ClickEffectUniforms(
                center: SIMD2<Float>(drawn.center), radius: Float(drawn.radius), thickness: Float(thickness),
                opacity: Float(min(drawn.opacity, 1)), outline: Float(min(ClickEffects.outlineOpacity(of: drawn), 1)),
                ring: ring ? 1 : 0, outlineWidth: outlineWidth)
            encoder.setVertexBytes(&quad, length: MemoryLayout<QuadUniforms>.stride, index: 0)
            encoder.setFragmentBytes(&uniforms, length: MemoryLayout<ClickEffectUniforms>.stride, index: 0)
            encoder.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
            counts.clickEffects += 1
        }
    }

    /// Draws `layer` with `pipeline` (`shadowFragment`) over a quad of its box and 3σ and a pixel more on every side: past
    /// 3σ of its box the shadow is under 0.35 / 255, which rounds to nothing in every output. The camera's (`camera`: its
    /// rect and corners, in output pixels, and the opacity it is drawn at next) with `cameraShadowFragment`, which takes the
    /// camera's rounded rect as the image of a quad (`imageCoverage`). Nothing of a layer `ShadowMath.Box` leaves out:
    /// returns whether it drew it.
    @discardableResult
    private func drawShadow(
        _ layer: ShadowLayer, under camera: (rect: Rect, cornerRadius: Double, opacity: Double)? = nil, viewport: SIMD2<Float>,
        pipeline: any MTLRenderPipelineState, encoder: any MTLRenderCommandEncoder
    ) -> Bool {
        guard let box = ShadowMath.Box(layer) else { return false }
        let reach = 3 * box.sigma + 1
        let origin = box.lower - reach, size = box.upper - box.lower + 2 * reach
        var quad = QuadUniforms(
            viewport: viewport, origin: origin, size: size, contentOrigin: origin, contentSize: size, uvOrigin: .zero,
            uvSize: .one, radius: 0)
        var uniforms = ShadowUniforms(lower: box.lower, upper: box.upper, sigma: box.sigma, corner: box.corner, opacity: box.opacity)
        encoder.setRenderPipelineState(pipeline)
        encoder.setVertexBytes(&quad, length: MemoryLayout<QuadUniforms>.stride, index: 0)
        encoder.setFragmentBytes(&uniforms, length: MemoryLayout<ShadowUniforms>.stride, index: 0)
        if let camera {
            let rect = camera.rect
            let cameraOrigin = SIMD2(Float(rect.x), Float(rect.y)), cameraSize = SIMD2(Float(rect.width), Float(rect.height))
            var shape = QuadUniforms(
                viewport: viewport, origin: cameraOrigin, size: cameraSize, contentOrigin: cameraOrigin, contentSize: cameraSize,
                uvOrigin: .zero, uvSize: .one, radius: Float(max(camera.cornerRadius, 0)))
            var opacity = Float(camera.opacity)
            encoder.setFragmentBytes(&shape, length: MemoryLayout<QuadUniforms>.stride, index: 1)
            encoder.setFragmentBytes(&opacity, length: MemoryLayout<Float>.stride, index: 2)
        }
        encoder.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
        return true
    }

    /// Draws the title bar of `window` with its buttons (`windowBarFragment`), over a quad one pixel larger than the bar
    /// on every side and one more at the bottom, where the bar goes on one pixel under the screen, and down behind the
    /// screen's round top corners.
    private func drawWindowBar(
        _ window: WindowFrameLayer, viewport: SIMD2<Float>, pipelines: StagePipelines, encoder: any MTLRenderCommandEncoder
    ) {
        let rect = window.rect, bar = window.barHeight, below = max(window.screenTopCornerRadius, 0)
        let origin = SIMD2(Float(rect.x - 1), Float(rect.y - 1)), size = SIMD2(Float(rect.width + 2), Float(bar + 3 + below))
        var quad = QuadUniforms(
            viewport: viewport, origin: origin, size: size, contentOrigin: origin, contentSize: size, uvOrigin: .zero,
            uvSize: .one, radius: 0)
        let colors = WindowFrameLayer.buttonColors
        var uniforms = WindowBarUniforms(
            barColor: window.barColor, red: colors[0], yellow: colors[1], green: colors[2],
            windowOrigin: SIMD2(Float(rect.x), Float(rect.y)), windowSize: SIMD2(Float(rect.width), Float(rect.height)),
            firstButton: SIMD2<Float>(window.firstButton), buttonSpacing: Float(WindowFrameLayer.buttonSpacing * bar),
            buttonRadius: window.buttons ? Float(WindowFrameLayer.buttonDiameter / 2 * bar) : 0,
            radius: Float(max(window.cornerRadius, 0)), barBottom: Float(rect.y + bar),
            bottomRadius: Float(max(window.bottomCornerRadius, 0)), below: Float(below))
        encoder.setRenderPipelineState(pipelines.windowBar)
        encoder.setVertexBytes(&quad, length: MemoryLayout<QuadUniforms>.stride, index: 0)
        encoder.setFragmentBytes(&uniforms, length: MemoryLayout<WindowBarUniforms>.stride, index: 0)
        encoder.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
    }

    /// Draws the part `uvOrigin`, `uvSize` of `texture` into `rect` with rounded corners with `pipeline`
    /// (`screenFragment`), over a quad one pixel larger on every side so its antialiased edge is drawn whole; with
    /// `clampsToCrop`, nothing of `texture` outside that part shows directly, and bilinear only the pixels that part cuts
    /// blend in at its edge; `mipmapped`, trilinear from `texture`'s mipmaps (`mipmappedScreenFragment`), where only a
    /// `texture` made of that part's whole pixels alone keeps all of what is outside it out (`image(of:in:commandBuffer:)`).
    /// With a `shape`, the rounded rect that cuts it is that one (with `cornerRadius` at its top and `bottomRadius` at its
    /// bottom), and `rect`'s own edges are square but for its top corners of `imageTopRadius`. At `opacity` (0 to 1; at 1
    /// exactly as opaque as ever): a screen's while it fades in, the camera's. With a `border`, the camera's, which
    /// `pipeline` draws over it (`borderedCameraFragment`). Nothing for an empty rect.
    private func drawImage(
        _ texture: any MTLTexture, in rect: Rect, cornerRadius: Double, uvOrigin: SIMD2<Float>, uvSize: SIMD2<Float>,
        clampsToCrop: Bool = false, shape: (rect: Rect, bottomRadius: Double, imageTopRadius: Double)? = nil,
        mipmapped: Bool = false, opacity: Double = 1, border: CameraBorderLayer? = nil, pipeline: any MTLRenderPipelineState,
        viewport: SIMD2<Float>, encoder: any MTLRenderCommandEncoder
    ) {
        guard rect.width > 0, rect.height > 0 else { return }
        var quad = QuadUniforms(
            viewport: viewport,
            origin: SIMD2(Float(rect.x - 1), Float(rect.y - 1)),
            size: SIMD2(Float(rect.width + 2), Float(rect.height + 2)),
            contentOrigin: SIMD2(Float(rect.x), Float(rect.y)),
            contentSize: SIMD2(Float(rect.width), Float(rect.height)),
            uvOrigin: uvOrigin,
            uvSize: uvSize,
            radius: Float(max(cornerRadius, 0)),
            clampsToCrop: clampsToCrop ? 1 : 0,
            shapeOrigin: shape.map { SIMD2(Float($0.rect.x), Float($0.rect.y)) } ?? .zero,
            shapeSize: shape.map { SIMD2(Float($0.rect.width), Float($0.rect.height)) } ?? .zero,
            shapeBottomRadius: shape.map { Float(max($0.bottomRadius, 0)) } ?? 0,
            topRadius: shape.map { Float(max($0.imageTopRadius, 0)) } ?? 0)
        var alpha = Float(min(max(opacity, 0), 1))
        encoder.setRenderPipelineState(pipeline)
        encoder.setVertexBytes(&quad, length: MemoryLayout<QuadUniforms>.stride, index: 0)
        encoder.setFragmentBytes(&quad, length: MemoryLayout<QuadUniforms>.stride, index: 0)
        encoder.setFragmentBytes(&alpha, length: MemoryLayout<Float>.stride, index: 1)
        if let border {
            var uniforms = CameraBorderUniforms(color: border.color, width: Float(border.width))
            encoder.setFragmentBytes(&uniforms, length: MemoryLayout<CameraBorderUniforms>.stride, index: 2)
        }
        encoder.setFragmentTexture(texture, index: 0)
        encoder.setFragmentSamplerState(mipmapped ? trilinearSampler : screenSampler, index: 0)
        encoder.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
    }

    /// The part of an image of `size` that fills `rect` without stretching: all of it along the axis where its
    /// shape is narrower than the rect's, the middle of it along the other.
    static func aspectFill(_ size: SIMD2<Double>, in rect: Rect) -> (origin: SIMD2<Float>, size: SIMD2<Float>) {
        guard size.x > 0, size.y > 0, rect.width > 0, rect.height > 0 else { return (.zero, .one) }
        let imageAspect = size.x / size.y, rectAspect = rect.width / rect.height
        if imageAspect > rectAspect {
            let width = rectAspect / imageAspect
            return (SIMD2(Float((1 - width) / 2), 0), SIMD2(Float(width), 1))
        }
        let height = imageAspect / rectAspect
        return (SIMD2(0, Float((1 - height) / 2)), SIMD2(1, Float(height)))
    }
}

/// What `Compositor.encode` drew, for tests: its render passes, and its drawings of each kind (a cursor or a click effect
/// hidden or of no size is not drawn).
struct DrawCounts: Equatable, Sendable {
    var renderPasses = 0
    var backgrounds = 0
    var screens = 0
    var cursors = 0
    var clickEffects = 0
    /// Subsamples of the stage added to the motion blur's sum.
    var accumulations = 0
    /// The camera's picture, with its border or without it.
    var cameras = 0
    /// Its shadow.
    var cameraShadows = 0
    /// Its pictures drawn with a border.
    var cameraBorders = 0
}

/// Where a pipeline draws: alone into the target, or into one attachment of the motion blur's pass (0 the subsample, 1
/// the sum, 2 the target), the others left as they are.
private enum Attachments {
    case target
    case blurPass(writing: Int)
}

/// How a pipeline blends what it draws: not at all, premultiplied "over", or added.
private enum Blending {
    case none, over, add
}

/// The pipelines that draw the stage into one layout of attachments.
private struct StagePipelines {
    let gradient: any MTLRenderPipelineState
    let stageGradient: any MTLRenderPipelineState
    let wallpaper: any MTLRenderPipelineState
    let backgroundImage: any MTLRenderPipelineState
    let blurredWallpaper: any MTLRenderPipelineState
    let screen: any MTLRenderPipelineState
    let mipmappedScreen: any MTLRenderPipelineState
    let shadow: any MTLRenderPipelineState
    let sprite: any MTLRenderPipelineState
    let cursor: any MTLRenderPipelineState
    let windowBar: any MTLRenderPipelineState
}

/// The pipelines of the motion blur's pass that do not draw the stage.
private struct BlurPipelines {
    /// Adds a subsample to the sum.
    let accumulate: any MTLRenderPipelineState
    /// Adds a sample of the cursor to the sum.
    let cursorSample: any MTLRenderPipelineState
    /// The sum into the target.
    let resolve: any MTLRenderPipelineState
    /// The cursor's sum over the stage into the target.
    let resolveCursor: any MTLRenderPipelineState
    let clickEffect: any MTLRenderPipelineState
    let camera: CameraPipelines
}

/// The pipelines that draw the camera (1c design §14.3) into one layout of attachments.
private struct CameraPipelines {
    /// Its picture alone: `screenFragment` into the target, as in 1b, or `cameraTargetFragment`.
    let picture: any MTLRenderPipelineState
    /// Its picture with its border over it.
    let bordered: any MTLRenderPipelineState
    /// Its shadow, under it.
    let shadow: any MTLRenderPipelineState
}

/// The screen's frame as it is sampled: its texture and the part of it shown, as fractions of it.
private struct ScreenImage {
    var texture: any MTLTexture
    var uvOrigin: SIMD2<Float>
    var uvSize: SIMD2<Float>
}

/// The textures a stage is drawn with.
private struct StageTextures {
    var screen: ScreenImage?
    /// The screen being left, during a change of screen.
    var previousScreen: ScreenImage?
    var cursor: any MTLTexture
    var backgroundImage: (any MTLTexture)?
    var windowTitle: (any MTLTexture)?
}

/// `StageMapping` in `ShaderSource.metal`: 16 bytes. The stage point, in pixels of the frame's output size, under each
/// pixel of the target: `pixel × scale + offset`.
private struct StageMapping {
    var scale: SIMD2<Float>
    var offset: SIMD2<Float>

    /// For a frame of `outputSize` drawn into a target of `targetSize` through `stage` (as it is when `nil`).
    init(_ stage: StageTransform?, outputSize: SIMD2<Int>, targetSize: SIMD2<Int>) {
        let size = SIMD2<Double>(outputSize), toFrame = size / SIMD2<Double>(targetSize)
        guard let stage else {
            scale = SIMD2<Float>(toFrame)
            offset = .zero
            return
        }
        // The frame's pixel `p` shows the stage point `(p − size / 2) / depth + center`.
        scale = SIMD2<Float>(toFrame / stage.depth)
        offset = SIMD2<Float>(stage.center - size / 2 / stage.depth)
    }
}

/// `GradientUniforms` in `ShaderSource.metal`.
private struct GradientUniforms {
    var start: SIMD4<Float>
    var end: SIMD4<Float>
    var direction: SIMD2<Float>
    var padding: SIMD2<Float>
}

/// `WallpaperUniforms` in `ShaderSource.metal`: 16 bytes.
struct WallpaperUniforms {
    var stageSize: SIMD2<Float>
    var count: UInt32
    var padding: UInt32
}

/// `QuadUniforms` in `ShaderSource.metal`: 88 bytes.
private struct QuadUniforms {
    var viewport: SIMD2<Float>
    var origin: SIMD2<Float>
    var size: SIMD2<Float>
    var contentOrigin: SIMD2<Float>
    var contentSize: SIMD2<Float>
    var uvOrigin: SIMD2<Float>
    var uvSize: SIMD2<Float>
    var radius: Float
    var clampsToCrop: Float = 0
    var shapeOrigin: SIMD2<Float> = .zero
    var shapeSize: SIMD2<Float> = .zero
    var shapeBottomRadius: Float = 0
    var topRadius: Float = 0
}

/// `ClickEffectUniforms` in `ShaderSource.metal`: 32 bytes.
private struct ClickEffectUniforms {
    var center: SIMD2<Float>
    var radius: Float
    var thickness: Float
    var opacity: Float
    var outline: Float
    var ring: Float
    var outlineWidth: Float
}

/// `ShadowUniforms` in `ShaderSource.metal`: 32 bytes.
private struct ShadowUniforms {
    var lower: SIMD2<Float>
    var upper: SIMD2<Float>
    var sigma: Float
    var corner: Float
    var opacity: Float
    var padding: Float = 0
}

/// `CameraBorderUniforms` in `ShaderSource.metal`: 32 bytes.
private struct CameraBorderUniforms {
    var color: SIMD4<Float>
    var width: Float
    var padding0: Float = 0
    var padding1: Float = 0
    var padding2: Float = 0
}

/// `WindowBarUniforms` in `ShaderSource.metal`: 112 bytes.
private struct WindowBarUniforms {
    var barColor: SIMD4<Float>
    var red: SIMD4<Float>
    var yellow: SIMD4<Float>
    var green: SIMD4<Float>
    var windowOrigin: SIMD2<Float>
    var windowSize: SIMD2<Float>
    var firstButton: SIMD2<Float>
    var buttonSpacing: Float
    var buttonRadius: Float
    var radius: Float
    var barBottom: Float
    var bottomRadius: Float
    var below: Float
}

/// The mipmapped copies of the screen's frames (`ScreenLayer.mipmapped`), each of the part of its frame shown alone: one
/// for each frame on the GPU, of its size and format, kept once the GPU is done with that frame for a later one to use
/// again, so a frame never writes into a copy another frame still reads. Only copies of the last two sizes asked for are
/// kept (the screen, and the one being left in a crossfade): while a change of geometry moves the crop, every frame asks
/// for another size, and the copies of the sizes before it (about 45 MB each at 4K) are let go rather than kept.
///
/// A frame's completion hands its copy back on a thread of Metal's, which reads nothing of this but through `state`'s
/// lock: what Metal orders between a commit and its completion, the thread sanitizer cannot see.
private final class MipmappedCopies: @unchecked Sendable {
    /// The most copies kept for later frames: past it the oldest is let go, so copies of a size no longer drawn do not
    /// stay. Two screens (a change of screen) of three frames on the GPU (the preview's drawables, the export's).
    private static let kept = 6

    /// A copy, to be handed back: textures are not `Sendable`. Made with `state`'s lock held.
    private final class Copy: @unchecked Sendable {
        let texture: any MTLTexture

        init(_ texture: any MTLTexture) {
            self.texture = texture
        }
    }

    /// A copy's size and format.
    private struct Size: Equatable {
        var width: Int
        var height: Int
        var pixelFormat: MTLPixelFormat

        init(width: Int, height: Int, pixelFormat: MTLPixelFormat) {
            (self.width, self.height, self.pixelFormat) = (width, height, pixelFormat)
        }

        init(of texture: any MTLTexture) {
            self.init(width: texture.width, height: texture.height, pixelFormat: texture.pixelFormat)
        }
    }

    /// How many sizes of copies are kept.
    private static let keptSizes = 2

    private struct State {
        /// The copies no frame on the GPU uses, oldest first.
        var free: [Copy] = []
        /// How many were made, for tests.
        var made = 0
        /// The sizes last asked for, the latest last: `keptSizes` at most.
        var sizes: [Size] = []

        /// Notes that `size` was asked for, and lets go of the free copies of a size no longer among the last ones.
        mutating func ask(_ size: Size) {
            sizes.removeAll { $0 == size }
            sizes.append(size)
            if sizes.count > MipmappedCopies.keptSizes { sizes.removeFirst(sizes.count - MipmappedCopies.keptSizes) }
            free.removeAll { !sizes.contains(Size(of: $0.texture)) }
        }
    }

    private let device: any MTLDevice
    private let state = Mutex(State())

    init(device: any MTLDevice) {
        self.device = device
    }

    var count: (made: Int, free: Int) { state.withLock { ($0.made, $0.free.count) } }

    /// How many sizes the free copies are of, for tests.
    var freeSizes: Int {
        state.withLock { state in
            state.free.reduce(into: [Size]()) { sizes, copy in
                if !sizes.contains(Size(of: copy.texture)) { sizes.append(Size(of: copy.texture)) }
            }.count
        }
    }

    /// The whole pixels of a frame `width` × `height` inside `crop` (fractions of it, 0, 0 its top-left corner), rounded
    /// inward: on each axis from `ceil(start − 10⁻⁶)` to `floor(end + 10⁻⁶)` within the frame, or the pixel of the crop's
    /// middle when no whole pixel is inside it. And `crop` as fractions of those pixels: (0, 0) to (1, 1) when its
    /// borders are on pixels, a little past them when they are not (the part that only the cut pixels show). `nil` for a
    /// crop that is not finite.
    static func region(
        of crop: Rect, width: Int, height: Int
    ) -> (pixels: MTLRegion, uvOrigin: SIMD2<Float>, uvSize: SIMD2<Float>)? {
        guard [crop.x, crop.y, crop.width, crop.height].allSatisfy(\.isFinite), width > 0, height > 0 else { return nil }
        func axis(_ start: Double, _ length: Double, _ pixels: Int) -> (first: Int, count: Int, uvOrigin: Float, uvSize: Float) {
            let count = Double(pixels), low = start * count, high = (start + length) * count
            var first = min(max((low - 1e-6).rounded(.up), 0), count)
            var end = min(max((high + 1e-6).rounded(.down), 0), count)
            if end <= first {
                first = min(max(((low + high) / 2).rounded(.down), 0), count - 1)
                end = first + 1
            }
            let size = end - first
            return (Int(first), Int(size), Float((low - first) / size), Float(length * count / size))
        }
        let x = axis(crop.x, crop.width, width), y = axis(crop.y, crop.height, height)
        return (MTLRegionMake2D(x.first, y.first, x.count, y.count), SIMD2(x.uvOrigin, y.uvOrigin), SIMD2(x.uvSize, y.uvSize))
    }

    /// A copy of `region` of `source` with its mipmaps, encoded into `commandBuffer`, which has no encoder open: a blit of
    /// those pixels of its level 0, then `generateMipmaps`. Throws `RenderError.metalResourceUnavailable`, having encoded
    /// nothing, when Metal cannot make the copy or the blit pass.
    func copy(of source: any MTLTexture, region: MTLRegion, commandBuffer: any MTLCommandBuffer) throws -> any MTLTexture {
        guard let copy = take(width: region.size.width, height: region.size.height, pixelFormat: source.pixelFormat) else {
            throw RenderError.metalResourceUnavailable("mipmapped copy of the screen")
        }
        guard let blit = commandBuffer.makeBlitCommandEncoder() else {
            give(copy)
            throw RenderError.metalResourceUnavailable("blit pass for the screen's mipmaps")
        }
        blit.label = "Compositor mipmaps"
        blit.copy(
            from: source, sourceSlice: 0, sourceLevel: 0, sourceOrigin: region.origin, sourceSize: region.size, to: copy.texture,
            destinationSlice: 0, destinationLevel: 0, destinationOrigin: MTLOrigin(x: 0, y: 0, z: 0))
        blit.generateMipmaps(for: copy.texture)
        blit.endEncoding()
        commandBuffer.addCompletedHandler { [self] _ in give(copy) }
        return copy.texture
    }

    /// A free copy of that size and format, or a new one.
    private func take(width: Int, height: Int, pixelFormat: MTLPixelFormat) -> Copy? {
        let size = Size(width: width, height: height, pixelFormat: pixelFormat)
        let reused = state.withLock { state -> Copy? in
            state.ask(size)
            let index = state.free.lastIndex { Size(of: $0.texture) == size }
            return index.map { state.free.remove(at: $0) }
        }
        if let reused { return reused }
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: pixelFormat, width: width, height: height, mipmapped: true)
        descriptor.usage = [.shaderRead, .renderTarget]
        descriptor.storageMode = .private
        guard let texture = device.makeTexture(descriptor: descriptor) else { return nil }
        return state.withLock { state in
            state.made += 1
            return Copy(texture)
        }
    }

    private func give(_ copy: Copy) {
        state.withLock { state in
            // One of a size no longer asked for goes.
            guard state.sizes.contains(Size(of: copy.texture)) else { return }
            state.free.append(copy)
            if state.free.count > Self.kept { state.free.removeFirst() }
        }
    }
}
