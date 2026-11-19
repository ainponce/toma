// SPDX-License-Identifier: GPL-3.0-or-later
import Metal
import ProjectFormat

/// The pipelines of the captions (phase 2 design §5.2, `captionStyle-1`), made with the compositor's (`LayerPipelines`):
/// their texture, premultiplied, read one texel a pixel (`captionFragment`) in the passes of what goes over the stage,
/// straight into the target and into the motion blur's target (`captionTargetFragment`); and the textures themselves
/// (`CaptionTextures`), drawn once for each layer, ahead of its frame when it can be, and kept.
struct CaptionPipelines {
    private let target: any MTLRenderPipelineState
    private let blurTarget: any MTLRenderPipelineState
    let textures: CaptionTextures

    init(maker: PipelineMaker) throws {
        target = try maker.pipeline(vertex: "quadVertex", fragment: "captionFragment", blending: .over, into: LayerPass.target.attachments)
        blurTarget = try maker.pipeline(
            vertex: "quadVertex", fragment: "captionTargetFragment", blending: .over, into: LayerPass.blurTarget.attachments)
        textures = CaptionTextures()
    }

    /// The pipeline of `pass`, over the stage.
    func pipeline(for pass: LayerPass) -> any MTLRenderPipelineState {
        switch pass {
        case .target: target
        case .blurTarget: blurTarget
        case .subsample: preconditionFailure("The captions are drawn over the stage, never into a subsample of it")
        }
    }
}

extension Compositor {
    /// Draws the captions `layer` in output space in an output of `outputSize`, into `pass`, counting it in
    /// `counts.captions`: step 6 of phase 2 design §11, over everything (`drawOverlays`), never blurred. Its texture
    /// (`CaptionTextures`: drawn ahead by an earlier frame, or now the first time the layer is drawn) over its region
    /// (`CaptionTextures.region(of:)`), whole pixels, one texel each. Nothing without one, nor for one with nothing to
    /// draw; nor, then, when CoreGraphics or Metal cannot make its texture (out of memory): the frame is drawn without its
    /// captions.
    func drawCaptions(
        _ layer: CaptionLayer?, outputSize: SIMD2<Int>, pass: LayerPass, encoder: any MTLRenderCommandEncoder,
        counts: inout DrawCounts
    ) {
        guard let layer, let region = CaptionTextures.region(of: layer),
              let texture = try? layers.captions.textures.texture(for: layer, device: device)
        else { return }
        let origin = SIMD2<Float>(region.origin), size = SIMD2<Float>(region.size)
        var quad = QuadUniforms(
            viewport: SIMD2(Float(outputSize.x), Float(outputSize.y)), origin: origin, size: size, contentOrigin: origin,
            contentSize: size, uvOrigin: .zero, uvSize: .one, radius: 0)
        encoder.setRenderPipelineState(layers.captions.pipeline(for: pass))
        encoder.setVertexBytes(&quad, length: MemoryLayout<QuadUniforms>.stride, index: 0)
        encoder.setFragmentBytes(&quad, length: MemoryLayout<QuadUniforms>.stride, index: 0)
        encoder.setFragmentTexture(texture, index: 0)
        encoder.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
        counts.captions += 1
    }
}
