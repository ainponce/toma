// SPDX-License-Identifier: GPL-3.0-or-later
import Metal
import ProjectFormat

/// The pipelines of an imported clip of the sequence (phase 3 design §5.4 and §12, step 2), made with the compositor's
/// (`LayerPipelines`): its frame (`mediaClipFragment`, `mediaClipTargetFragment`) and its shadow under it (the core's
/// `cameraShadowFragment`, `cameraShadowTargetFragment`), into the target, a subsample's attachment and the motion blur's
/// target.
struct MediaClipPipelines {
    let picture: [LayerPass: any MTLRenderPipelineState]
    let shadow: [LayerPass: any MTLRenderPipelineState]

    init(maker: PipelineMaker) throws {
        precondition(
            MemoryLayout<MediaClipUniforms>.stride == 32, "MediaClipUniforms must keep the layout of the shaders' struct: 32 bytes")
        precondition(
            MemoryLayout<MediaClipShadowUniforms>.stride == 32,
            "MediaClipShadowUniforms must keep the layout of the shaders' ShadowUniforms: 32 bytes")
        var picture: [LayerPass: any MTLRenderPipelineState] = [:]
        var shadow: [LayerPass: any MTLRenderPipelineState] = [:]
        for pass in [LayerPass.target, .subsample, .blurTarget] {
            let intoTarget = pass == .blurTarget
            picture[pass] = try maker.pipeline(
                vertex: "quadVertex", fragment: intoTarget ? "mediaClipTargetFragment" : "mediaClipFragment", blending: .over,
                into: pass.attachments)
            shadow[pass] = try maker.pipeline(
                vertex: "quadVertex", fragment: intoTarget ? "cameraShadowTargetFragment" : "cameraShadowFragment", blending: .over,
                into: pass.attachments)
        }
        self.picture = picture
        self.shadow = shadow
    }
}

/// What a frame's imported clip is drawn with: the frame of its file the renderer decoded for it
/// (`FrameRenderer.mediaTextures(for:decoded:commandBuffer:)`), or a copy of it with its mipmaps (`mipmapped`, sampled
/// trilinear), and how a player turns it upright. `nil` draws none. It must stay alive until the command buffer it is
/// drawn in completes.
struct MediaClipTextures {
    var frame: any MTLTexture
    var orientation: MediaOrientation = .upright
    var mipmapped = false
}

