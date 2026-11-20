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
/// themselves, kept. Images and clips (plan 3a decisions 4 and 13) are drawn in the same loop with their own textures, by
/// the overlay's pipelines (`overlayVertex`, `overlayFragment` and the others), into the same passes.
struct AnnotationPipelines {
    private let target: any MTLRenderPipelineState
    private let blurTarget: any MTLRenderPipelineState
    private let clippedTarget: any MTLRenderPipelineState
    private let clippedBlurTarget: any MTLRenderPipelineState
    private let overlayTarget: any MTLRenderPipelineState
    private let overlayBlurTarget: any MTLRenderPipelineState
    private let clippedOverlayTarget: any MTLRenderPipelineState
    private let clippedOverlayBlurTarget: any MTLRenderPipelineState
    let rasters: AnnotationRasters

    init(maker: PipelineMaker) throws {
        precondition(
            MemoryLayout<AnnotationUniforms>.stride == 72, "AnnotationUniforms must keep the layout of the shaders' struct: 72 bytes")
        precondition(
            MemoryLayout<OverlayUniforms>.stride == 128, "OverlayUniforms must keep the layout of the shaders' struct: 128 bytes")
        precondition(
            MemoryLayout<OverlayShadowUniforms>.stride == 32,
            "OverlayShadowUniforms must keep the layout of the shaders' ShadowUniforms: 32 bytes")
        target = try maker.pipeline(
            vertex: "annotationVertex", fragment: "annotationFragment", blending: .over, into: LayerPass.target.attachments)
        blurTarget = try maker.pipeline(
            vertex: "annotationVertex", fragment: "annotationTargetFragment", blending: .over, into: LayerPass.blurTarget.attachments)
        clippedTarget = try maker.pipeline(
            vertex: "annotationVertex", fragment: "clippedAnnotationFragment", blending: .over, into: LayerPass.target.attachments)
        clippedBlurTarget = try maker.pipeline(
            vertex: "annotationVertex", fragment: "clippedAnnotationTargetFragment", blending: .over,
            into: LayerPass.blurTarget.attachments)
        overlayTarget = try maker.pipeline(
            vertex: "overlayVertex", fragment: "overlayFragment", blending: .over, into: LayerPass.target.attachments)
        overlayBlurTarget = try maker.pipeline(
            vertex: "overlayVertex", fragment: "overlayTargetFragment", blending: .over, into: LayerPass.blurTarget.attachments)
        clippedOverlayTarget = try maker.pipeline(
            vertex: "overlayVertex", fragment: "clippedOverlayFragment", blending: .over, into: LayerPass.target.attachments)
        clippedOverlayBlurTarget = try maker.pipeline(
            vertex: "overlayVertex", fragment: "clippedOverlayTargetFragment", blending: .over,
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

    /// The pipeline of an image or a clip in `pass`, over the stage, cut to a card with `clipped`.
    func overlayPipeline(for pass: LayerPass, clipped: Bool) -> any MTLRenderPipelineState {
        switch pass {
        case .target: clipped ? clippedOverlayTarget : overlayTarget
        case .blurTarget: clipped ? clippedOverlayBlurTarget : overlayBlurTarget
        case .subsample: preconditionFailure("The annotations are drawn over the stage, never into a subsample of it")
        }
    }
}

/// What a frame's annotations are drawn with besides their own bitmaps (plan 3a decision 13): the images it shows, by
/// asset (`OverlayImageTextures`, with mipmaps), and the frames of its clips the renderer decoded for them, by the layer's
/// id, with how a player turns each upright (`MediaOrientation`); from
/// `FrameRenderer.annotationTextures(for:decoded:commandBuffer:)`. A layer without its texture is not drawn: an image
/// that is missing or cannot be read, a clip whose file cannot be read. `nil` draws none of them. They must stay alive
/// until the command buffer they are drawn in completes.
struct AnnotationTextures {
    var images: [String: any MTLTexture] = [:]
    var clips: [String: any MTLTexture] = [:]
    /// How each clip's frame is turned upright, by the layer's id: as decoded when missing.
    var orientations: [String: MediaOrientation] = [:]

    var isEmpty: Bool { images.isEmpty && clips.isEmpty }
}

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
            layers, through: stage, zoomed: true, clip: card, textures: textures, outputSize: outputSize, pass: pass, encoder: encoder)
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
            layers, through: nil, zoomed: false, clip: nil, textures: textures, outputSize: outputSize, pass: pass, encoder: encoder)
    }

    /// Draws `layers` in their order through `stage`, at the zoom's scale with `zoomed` (at 1 otherwise), cut to `clip`, and
    /// returns how many it drew: the bitmaps, and the images and clips with `textures` (`drawOverlay`). Nothing of a layer
    /// at opacity 0 (or not a number), of one whose region falls outside the output, nor of one without a texture (nothing
    /// to draw, or CoreGraphics or Metal could not make it, an image or a clip that cannot be read: the frame is drawn
    /// without it); so no bitmap is made of the first two. The pipeline, the sampler and the cut are set before the first
    /// drawn of a kind, and not again while nothing of the other kind is drawn between them.
    private func drawAnnotations(
        _ layers: [AnnotationLayer], through stage: StageTransform?, zoomed: Bool, clip: CardContent?, textures: AnnotationTextures?,
        outputSize: SIMD2<Int>, pass: LayerPass, encoder: any MTLRenderCommandEncoder
    ) -> Int {
        let pipelines = self.layers.annotations
        let viewport = SIMD2<Double>(outputSize)
        let depth = stage?.depth ?? 1
        var drawn = 0
        // Whether the bitmaps' pipeline, sampler and cut are bound, or the images' and clips' pipeline and cut: each kind
        // binds its own, and unbinds the other's.
        var bound = false
        var overlayBound = false
        for layer in layers {
            let picture: OverlayPicture
            switch layer.content {
            case let .image(image):
                guard let texture = textures?.images[image.asset] else { continue }
                picture = OverlayPicture(
                    texture: texture, orientation: .upright, fit: image.fit, corner: image.corner, shadow: image.shadow, opaque: false)
            case let .clip(clipLayer, _):
                guard let texture = textures?.clips[layer.id] else { continue }
                picture = OverlayPicture(
                    texture: texture, orientation: textures?.orientations[layer.id] ?? .upright, fit: .fit, corner: clipLayer.corner,
                    shadow: clipLayer.shadow, opaque: true)
            case .text, .arrow, .shape, .callout, .step:
                if drawBitmap(
                    layer, through: stage, zoomed: zoomed, depth: depth, clip: clip, viewport: viewport, outputSize: outputSize,
                    pass: pass, bound: &bound, encoder: encoder)
                {
                    drawn += 1
                    overlayBound = false
                }
                continue
            }
            guard var uniforms = Self.overlayUniforms(layer, picture, through: stage, outputSize: outputSize),
                Self.covers(uniforms.quad, viewport: viewport)
            else { continue }
            if !overlayBound {
                encoder.setRenderPipelineState(pipelines.overlayPipeline(for: pass, clipped: clip != nil))
                if let clip { Self.setClip(clip, at: 2, encoder: encoder) }
                overlayBound = true
                bound = false
            }
            encoder.setVertexBytes(&uniforms.overlay, length: MemoryLayout<OverlayUniforms>.stride, index: 0)
            encoder.setFragmentBytes(&uniforms.overlay, length: MemoryLayout<OverlayUniforms>.stride, index: 0)
            encoder.setFragmentBytes(&uniforms.shadow, length: MemoryLayout<OverlayShadowUniforms>.stride, index: 1)
            encoder.setFragmentTexture(picture.texture, index: 0)
            // An image's mipmaps; a clip's frame has none.
            encoder.setFragmentSamplerState(picture.opaque ? screenSampler : trilinearSampler, index: 0)
            encoder.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
            drawn += 1
        }
        return drawn
    }

    /// Draws the bitmap of `layer`, a text, an arrow, a shape, a speech bubble or a step, through `stage` (`drawAnnotations`),
    /// binding the bitmaps' pipeline, sampler and cut unless `bound`; whether it drew it.
    private func drawBitmap(
        _ layer: AnnotationLayer, through stage: StageTransform?, zoomed: Bool, depth: Double, clip: CardContent?,
        viewport: SIMD2<Double>, outputSize: SIMD2<Int>, pass: LayerPass, bound: inout Bool, encoder: any MTLRenderCommandEncoder
    ) -> Bool {
        let pipelines = self.layers.annotations
        guard layer.opacity > 0, layer.scale > 0, layer.scale.isFinite else { return false }
        let scale = zoomed ? AnnotationRaster.scale(for: layer, depth: depth) : 1
        guard let region = AnnotationRaster.region(of: layer, scale: scale) else { return false }
        var uniforms = Self.annotationUniforms(layer, region: region, through: stage, rasterScale: scale, outputSize: outputSize)
        guard Self.covers(uniforms, viewport: viewport),
            let made = try? pipelines.rasters.texture(for: layer, scale: scale, device: device)
        else { return false }
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
        return true
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

    /// How the image or the clip `picture` of `layer` is drawn (plan 3a decisions 4, 6 and 13), through `stage`: the
    /// picture fitted whole into the layer's box with its upright proportion (`.fit`, centred) or covering it (`.fill`, its
    /// middle cropped); its corners `corner` (0 to 0.5) of the box's shorter side, at most half the picture's; with
    /// `shadow`, black at 45 % of σ 0.02 of the box's shorter side, 0.01 of it down the output (whatever the layer's
    /// rotation), its quad reaching 3σ and the offset past the picture; popped and rotated about the centre of the box,
    /// at its opacity. And the quad as `annotationVertex` would draw it, for `covers`. `nil` for a layer that draws
    /// nothing: at opacity 0 or not a number, of no size, or with a texture of no size.
    static func overlayUniforms(
        _ layer: AnnotationLayer, _ picture: OverlayPicture, through stage: StageTransform?, outputSize: SIMD2<Int>
    ) -> (overlay: OverlayUniforms, shadow: OverlayShadowUniforms, quad: AnnotationUniforms)? {
        let box = layer.rect
        let textureSize = SIMD2(Double(picture.texture.width), Double(picture.texture.height))
        let upright = picture.orientation.uprightSize(of: textureSize)
        guard layer.opacity > 0, layer.scale > 0, layer.scale.isFinite,
            [box.x, box.y, box.width, box.height].allSatisfy(\.isFinite), box.width > 0, box.height > 0,
            upright.x > 0, upright.y > 0
        else { return nil }
        let depth = stage?.depth ?? 1
        let pixels = layer.scale * depth
        guard pixels.isFinite, pixels > 0 else { return nil }
        // The picture's rect and the part of it shown (upright fractions).
        var rect = box
        var crop = (origin: SIMD2<Float>.zero, size: SIMD2<Float>.one)
        switch picture.fit {
        case .fit:
            let scale = min(box.width / upright.x, box.height / upright.y)
            let size = upright * scale
            rect = Rect(x: box.x + (box.width - size.x) / 2, y: box.y + (box.height - size.y) / 2, width: size.x, height: size.y)
        case .fill:
            crop = Compositor.aspectFill(upright, in: box)
        }
        let shorter = min(box.width, box.height)
        let corner = picture.corner.isFinite ? min(max(picture.corner, 0), 0.5) : 0
        let radius = corner * shorter
        let degrees = layer.rotation.isFinite ? layer.rotation.truncatingRemainder(dividingBy: 360) : 0
        let radians = degrees * .pi / 180
        let (cosine, sine) = degrees == 0 ? (1.0, 0.0) : (cos(radians), sin(radians))
        // The shadow, in the layer's coordinates: down the output is (sin, cos) of them, as the layer turns clockwise.
        var shadow = OverlayShadowUniforms(lower: .zero, upper: .zero, sigma: 1, corner: 0, opacity: 0)
        var reach = 1 / pixels
        if picture.shadow, let made = ShadowMath.Box(ShadowLayer(
            rect: Rect(x: rect.x + Self.overlayShadowOffset * shorter * sine, y: rect.y, width: rect.width, height: rect.height),
            cornerRadius: radius, opacity: Self.overlayShadowOpacity, sigma: Self.overlayShadowSigma * shorter,
            offsetY: Self.overlayShadowOffset * shorter * cosine))
        {
            shadow = OverlayShadowUniforms(lower: made.lower, upper: made.upper, sigma: made.sigma, corner: made.corner, opacity: made.opacity)
            reach += 3 * Self.overlayShadowSigma * shorter + Self.overlayShadowOffset * shorter
        }
        let quad = Rect(x: rect.x - reach, y: rect.y - reach, width: rect.width + 2 * reach, height: rect.height + 2 * reach)
        let o = picture.orientation
        let texOrigin = o.origin + crop.origin.x * o.across + crop.origin.y * o.down
        let half = SIMD2<Double>(outputSize) / 2
        let pivot = SIMD2<Float>(Float(box.x + box.width / 2), Float(box.y + box.height / 2))
        let rotation = SIMD2<Float>(Float(cosine), Float(sine))
        let stageCenter = SIMD2<Float>(stage?.center ?? half)
        let overlay = OverlayUniforms(
            viewport: SIMD2<Float>(Float(outputSize.x), Float(outputSize.y)),
            origin: SIMD2<Float>(Float(quad.x), Float(quad.y)), size: SIMD2<Float>(Float(quad.width), Float(quad.height)),
            pivot: pivot, rotation: rotation, stageCenter: stageCenter, outputCenter: SIMD2<Float>(half),
            pictureOrigin: SIMD2<Float>(Float(rect.x), Float(rect.y)), pictureSize: SIMD2<Float>(Float(rect.width), Float(rect.height)),
            texOrigin: texOrigin, texAcross: crop.size.x * o.across, texDown: crop.size.y * o.down, depth: Float(depth),
            scale: Float(layer.scale), opacity: Float(min(layer.opacity, 1)), radius: Float(radius), pixels: Float(pixels),
            shadow: picture.shadow && shadow.opacity > 0 ? 1 : 0, opaque: picture.opaque ? 1 : 0)
        let corners = AnnotationUniforms(
            viewport: overlay.viewport, origin: overlay.origin, size: overlay.size, pivot: pivot, rotation: rotation,
            stageCenter: stageCenter, outputCenter: overlay.outputCenter, depth: overlay.depth, scale: overlay.scale,
            opacity: overlay.opacity, exact: 0)
        return (overlay, shadow, corners)
    }

    /// An image's or a clip's shadow (plan 3a decision 4): black at 45 %, σ 0.02 of its box's shorter side and 0.01 of it
    /// down.
    static let overlayShadowOpacity = 0.45
    static let overlayShadowSigma = 0.02
    static let overlayShadowOffset = 0.01

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

/// What an image or a clip of the annotations is drawn from (`Compositor.overlayUniforms`): its texture, how a player turns
/// it upright (a clip's), how it fills its box, its corners (0 to 0.5 of the box's shorter side) and whether it casts its
/// shadow; a clip's frame is opaque.
struct OverlayPicture {
    var texture: any MTLTexture
    var orientation: MediaOrientation
    var fit: ImageFit
    var corner: Double
    var shadow: Bool
    var opaque: Bool
}

/// `OverlayUniforms` in `ShaderSource.annotationsMetal`: 128 bytes. How an image or a clip is drawn: its quad and its
/// picture's rect in the layer's coordinates, popped and rotated about `pivot` and through the zoom as an annotation's
/// bitmap (`AnnotationUniforms`), the texture coordinates across the picture, its corners, its shadow and its opacity.
struct OverlayUniforms {
    var viewport: SIMD2<Float>
    var origin: SIMD2<Float>
    var size: SIMD2<Float>
    var pivot: SIMD2<Float>
    var rotation: SIMD2<Float>
    var stageCenter: SIMD2<Float>
    var outputCenter: SIMD2<Float>
    var pictureOrigin: SIMD2<Float>
    var pictureSize: SIMD2<Float>
    var texOrigin: SIMD2<Float>
    var texAcross: SIMD2<Float>
    var texDown: SIMD2<Float>
    var depth: Float
    var scale: Float
    var opacity: Float
    var radius: Float
    var pixels: Float
    var shadow: Float
    var opaque: Float
    var padding: Float = 0
}

/// `ShadowUniforms` in `ShaderSource.coreMetal`: 32 bytes (the compositor's own is private to its file), here in the
/// layer's coordinates.
struct OverlayShadowUniforms {
    var lower: SIMD2<Float>
    var upper: SIMD2<Float>
    var sigma: Float
    var corner: Float
    var opacity: Float
    var padding: Float = 0
}
