// SPDX-License-Identifier: GPL-3.0-or-later
import Metal
import ProjectFormat

/// The pipelines of the keys on screen (phase 2 design §7.4, `keyOverlay-1`), made with the compositor's
/// (`LayerPipelines`): their texture, premultiplied, read one texel a pixel at the item's opacity (`keyOverlayFragment`),
/// into the target, a subsample's attachment and the motion blur's target (`keyOverlayTargetFragment`); and the textures
/// themselves (`KeyOverlayTexture`), drawn once for each content and size and kept.
struct KeyPipelines {
    let target: any MTLRenderPipelineState
    let subsample: any MTLRenderPipelineState
    let blurTarget: any MTLRenderPipelineState
    let textures: KeyOverlayTexture

    init(maker: PipelineMaker) throws {
        target = try maker.pipeline(
            vertex: "quadVertex", fragment: "keyOverlayFragment", blending: .over, into: LayerPass.target.attachments)
        subsample = try maker.pipeline(
            vertex: "quadVertex", fragment: "keyOverlayFragment", blending: .over, into: LayerPass.subsample.attachments)
        blurTarget = try maker.pipeline(
            vertex: "quadVertex", fragment: "keyOverlayTargetFragment", blending: .over, into: LayerPass.blurTarget.attachments)
        textures = KeyOverlayTexture(device: maker.device)
    }

    /// The pipeline of `pass`.
    func pipeline(for pass: LayerPass) -> any MTLRenderPipelineState {
        switch pass {
        case .target: target
        case .subsample: subsample
        case .blurTarget: blurTarget
        }
    }
}

extension Compositor {
    /// Draws the keys `layer` in output space in an output of `outputSize`, into `pass`, counting each item drawn in
    /// `counts.keyOverlays`: step 5 of phase 2 design §11, over the camera and under the captions (`drawOverlays`), never
    /// blurred. Each item in order (the one going first under the one coming), its texture (`KeyOverlayTexture`, made
    /// now the first time its content is drawn at its size) from its rect's top-left pixel, one texel a pixel, at its
    /// opacity. Nothing without a layer, nor for an item hidden (its opacity not above 0) or whose region is not a size;
    /// nor, then, when CoreGraphics or Metal cannot make its texture (out of memory): the frame is drawn without it.
    func drawKeys(
        _ layer: KeyOverlayLayer?, outputSize: SIMD2<Int>, pass: LayerPass, encoder: any MTLRenderCommandEncoder,
        counts: inout DrawCounts
    ) {
        guard let layer else { return }
        let viewport = SIMD2(Float(outputSize.x), Float(outputSize.y))
        for item in layer.items {
            var opacity = Float(item.opacity.isNaN ? 0 : min(max(item.opacity, 0), 1))
            guard opacity > 0, let region = KeyOverlayTexture.region(of: item),
                  let texture = try? layers.keys.textures.texture(for: item)
            else { continue }
            let origin = SIMD2<Float>(region.origin), size = SIMD2(Float(texture.width), Float(texture.height))
            var quad = QuadUniforms(
                viewport: viewport, origin: origin, size: size, contentOrigin: origin, contentSize: size, uvOrigin: .zero,
                uvSize: .one, radius: 0)
            encoder.setRenderPipelineState(layers.keys.pipeline(for: pass))
            encoder.setVertexBytes(&quad, length: MemoryLayout<QuadUniforms>.stride, index: 0)
            encoder.setFragmentBytes(&quad, length: MemoryLayout<QuadUniforms>.stride, index: 0)
            encoder.setFragmentBytes(&opacity, length: MemoryLayout<Float>.stride, index: 1)
            encoder.setFragmentTexture(texture, index: 0)
            encoder.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
            counts.keyOverlays += 1
        }
    }
}
