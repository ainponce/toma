// SPDX-License-Identifier: GPL-3.0-or-later
import Metal
import ProjectFormat
import Synchronization

/// The pipelines of the calm zoom (phase 3 design §6 and §12, step 4: Highlight, Dim and the loupe, `CalmZoomLook`), made
/// with the compositor's (`LayerPipelines`): Highlight in each pass of what goes over the stage (straight into the target,
/// into the motion blur's target); Dim's two blur passes (the core's `blurFragment`, across into `rgba16Float`, then down
/// into the frame's format, as `BackgroundImages` does) and its veil, and the loupe's lens, into the target alone, in the
/// pass `drawCalmZoom` opens; and the textures they read (`CalmZoomTextures`).
struct CalmZoomPipelines {
    private let highlight: any MTLRenderPipelineState
    private let blurTargetHighlight: any MTLRenderPipelineState
    let dim: any MTLRenderPipelineState
    let blurAcross: any MTLRenderPipelineState
    let blurDown: any MTLRenderPipelineState
    let lens: any MTLRenderPipelineState
    /// The copies of the frame and Dim's blur, apart from the screen's copies.
    let textures: CalmZoomTextures
    /// For tests: the passes the command buffer is made to refuse.
    let refusals = CalmZoomRefusals()

    init(maker: PipelineMaker) throws {
        CalmZoomLook.checkLayouts()
        highlight = try maker.pipeline(vertex: "quadVertex", fragment: "calmHighlightFragment", blending: .over, into: .target)
        blurTargetHighlight = try maker.pipeline(
            vertex: "quadVertex", fragment: "calmHighlightTargetFragment", blending: .over, into: LayerPass.blurTarget.attachments)
        dim = try maker.pipeline(vertex: "quadVertex", fragment: "calmDimFragment", blending: .over, into: .target)
        let across = MTLRenderPipelineDescriptor()
        across.vertexFunction = try maker.function("gradientVertex")
        across.fragmentFunction = try maker.function("blurFragment")
        across.colorAttachments[0].pixelFormat = Compositor.sumFormat
        blurAcross = try maker.device.makeRenderPipelineState(descriptor: across)
        blurDown = try maker.pipeline(vertex: "gradientVertex", fragment: "blurFragment", blending: .none, into: .target)
        lens = try maker.pipeline(vertex: "quadVertex", fragment: "loupeFragment", blending: .over, into: .target)
        textures = CalmZoomTextures(device: maker.device)
    }

    /// Highlight's pipeline of `pass`, over the stage.
    func highlight(for pass: LayerPass) -> any MTLRenderPipelineState {
        switch pass {
        case .target: highlight
        case .blurTarget: blurTargetHighlight
        case .subsample: preconditionFailure("The calm zoom is drawn over the stage, never into a subsample of it")
        }
    }
}

