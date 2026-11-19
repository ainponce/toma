// SPDX-License-Identifier: GPL-3.0-or-later
import Metal
import ProjectFormat

/// The pipelines of the screen with its privacy regions (phase 2 design §7.1, `privacy-1`), made with the compositor's
/// (`LayerPipelines`): the screen's shader with the regions (`ShaderSource.privacyMetal`), straight into the target, into
/// a subsample of the motion blur's pass and into its target, each also cut to a card. Blended "over", as the screen's
/// own.
struct PrivacyPipelines {
    let screen: any MTLRenderPipelineState
    let clippedScreen: any MTLRenderPipelineState
    let subsample: any MTLRenderPipelineState
    let clippedSubsample: any MTLRenderPipelineState
    let blurTarget: any MTLRenderPipelineState
    let clippedBlurTarget: any MTLRenderPipelineState

    init(maker: PipelineMaker) throws {
        func pipeline(_ fragment: String, _ pass: LayerPass) throws -> any MTLRenderPipelineState {
            try maker.pipeline(vertex: "quadVertex", fragment: fragment, blending: .over, into: pass.attachments)
        }
        screen = try pipeline("privacyScreenFragment", .target)
        clippedScreen = try pipeline("clippedPrivacyScreenFragment", .target)
        subsample = try pipeline("privacyScreenFragment", .subsample)
        clippedSubsample = try pipeline("clippedPrivacyScreenFragment", .subsample)
        blurTarget = try pipeline("privacyScreenTargetFragment", .blurTarget)
        clippedBlurTarget = try pipeline("clippedPrivacyScreenTargetFragment", .blurTarget)
    }
}

/// `PrivacyUniforms` in `ShaderSource.privacyMetal`: a header of 16 bytes (its `count`, a `uint`, in the first 4), then 8
/// regions of three `float4` each, their rect, their colour and their effect and strength. 400 bytes.
enum PrivacyUniforms {
    static let regionFloats = 3
    static let length = MemoryLayout<SIMD4<Float>>.stride * (1 + PrivacyRegion.maxPerFrame * regionFloats)

    /// What the shader reads of `regions`: the first `PrivacyRegion.maxPerFrame` of them (the scene never gives more), the
    /// rest of the 8 zeros. A strength that is not a number is 1 and a colour's that is not is 0, each read from 0 to 1; a
    /// rect that is not finite covers the whole layer, so a region never hides less for it.
    static func values(of regions: [PrivacyRegion]) -> [SIMD4<Float>] {
        let shown = regions.prefix(PrivacyRegion.maxPerFrame)
        var values = [SIMD4<Float>](repeating: .zero, count: 1 + PrivacyRegion.maxPerFrame * regionFloats)
        values.withUnsafeMutableBytes { $0.storeBytes(of: UInt32(shown.count), toByteOffset: 0, as: UInt32.self) }
        func unit(_ value: Float, notANumber: Float) -> Float { value.isNaN ? notANumber : min(max(value, 0), 1) }
        for (k, region) in shown.enumerated() {
            let rect = [region.rect.x, region.rect.y, region.rect.width, region.rect.height].allSatisfy(\.isFinite)
                ? region.rect : Rect(x: 0, y: 0, width: 1, height: 1)
            let effect: Float = switch region.effect {
            case .blur: 0
            case .pixelate: 1
            case .fill: 2
            }
            let color = region.color
            values[1 + k * regionFloats] = SIMD4(Float(rect.x), Float(rect.y), Float(rect.width), Float(rect.height))
            values[2 + k * regionFloats] = SIMD4(
                unit(color.x, notANumber: 0), unit(color.y, notANumber: 0), unit(color.z, notANumber: 0), 1)
            values[3 + k * regionFloats] = SIMD4(effect, unit(Float(region.strength), notANumber: 1), 0, 0)
        }
        return values
    }
}

extension Compositor {
    /// The pipeline the screen `layer` is drawn with for its privacy regions (`ScreenLayer.privacy`), in `drawStage`, step
    /// 2 of phase 2 design §11: cut to a card with `clipped`, into `pass`. `nil`, without regions: the screen's own
    /// pipeline of phase 1, and `bindPrivacy` is not called. The same pipeline whether it is sampled from mipmaps or not
    /// (`mipmapped`): the shader reads the levels its texture has, and blurs and pixelates nothing without them.
    func privacyScreenPipeline(
        for layer: ScreenLayer, clipped: Bool, mipmapped: Bool, pass: LayerPass
    ) -> (any MTLRenderPipelineState)? {
        guard !layer.privacy.isEmpty else { return nil }
        let pipelines = layers.privacy
        switch pass {
        case .target: return clipped ? pipelines.clippedScreen : pipelines.screen
        case .subsample: return clipped ? pipelines.clippedSubsample : pipelines.subsample
        case .blurTarget: return clipped ? pipelines.clippedBlurTarget : pipelines.blurTarget
        }
    }

    /// Binds `regions` for the pipeline `privacyScreenPipeline` gave, right before the screen is drawn with it: as
    /// `PrivacyUniforms` at fragment buffer 3, which the screen's own drawing does not set, so the binding stays through
    /// `setRenderPipelineState`.
    func bindPrivacy(_ regions: [PrivacyRegion], encoder: any MTLRenderCommandEncoder) {
        let values = PrivacyUniforms.values(of: regions)
        values.withUnsafeBytes { bytes in
            precondition(bytes.count == PrivacyUniforms.length, "PrivacyUniforms must keep the layout of the shaders' struct: 400 bytes")
            encoder.setFragmentBytes(bytes.baseAddress!, length: bytes.count, index: 3)
        }
    }

    /// What the screen `layer` (`RenderFrame.screen` or `previousScreen`) samples of its frame `frame`
    /// (`image(of:in:commandBuffer:)`), made before the render pass. A layer with privacy regions is always drawn from its
    /// copy with mipmaps, which its blur and its pixels are made from, whatever its sampling (plan 2c decision 3); when
    /// Metal cannot make the copy (`RenderError.metalResourceUnavailable`), it fails closed: `layer` is drawn from its frame,
    /// bilinear, and each of its regions is filled black, so nothing it hides is ever drawn. `layer` is left as it is drawn.
    /// `nil` without a layer or a frame, and for a crop that is not finite.
    func screenImage(
        of layer: inout ScreenLayer?, in frame: (any MTLTexture)?, commandBuffer: any MTLCommandBuffer
    ) throws -> ScreenImage? {
        guard var drawn = layer, let frame else { return nil }
        guard !drawn.privacy.isEmpty else { return try image(of: drawn, in: frame, commandBuffer: commandBuffer) }
        drawn.mipmapped = true
        do {
            let image = try image(of: drawn, in: frame, commandBuffer: commandBuffer)
            layer = drawn
            return image
        } catch RenderError.metalResourceUnavailable {
            drawn.mipmapped = false
            drawn.privacy = drawn.privacy.map { region in
                PrivacyRegion(rect: region.rect, effect: .fill, strength: region.strength, color: SIMD4(0, 0, 0, 1))
            }
            layer = drawn
            return try image(of: drawn, in: frame, commandBuffer: commandBuffer)
        }
    }

    /// Makes every copy with mipmaps of the screen fail as when Metal cannot make one, with `failing`: for tests.
    func makeScreenCopiesFail(_ failing: Bool) {
        mipmappedCopies.failsForTests = failing
    }
}
