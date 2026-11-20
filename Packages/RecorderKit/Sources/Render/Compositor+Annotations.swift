// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import Metal
import ProjectFormat
import simd

/// The pipelines of the annotations (phase 3 design §5.1 and §12, steps 5 and 7, `annotation-1`), made with the
/// compositor's (`LayerPipelines`): a layer's bitmap (`AnnotationRasters`), premultiplied, over the quad of its region
/// popped and rotated about the centre of its box and carried through the zoom (`annotationVertex`), at its opacity, in
/// each pass of what goes over the stage (straight into the target, `annotationFragment`, and into the motion blur's
/// target, `annotationTargetFragment`), and those cut to a card (`clippedAnnotation…`, the cursor's cut); and the bitmaps
/// themselves, kept. Images and clips (milestone 3a's A7) are drawn in the same loop with their own textures.
struct AnnotationPipelines {
    private let target: any MTLRenderPipelineState
    private let blurTarget: any MTLRenderPipelineState
    private let clippedTarget: any MTLRenderPipelineState
    private let clippedBlurTarget: any MTLRenderPipelineState
    let rasters: AnnotationRasters

    init(maker: PipelineMaker) throws {
        precondition(
            MemoryLayout<AnnotationUniforms>.stride == 72, "AnnotationUniforms must keep the layout of the shaders' struct: 72 bytes")
        target = try maker.pipeline(
            vertex: "annotationVertex", fragment: "annotationFragment", blending: .over, into: LayerPass.target.attachments)
        blurTarget = try maker.pipeline(
            vertex: "annotationVertex", fragment: "annotationTargetFragment", blending: .over, into: LayerPass.blurTarget.attachments)
        clippedTarget = try maker.pipeline(
            vertex: "annotationVertex", fragment: "clippedAnnotationFragment", blending: .over, into: LayerPass.target.attachments)
        clippedBlurTarget = try maker.pipeline(
            vertex: "annotationVertex", fragment: "clippedAnnotationTargetFragment", blending: .over,
            into: LayerPass.blurTarget.attachments)
        rasters = AnnotationRasters()
    }

    /// The pipeline of `pass`, over the stage, cut to a card with `clipped`.
    func pipeline(for pass: LayerPass, clipped: Bool) -> any MTLRenderPipelineState {
        switch pass {
        case .target: clipped ? clippedTarget : target
        case .blurTarget: clipped ? clippedBlurTarget : blurTarget
        case .subsample: preconditionFailure("The annotations are drawn over the stage, never into a subsample of it")
        }
    }
}

/// What a frame's annotations are drawn with besides their own textures: the images and the frames of the clips the
/// renderer decoded for them (`FrameRenderer.annotationTextures(for:decoded:commandBuffer:)`). `nil` draws none of those;
/// nothing in the base. They must stay alive until the command buffer they are drawn in completes.
struct AnnotationTextures {}

/// `AnnotationUniforms` in `ShaderSource.annotationsMetal`: 72 bytes. How a layer's region is drawn: popped by `scale` and
/// rotated by `rotation` about `pivot`, then through the zoom (`(q − stageCenter) × depth + outputCenter`), at `opacity`;
/// with `exact`, at rest, one texel a pixel, read.
struct AnnotationUniforms {
    var viewport: SIMD2<Float>
    var origin: SIMD2<Float>
    var size: SIMD2<Float>
    var pivot: SIMD2<Float>
    /// The cosine and the sine of the clockwise angle.
    var rotation: SIMD2<Float>
    var stageCenter: SIMD2<Float>
    var outputCenter: SIMD2<Float>
    var depth: Float
    var scale: Float
    var opacity: Float
    var exact: Float
}

extension Compositor {
    /// Draws the annotations stuck to the recording `layers`, in their order, with `textures` (step 5 of phase 3 design §12,
    /// after the calm zoom and before the camera, `drawOverTheStage`): in the stage, through `stage` (in a card's mode, the
    /// card's content, `card`, cut to the card with its strength, as the cursor), each rasterized at the scale of the zoom
    /// (`AnnotationRaster.scale(for:depth:)`, a step of √2 at a time), in an output of `outputSize`, into `pass`, counting
    /// each drawn in `counts.contentAnnotations`. Nothing without them, and in the base: no call at all.
    func drawContentAnnotations(
        _ layers: [AnnotationLayer], through stage: StageTransform?, card: CardContent?, textures: AnnotationTextures?,
        outputSize: SIMD2<Int>, pass: LayerPass, encoder: any MTLRenderCommandEncoder, counts: inout DrawCounts
    ) {
        guard !layers.isEmpty else { return }
        counts.contentAnnotations += drawAnnotations(
            layers, through: stage, zoomed: true, clip: card, outputSize: outputSize, pass: pass, encoder: encoder)
    }

    /// Draws the output's annotations `layers`, in their order, with `textures` (step 7 of phase 3 design §12, over the
    /// camera and a title card and under the keys, `drawOverlays`): in output space in an output of `outputSize`, one texel
    /// a pixel, into `pass`, counting each drawn in `counts.outputAnnotations`. Nothing without them, and in the base: no
    /// call at all.
    func drawOutputAnnotations(
        _ layers: [AnnotationLayer], textures: AnnotationTextures?, outputSize: SIMD2<Int>, pass: LayerPass,
        encoder: any MTLRenderCommandEncoder, counts: inout DrawCounts
    ) {
        guard !layers.isEmpty else { return }
        counts.outputAnnotations += drawAnnotations(
            layers, through: nil, zoomed: false, clip: nil, outputSize: outputSize, pass: pass, encoder: encoder)
    }