extension Compositor {
    /// Draws the calm zoom `layer` of `frame` over the stage drawn (step 4 of phase 3 design §12, after the click effects
    /// and before the annotations stuck to the recording and the camera, `drawOverTheStage`): through `stage`, or the
    /// card's content `card` in a card's mode, into `pass`, counting each drawn in `counts.calmZooms`. Highlight draws in
    /// the same pass; dim and the loupe, which read what is drawn of the stage, end `encoder`'s pass, sample its target
    /// through a texture of their own made from `commandBuffer`, and open one pass into `target` alone, which they leave in
    /// `encoder`. Returns whether they did: what follows is drawn into that pass (`Compositor.directCamera`, `.target`).
    /// Nothing without a layer, nor of one not seen (`CalmZoomLayer`): `false`. Throws `RenderError.metalResourceUnavailable`
    /// when Metal cannot make a texture it needs, or the command buffer takes no pass it needs, leaving in `encoder` a pass
    /// still open (the one given, or the one it opened), which the caller ends: the frame is never drawn some other way.
    /// When the command buffer takes not even the pass into `target` again after it ended the given one, it throws that
    /// error in `CalmZoomPassEnded`: there is no pass left to end.
    ///
    /// Every texture is made before the pass is ended, so a texture Metal cannot make leaves the pass given as it is. The
    /// pass reopened counts in `counts.renderPasses`, and the drawing that read the frame in `counts.calmZoomSamples`.
    ///
    /// Over a frame with nothing behind its stage (`BackgroundLayer.transparent`, milestone 4c), Highlight and Dim darken
    /// the stage drawn and not the void, and the loupe magnifies what is under it with its alpha, with their pipelines of
    /// `AlphaPipelines`.
    func drawCalmZoom(
        _ layer: CalmZoomLayer?, frame: RenderFrame, through stage: StageTransform?, card: CardContent?, pass: LayerPass,
        encoder: inout any MTLRenderCommandEncoder, target: any MTLTexture, commandBuffer: any MTLCommandBuffer,
        counts: inout DrawCounts
    ) throws -> Bool {
        guard let layer, layer.mode != .classic, layer.amount > 0,
              [layer.focus.x, layer.focus.y, layer.focus.width, layer.focus.height].allSatisfy(\.isFinite)
        else { return false }
        let amount = min(layer.amount, 1)
        let outputSize = frame.outputSize
        let transparent = frame.background == .transparent
        let focus = stage?.outputRect(ofStage: layer.focus, outputSize: outputSize) ?? layer.focus
        var passes = CalmZoomPasses(commandBuffer: commandBuffer, refusal: layers.calmZoom.refusals.forTests)
        switch layer.mode {
        case .classic:
            return false
        case .highlight:
            var uniforms = CalmZoomLook.focusUniforms(.highlight, amount: amount, focus: focus, outputSize: outputSize)
            let highlight = transparent ? layers.alpha.highlight(for: pass) : layers.calmZoom.highlight(for: pass)
            encoder.setRenderPipelineState(highlight)
            drawOverTheOutput(&uniforms, card: card, outputSize: outputSize, encoder: encoder)
            counts.calmZooms += 1
            return false
        case .dim:
            try checkReadable(target)
            try drawDim(
                focus: focus, amount: amount, card: card, outputSize: outputSize, transparent: transparent, encoder: &encoder,
                target: target, passes: &passes, counts: &counts)
            return true
        case .loupe:
            guard let lens = layer.loupe, lens.radius > 0, lens.radius.isFinite, !lens.magnification.isNaN else { return false }
            let middle = SIMD2(layer.focus.x + layer.focus.width / 2, layer.focus.y + layer.focus.height / 2)
            let center = stage?.outputPoint(ofStage: middle, outputSize: outputSize) ?? middle
            return try drawLoupe(
                lens, center: center, amount: amount, outputSize: outputSize, transparent: transparent, encoder: &encoder,
                target: target, passes: &passes, counts: &counts)
        }
    }

    /// Throws `RenderError.metalResourceUnavailable` for a target that cannot be read (`framebufferOnly`), whose frame
    /// Dim and the loupe cannot copy: before anything is encoded of them, so the frame is not drawn some other way.
    private func checkReadable(_ target: any MTLTexture) throws {
        guard !target.isFramebufferOnly else { throw RenderError.metalResourceUnavailable("a target the calm zoom can read") }
    }

    /// A render pass into `target` (`.bgra8Unorm`) that starts from what it holds: the one the calm zoom opens after
    /// reading what was drawn. Throws `RenderError.metalResourceUnavailable` when `commandBuffer` takes none.
    func loadingPass(into target: any MTLTexture, commandBuffer: any MTLCommandBuffer) throws -> any MTLRenderCommandEncoder {
        var passes = CalmZoomPasses(commandBuffer: commandBuffer, refusal: nil)
        guard let encoder = passes.render(Self.loadingDescriptor(into: target)) else {
            throw RenderError.metalResourceUnavailable("the calm zoom's pass into the target")
        }
        return encoder
    }

    /// The pass of `loadingPass`.
    private static func loadingDescriptor(into target: any MTLTexture) -> MTLRenderPassDescriptor {
        precondition(target.pixelFormat == Self.pixelFormat, "Compositor draws into \(Self.pixelFormat) only, not \(target.pixelFormat)")
        let pass = MTLRenderPassDescriptor()
        let attachment = pass.colorAttachments[0]!
        attachment.texture = target
        attachment.loadAction = .load
        attachment.storeAction = .store
        return pass
    }

