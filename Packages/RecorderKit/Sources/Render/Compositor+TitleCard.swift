// SPDX-License-Identifier: GPL-3.0-or-later
import Metal
import ProjectFormat

/// The pipelines of a title card (phase 3 design §5.2 and §12, `titleCard-1`), made with the compositor's
/// (`LayerPipelines`): its fill or veil over the whole target (`titleCardFillFragment`), and its texts' texture,
/// premultiplied, read one texel a pixel at the card's opacity (`titleCardTextFragment`), each straight into the target
/// and into the motion blur's target (`…TargetFragment`), the passes of what goes over the stage; and the textures
/// themselves (`TitleCardTextures`), drawn once for each card and size, and kept.
struct TitleCardPipelines {
    private let fill: any MTLRenderPipelineState
    private let fillBlurTarget: any MTLRenderPipelineState
    private let text: any MTLRenderPipelineState
    private let textBlurTarget: any MTLRenderPipelineState
    let textures: TitleCardTextures

    init(maker: PipelineMaker) throws {
        func pipeline(_ vertex: String, _ fragment: String, _ pass: LayerPass) throws -> any MTLRenderPipelineState {
            try maker.pipeline(vertex: vertex, fragment: fragment, blending: .over, into: pass.attachments)
        }
        fill = try pipeline("gradientVertex", "titleCardFillFragment", .target)
        fillBlurTarget = try pipeline("gradientVertex", "titleCardFillTargetFragment", .blurTarget)
        text = try pipeline("quadVertex", "titleCardTextFragment", .target)
        textBlurTarget = try pipeline("quadVertex", "titleCardTextTargetFragment", .blurTarget)
        textures = TitleCardTextures()
    }

    /// The fill's pipeline of `pass` and the texts', over the stage.
    func pipelines(for pass: LayerPass) -> (fill: any MTLRenderPipelineState, text: any MTLRenderPipelineState) {
        switch pass {
        case .target: (fill, text)
        case .blurTarget: (fillBlurTarget, textBlurTarget)
        case .subsample: preconditionFailure("A title card is drawn over the stage, never into a subsample of it")
        }
    }
}

extension Compositor {
    /// Draws the title card `layer` in output space in an output of `outputSize`, into `pass`, counting it in
    /// `counts.titleCards`: first in `drawOverlays`, over what its frame drew in the place of steps 1 to 6 of phase 3
    /// design §12 and under the output's annotations (base plan decision 9). Its fill (`TitleCardLayer.fill`, premultiplied,
    /// at the layer's opacity times its alpha) or else its veil (black at `scrim` times the opacity) over the whole target,
    /// then its texts' texture (`TitleCardTextures`) over the whole pixels it covers, one texel each, at the opacity.
    /// Nothing without one; nothing of what is at opacity 0; and no texts when there are none, or when CoreGraphics or
    /// Metal cannot make their texture (out of memory): the frame is drawn without them.
    func drawTitleCard(
        _ layer: TitleCardLayer?, outputSize: SIMD2<Int>, pass: LayerPass, encoder: any MTLRenderCommandEncoder,
        counts: inout DrawCounts
    ) {
        guard let layer else { return }
        counts.titleCards += 1
        func unit(_ value: Double) -> Float { value.isNaN ? 0 : Float(min(max(value, 0), 1)) }
        let opacity = unit(layer.opacity)
        guard opacity > 0 else { return }
        let pipelines = layers.titleCard.pipelines(for: pass)
        // The fill or the veil, premultiplied.
        var color: SIMD4<Float>
        if let fill = layer.fill {
            let alpha = unit(fill.a) * opacity
            color = SIMD4(unit(fill.r) * alpha, unit(fill.g) * alpha, unit(fill.b) * alpha, alpha)
        } else {
            color = SIMD4(0, 0, 0, unit(layer.scrim) * opacity)
        }
        if color.w > 0 {
            encoder.setRenderPipelineState(pipelines.fill)
            encoder.setFragmentBytes(&color, length: MemoryLayout<SIMD4<Float>>.stride, index: 0)
            encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
        }
        guard let text = try? layers.titleCard.textures.texture(for: layer, outputSize: outputSize, device: device) else { return }
        let origin = SIMD2<Float>(text.origin), size = SIMD2<Float>(text.size)
        var quad = QuadUniforms(
            viewport: SIMD2(Float(outputSize.x), Float(outputSize.y)), origin: origin, size: size, contentOrigin: origin,
            contentSize: size, uvOrigin: .zero, uvSize: .one, radius: 0)
        var textOpacity = opacity
        encoder.setRenderPipelineState(pipelines.text)
        encoder.setVertexBytes(&quad, length: MemoryLayout<QuadUniforms>.stride, index: 0)
        encoder.setFragmentBytes(&quad, length: MemoryLayout<QuadUniforms>.stride, index: 0)
        encoder.setFragmentBytes(&textOpacity, length: MemoryLayout<Float>.stride, index: 1)
        encoder.setFragmentTexture(text.texture, index: 0)
        encoder.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
    }
}