    /// Draws `layers` in their order through `stage`, at the zoom's scale with `zoomed` (at 1 otherwise), cut to `clip`, and
    /// returns how many it drew. Nothing of a layer at opacity 0 (or not a number), of one whose region falls outside the
    /// output, nor of one without a texture (nothing to draw, or CoreGraphics or Metal could not make it: the frame is drawn
    /// without it); so no bitmap is made of the first two. The pipeline, the sampler and the cut are set before the first
    /// drawn, and not again while nothing else is drawn between them.
    private func drawAnnotations(
        _ layers: [AnnotationLayer], through stage: StageTransform?, zoomed: Bool, clip: CardContent?, outputSize: SIMD2<Int>,
        pass: LayerPass, encoder: any MTLRenderCommandEncoder
    ) -> Int {
        let pipelines = self.layers.annotations
        let viewport = SIMD2<Double>(outputSize)
        let depth = stage?.depth ?? 1
        var drawn = 0
        // Whether the bitmaps' pipeline, sampler and cut are bound: an image or a clip drawn between two layers (milestone
        // 3a's A7) binds its own, and unbinds these.
        var bound = false
        for layer in layers {
            switch layer.content {
            case .image, .clip:
                // Drawn with their own textures (milestone 3a's A7), in this same order.
                continue
            case .text, .arrow, .shape, .callout, .step:
                break
            }
            guard layer.opacity > 0, layer.scale > 0, layer.scale.isFinite else { continue }
            let scale = zoomed ? AnnotationRaster.scale(for: layer, depth: depth) : 1
            guard let region = AnnotationRaster.region(of: layer, scale: scale) else { continue }
            var uniforms = Self.annotationUniforms(layer, region: region, through: stage, rasterScale: scale, outputSize: outputSize)
            guard Self.covers(uniforms, viewport: viewport),
                let made = try? pipelines.rasters.texture(for: layer, scale: scale, device: device)
            else { continue }
            if !bound {
                encoder.setRenderPipelineState(pipelines.pipeline(for: pass, clipped: clip != nil))
                encoder.setFragmentSamplerState(screenSampler, index: 0)
                if let clip { Self.setClip(clip, at: 1, encoder: encoder) }
                bound = true
            }
            // The texture's own region: the same as `region`, as the layer and the scale are.
            uniforms.origin = SIMD2<Float>(Float(made.region.x), Float(made.region.y))
            uniforms.size = SIMD2<Float>(Float(made.region.width), Float(made.region.height))
            encoder.setVertexBytes(&uniforms, length: MemoryLayout<AnnotationUniforms>.stride, index: 0)
            encoder.setFragmentBytes(&uniforms, length: MemoryLayout<AnnotationUniforms>.stride, index: 0)
            encoder.setFragmentTexture(made.texture, index: 0)
            encoder.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
            drawn += 1
        }
        return drawn
    }

    /// How `layer`'s `region` (its coordinates) is drawn: popped and rotated about the centre of its box, through `stage`
    /// (as it is when `nil`), at its opacity; exact (one texel a pixel, read) when none of that moves it and its bitmap is
    /// at 1 (`rasterScale`).
    static func annotationUniforms(
        _ layer: AnnotationLayer, region: Rect, through stage: StageTransform?, rasterScale: Double, outputSize: SIMD2<Int>
    ) -> AnnotationUniforms {
        let half = SIMD2<Double>(outputSize) / 2
        let degrees = layer.rotation.isFinite ? layer.rotation.truncatingRemainder(dividingBy: 360) : 0
        let radians = degrees * .pi / 180
        let still = degrees == 0 && layer.scale == 1 && stage == nil && rasterScale == 1
        return AnnotationUniforms(
            viewport: SIMD2<Float>(Float(outputSize.x), Float(outputSize.y)),
            origin: SIMD2<Float>(Float(region.x), Float(region.y)), size: SIMD2<Float>(Float(region.width), Float(region.height)),
            pivot: SIMD2<Float>(Float(layer.rect.x + layer.rect.width / 2), Float(layer.rect.y + layer.rect.height / 2)),
            rotation: degrees == 0 ? SIMD2(1, 0) : SIMD2<Float>(Float(cos(radians)), Float(sin(radians))),
            stageCenter: SIMD2<Float>(stage?.center ?? half), outputCenter: SIMD2<Float>(half), depth: Float(stage?.depth ?? 1),
            scale: Float(layer.scale), opacity: Float(min(layer.opacity, 1)), exact: still ? 1 : 0)
    }

    /// Whether the quad of `uniforms` (`annotationVertex`'s corners) reaches into an output of `viewport`.
    static func covers(_ u: AnnotationUniforms, viewport: SIMD2<Double>) -> Bool {
        var low = SIMD2(Double.infinity, .infinity), high = -low
        for corner in [SIMD2(0.0, 0), SIMD2(1, 0), SIMD2(0, 1), SIMD2(1, 1)] {
            let p = SIMD2<Double>(u.origin) + corner * SIMD2<Double>(u.size)
            let pivot = SIMD2<Double>(u.pivot), d = (p - pivot) * Double(u.scale)
            let (c, s) = (Double(u.rotation.x), Double(u.rotation.y))
            let q = pivot + SIMD2(d.x * c - d.y * s, d.x * s + d.y * c)
            let o = (q - SIMD2<Double>(u.stageCenter)) * Double(u.depth) + SIMD2<Double>(u.outputCenter)
            low = simd_min(low, o)
            high = simd_max(high, o)
        }
        guard [low.x, low.y, high.x, high.y].allSatisfy(\.isFinite) else { return false }
        return high.x > 0 && high.y > 0 && low.x < viewport.x && low.y < viewport.y
    }
}