    /// Ends `encoder`'s pass, runs `body` (what reads the target), and opens the pass into `target` that loads what it
    /// holds into `encoder` (`loadingPass`). When `body` throws, or the command buffer takes no such pass, opens one anyway
    /// for the caller to end and throws the error; when the command buffer takes none at all, throws it in
    /// `CalmZoomPassEnded`.
    private func withThePassEnded(
        _ encoder: inout any MTLRenderCommandEncoder, target: any MTLTexture, passes: inout CalmZoomPasses,
        _ body: (inout CalmZoomPasses) throws(RenderError) -> Void
    ) throws {
        encoder.endEncoding()
        var failure: RenderError?
        do {
            try body(&passes)
        } catch {
            failure = error
        }
        if failure == nil, let opened = passes.render(Self.loadingDescriptor(into: target)) {
            encoder = opened
            return
        }
        let error = failure ?? .metalResourceUnavailable("the calm zoom's pass into the target")
        guard let reopened = passes.render(Self.loadingDescriptor(into: target), reopening: true) else {
            throw CalmZoomPassEnded(error: error)
        }
        encoder = reopened
        throw error
    }

    /// Draws one quad over the whole output with the pipeline set, `uniforms` as the fragment's buffer 1 and the card's
    /// cut (`card`, none without one) as its buffers 2 and 3.
    private func drawOverTheOutput(
        _ uniforms: inout CalmFocusUniforms, card: CardContent?, outputSize: SIMD2<Int>, encoder: any MTLRenderCommandEncoder
    ) {
        let viewport = SIMD2<Float>(Float(outputSize.x), Float(outputSize.y))
        var quad = QuadUniforms(
            viewport: viewport, origin: .zero, size: viewport, contentOrigin: .zero, contentSize: viewport, uvOrigin: .zero,
            uvSize: .one, radius: 0)
        encoder.setVertexBytes(&quad, length: MemoryLayout<QuadUniforms>.stride, index: 0)
        encoder.setFragmentBytes(&uniforms, length: MemoryLayout<CalmFocusUniforms>.stride, index: 1)
        Self.setClip(card ?? CardContent(transform: nil, clip: quad, strength: 0), at: 2, encoder: encoder)
        encoder.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
    }

    /// Dim (`CalmZoomLook`) of `focus` as drawn: a copy of the whole target with its mipmaps up to the level of its blur
    /// (`dimBlurLevel`), that level blurred in two passes, and its veil over the target in a pass of its own, left in
    /// `encoder`; over a `transparent` frame, the veil with the copy's alpha (`AlphaPipelines.dim`).
    private func drawDim(
        focus: Rect, amount: Double, card: CardContent?, outputSize: SIMD2<Int>, transparent: Bool,
        encoder: inout any MTLRenderCommandEncoder, target: any MTLTexture, passes: inout CalmZoomPasses,
        counts: inout DrawCounts
    ) throws {
        let pipelines = layers.calmZoom
        let width = target.width, height = target.height
        // σ in the target's pixels, and in the texels of the level it is blurred at.
        let sigma = CalmZoomLook.dimSigma * CalmZoomLook.point(outputSize: outputSize) * Double(width) / Double(outputSize.x)
        let level = CalmZoomLook.dimBlurLevel(sigma: sigma, size: SIMD2(width, height))
        let levelSize = SIMD2(max(width >> level, 1), max(height >> level, 1))
        let reducedSigma = sigma / Double(1 << level)
        // Every texture before the pass is ended: the copy with the view of its level kept with it.
        let commandBuffer = passes.commandBuffer
        let copy = try pipelines.textures.mipmapped(
            width: width, height: height, pixelFormat: Self.pixelFormat, levels: level + 1, commandBuffer: commandBuffer)
        let across = try pipelines.textures.texture(
            width: levelSize.x, height: levelSize.y, pixelFormat: Self.sumFormat, commandBuffer: commandBuffer)
        let blurred = try pipelines.textures.texture(
            width: levelSize.x, height: levelSize.y, pixelFormat: Self.pixelFormat, commandBuffer: commandBuffer)

        let radius = Int32(min((3 * reducedSigma).rounded(.up), Double(max(levelSize.x, levelSize.y))))
        try withThePassEnded(&encoder, target: target, passes: &passes) { passes throws(RenderError) in
            try Self.copyFrame(
                of: target, region: MTLRegionMake2D(0, 0, width, height), into: copy.texture, mipmaps: level > 0, passes: &passes)
            for (source, destination, direction, pipeline) in [
                (copy.lastLevel, across, SIMD2<Float>(1, 0), pipelines.blurAcross),
                (across, blurred, SIMD2<Float>(0, 1), pipelines.blurDown),
            ] {
                guard let blur = passes.render(Self.blurDescriptor(into: destination)) else {
                    throw .metalResourceUnavailable("the calm zoom's blur pass")
                }
                blur.label = "Compositor calm zoom blur"
                var uniforms = CalmBlurUniforms(direction: direction, sigma: Float(reducedSigma), radius: radius)
                blur.setRenderPipelineState(pipeline)
                blur.setFragmentBytes(&uniforms, length: MemoryLayout<CalmBlurUniforms>.stride, index: 0)
                blur.setFragmentTexture(source, index: 0)
                blur.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
                blur.endEncoding()
            }
        }

        counts.renderPasses += 1
        var uniforms = CalmZoomLook.focusUniforms(.dim, amount: amount, focus: focus, outputSize: outputSize)
        encoder.setRenderPipelineState(transparent ? layers.alpha.dim : pipelines.dim)
        encoder.setFragmentTexture(blurred, index: 0)
        encoder.setFragmentSamplerState(screenSampler, index: 0)
        drawOverTheOutput(&uniforms, card: card, outputSize: outputSize, encoder: encoder)
        counts.calmZooms += 1
        counts.calmZoomSamples += 1
    }