extension Compositor {
    /// Draws the imported clip `layer` with `textures`, where the screens are (step 2 of phase 3 design §12, after them and
    /// before the cursor, `drawStage`), in an output of `outputSize`, into `pass`, counting it in `counts.mediaClips`: its
    /// frame fitted whole into the layer's room with its upright proportion (`MediaClipLayer.rect(fitting:)`, of the
    /// texture's size), bilinear (trilinear from its mipmaps, `MediaClipTextures.mipmapped`) and opaque over a rounded rect of the layer's corners (at most half its shorter side), and
    /// before it, under it, the screen's shadow of the layer's weight `s` (`FrameEvaluator`'s: at opacity `0.55·s`, of
    /// σ `(0.004 + 0.016·s)·W`, `0.010·s·W` down); the two at the layer's opacity (0 to 1), as the camera with its shadow
    /// (at 1, the clip opaque). A frame of the sequence's clip has no zoom and no card (plan 3a decision
    /// 12); were it drawn through `stage`, or the card's content `card`, it would move with it, its corners and its shadow
    /// scaled by its depth. Nothing without a layer or a frame of it (a file that cannot be read: the background alone),
    /// nor in a room that is empty, nor at an opacity not above 0.
    func drawMediaClip(
        _ layer: MediaClipLayer?, through stage: StageTransform?, card: CardContent?, textures: MediaClipTextures?,
        outputSize: SIMD2<Int>, pass: LayerPass, encoder: any MTLRenderCommandEncoder, counts: inout DrawCounts
    ) {
        guard let layer, let textures, layer.opacity > 0 else { return }
        let opacity = Float(min(layer.opacity, 1))
        let frame = textures.frame
        let picture = textures.orientation.uprightSize(of: SIMD2(Double(frame.width), Double(frame.height)))
        let fitted = layer.rect(fitting: picture)
        let transform = card?.transform ?? stage
        let rect = transform?.outputRect(ofStage: fitted, outputSize: outputSize) ?? fitted
        guard rect.width > 0, rect.height > 0, [rect.x, rect.y, rect.width, rect.height].allSatisfy(\.isFinite),
              let picturePipeline = layers.mediaClip.picture[pass], let shadowPipeline = layers.mediaClip.shadow[pass]
        else { return }
        let depth = transform?.depth ?? 1
        let corners = layer.cornerRadius.isFinite ? max(layer.cornerRadius, 0) * depth : 0
        let viewport = SIMD2<Float>(Float(outputSize.x), Float(outputSize.y))
        var quad = Self.imageQuad(in: rect, cornerRadius: corners, uvOrigin: .zero, uvSize: .one, viewport: viewport)

        // The shadow, under the clip: drawn where the clip lets it through, as the camera's (`cameraShadowFragment`).
        let weight = layer.shadow.isNaN ? 0 : min(max(layer.shadow, 0), 1)
        let width = Double(outputSize.x) * depth
        let shadow = ShadowLayer(
            rect: rect, cornerRadius: corners, opacity: 0.55 * weight, sigma: (0.004 + 0.016 * weight) * width,
            offsetY: 0.010 * weight * width)
        if weight > 0, let box = ShadowMath.Box(shadow) {
            let reach = 3 * box.sigma + 1
            let origin = box.lower - reach, size = box.upper - box.lower + 2 * reach
            var shadowQuad = QuadUniforms(
                viewport: viewport, origin: origin, size: size, contentOrigin: origin, contentSize: size, uvOrigin: .zero,
                uvSize: .one, radius: 0)
            var uniforms = MediaClipShadowUniforms(
                lower: box.lower, upper: box.upper, sigma: box.sigma, corner: box.corner, opacity: box.opacity)
            var shape = Self.shape(rect, cornerRadius: corners, viewport: viewport), shadowOpacity = opacity
            encoder.setRenderPipelineState(shadowPipeline)
            encoder.setVertexBytes(&shadowQuad, length: MemoryLayout<QuadUniforms>.stride, index: 0)
            encoder.setFragmentBytes(&uniforms, length: MemoryLayout<MediaClipShadowUniforms>.stride, index: 0)
            encoder.setFragmentBytes(&shape, length: MemoryLayout<QuadUniforms>.stride, index: 1)
            encoder.setFragmentBytes(&shadowOpacity, length: MemoryLayout<Float>.stride, index: 2)
            encoder.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
        }

        // The clip's frame, upright, over its rounded rect.
        let orientation = textures.orientation
        var uniforms = MediaClipUniforms(
            origin: orientation.origin, across: orientation.across, down: orientation.down, opacity: opacity)
        encoder.setRenderPipelineState(picturePipeline)
        encoder.setVertexBytes(&quad, length: MemoryLayout<QuadUniforms>.stride, index: 0)
        encoder.setFragmentBytes(&quad, length: MemoryLayout<QuadUniforms>.stride, index: 0)
        encoder.setFragmentBytes(&uniforms, length: MemoryLayout<MediaClipUniforms>.stride, index: 1)
        encoder.setFragmentTexture(frame, index: 0)
        encoder.setFragmentSamplerState(textures.mipmapped ? trilinearSampler : screenSampler, index: 0)
        encoder.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
        counts.mediaClips += 1
    }
}

/// `MediaClipUniforms` in `ShaderSource.mediaClipMetal`: 32 bytes.
private struct MediaClipUniforms {
    var origin: SIMD2<Float>
    var across: SIMD2<Float>
    var down: SIMD2<Float>
    var opacity: Float
    var padding: Float = 0
}

/// `ShadowUniforms` in `ShaderSource.coreMetal`: 32 bytes (the compositor's own is private to its file).
private struct MediaClipShadowUniforms {
    var lower: SIMD2<Float>
    var upper: SIMD2<Float>
    var sigma: Float
    var corner: Float
    var opacity: Float
    var padding: Float = 0
}