    /// The loupe's `lens` centred at `center` (output pixels): a copy of its box in the target (with what its bulge
    /// reads, `lensBox`), and the lens, its shadow and its ring over the target in a pass of its own, left in `encoder`;
    /// over a `transparent` frame, the lens with the copy's alpha (`AlphaPipelines.lens`). Nothing, and `false`, when none
    /// of the box is in the target.
    private func drawLoupe(
        _ lens: LoupeLayer, center: SIMD2<Double>, amount: Double, outputSize: SIMD2<Int>, transparent: Bool,
        encoder: inout any MTLRenderCommandEncoder, target: any MTLTexture, passes: inout CalmZoomPasses,
        counts: inout DrawCounts
    ) throws -> Bool {
        let half = CalmZoomLook.lensHalfSize(radius: lens.radius, shape: lens.shape)
        guard center.x.isFinite, center.y.isFinite, half.x.isFinite, half.y.isFinite else { return false }
        try checkReadable(target)
        let toTarget = SIMD2(Double(target.width), Double(target.height)) / SIMD2<Double>(outputSize)
        guard let region = CalmZoomLook.lensBox(
            halfSize: half, center: center, toTarget: toTarget, targetSize: SIMD2(target.width, target.height))
        else { return false }
        // The texture before the pass is ended.
        let copy = try layers.calmZoom.textures.texture(
            width: region.size.width, height: region.size.height, pixelFormat: Self.pixelFormat,
            commandBuffer: passes.commandBuffer)

        try withThePassEnded(&encoder, target: target, passes: &passes) { passes throws(RenderError) in
            try Self.copyFrame(of: target, region: region, into: copy, mipmaps: false, passes: &passes)
        }
        counts.renderPasses += 1

        var uniforms = CalmZoomLook.loupeUniforms(
            lens, center: center, amount: amount, sampleOrigin: SIMD2(Double(region.origin.x), Double(region.origin.y)),
            toTarget: toTarget, outputSize: outputSize)
        var shadow = CalmZoomLook.lensShadow(lens, center: center, outputSize: outputSize)
        let viewport = SIMD2<Float>(Float(outputSize.x), Float(outputSize.y))
        let extent = half + CalmZoomLook.lensReach(outputSize: outputSize)
        let origin = SIMD2<Float>(center - extent), size = SIMD2<Float>(2 * extent)
        var quad = QuadUniforms(
            viewport: viewport, origin: origin, size: size, contentOrigin: origin, contentSize: size, uvOrigin: .zero,
            uvSize: .one, radius: 0)
        encoder.setRenderPipelineState(transparent ? layers.alpha.lens : layers.calmZoom.lens)
        encoder.setVertexBytes(&quad, length: MemoryLayout<QuadUniforms>.stride, index: 0)
        encoder.setFragmentBytes(&uniforms, length: MemoryLayout<LoupeUniforms>.stride, index: 1)
        encoder.setFragmentBytes(&shadow, length: MemoryLayout<LensShadowUniforms>.stride, index: 2)
        encoder.setFragmentTexture(copy, index: 0)
        encoder.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
        counts.calmZooms += 1
        counts.calmZoomSamples += 1
        return true
    }

    /// Copies `region` of `target`, whose pass has ended, into level 0 of `copy` (its origin there), with the rest of its
    /// mipmaps made with `mipmaps`. Throws `RenderError.metalResourceUnavailable` without a blit pass.
    private static func copyFrame(
        of target: any MTLTexture, region: MTLRegion, into copy: any MTLTexture, mipmaps: Bool, passes: inout CalmZoomPasses
    ) throws(RenderError) {
        guard let blit = passes.blit() else { throw .metalResourceUnavailable("the calm zoom's blit pass") }
        blit.label = "Compositor calm zoom copy"
        blit.copy(
            from: target, sourceSlice: 0, sourceLevel: 0, sourceOrigin: region.origin, sourceSize: region.size, to: copy,
            destinationSlice: 0, destinationLevel: 0, destinationOrigin: MTLOrigin(x: 0, y: 0, z: 0))
        if mipmaps { blit.generateMipmaps(for: copy) }
        blit.endEncoding()
    }

    /// A render pass that writes every pixel of `destination` (what it held is not loaded): one of Dim's blur.
    private static func blurDescriptor(into destination: any MTLTexture) -> MTLRenderPassDescriptor {
        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = destination
        pass.colorAttachments[0].loadAction = .dontCare
        pass.colorAttachments[0].storeAction = .store
        return pass
    }
}

/// What `Compositor.drawCalmZoom` throws when the command buffer took no pass after it ended the one it was given, not
/// even the pass into the target again: `error`, with no pass left open, so the caller ends none.
struct CalmZoomPassEnded: Error {
    let error: RenderError
}

/// The passes the calm zoom asks its command buffer for, `nil` when it takes none; for tests, refused as `refusal` says.
struct CalmZoomPasses {
    let commandBuffer: any MTLCommandBuffer
    let refusal: CalmZoomRefusals.Plan?
    /// How many were asked for.
    private var asked = 0

    init(commandBuffer: any MTLCommandBuffer, refusal: CalmZoomRefusals.Plan?) {
        self.commandBuffer = commandBuffer
        self.refusal = refusal
    }

    /// Whether the next one is refused, for tests: from the `after`-th on, but the pass opened again after a failure
    /// (`reopening`) when the plan gives that one.
    private mutating func refuses(reopening: Bool) -> Bool {
        defer { asked += 1 }
        guard let refusal else { return false }
        return asked >= refusal.after && !(reopening && refusal.reopens)
    }

    mutating func blit() -> (any MTLBlitCommandEncoder)? {
        refuses(reopening: false) ? nil : commandBuffer.makeBlitCommandEncoder()
    }

    mutating func render(_ pass: MTLRenderPassDescriptor, reopening: Bool = false) -> (any MTLRenderCommandEncoder)? {
        guard !refuses(reopening: reopening), let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: pass) else { return nil }
        encoder.label = "Compositor calm zoom"
        return encoder
    }
}

/// For tests: the passes the calm zoom's command buffer refuses, as one that takes no more does.
final class CalmZoomRefusals: @unchecked Sendable {
    /// From the `after`-th pass the calm zoom asks for (blits included, 0 the first), every one is refused; but the pass
    /// into the target opened again after that, with `reopens`.
    struct Plan: Sendable {
        var after: Int
        var reopens: Bool
    }

    private let plan = Mutex<Plan?>(nil)

    var forTests: Plan? {
        get { plan.withLock { $0 } }
        set { plan.withLock { $0 = newValue } }
    }
}
