// SPDX-License-Identifier: GPL-3.0-or-later
import Metal

/// Makes the compositor's pipelines from its compiled library (`ShaderSource.metal`): phase 1's, in `Compositor.init`,
/// and those of phase 2's layers (`LayerPipelines`), each with the same descriptors as ever.
struct PipelineMaker {
    let device: any MTLDevice
    let library: any MTLLibrary

    /// The function `name` of the library. Throws `RenderError.missingShaderFunction` without one.
    func function(_ name: String) throws -> any MTLFunction {
        guard let function = library.makeFunction(name: name) else { throw RenderError.missingShaderFunction(name) }
        return function
    }

    /// The pipeline of the functions `vertex` and `fragment` that draws into `attachments` (`.bgra8Unorm` alone, or the
    /// motion blur's pass, writing only one of them) and blends what it draws as `blending` says. Throws what Metal throws.
    func pipeline(
        vertex: String, fragment: String, blending: Blending, into attachments: Attachments = .target
    ) throws -> any MTLRenderPipelineState {
        let descriptor = MTLRenderPipelineDescriptor()
        descriptor.vertexFunction = try function(vertex)
        descriptor.fragmentFunction = try function(fragment)
        let written: Int
        switch attachments {
        case .target:
            descriptor.colorAttachments[0].pixelFormat = Compositor.pixelFormat
            written = 0
        case let .blurPass(index):
            for (i, format) in [Compositor.pixelFormat, Compositor.sumFormat, Compositor.pixelFormat].enumerated() {
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
}

/// The pass a drawing is in, and so the attachments its pipelines draw into: what `StagePipelines` and `CameraPipelines`
/// carry, so a layer drawn with them picks its own pipeline of the same pass.
enum LayerPass {
    /// Straight into the target, without a motion blur: `Compositor.direct` and `directCamera`.
    case target
    /// Into a subsample of the motion blur's pass (attachment 0): the stage's, `Compositor.subsample`.
    case subsample
    /// Into the target of the motion blur's pass (attachment 2): what goes over the average, `BlurPipelines`.
    case blurTarget

    /// The attachments a pipeline of the pass draws into.
    var attachments: Attachments {
        switch self {
        case .target: .target
        case .subsample: .blurPass(writing: 0)
        case .blurTarget: .blurPass(writing: 2)
        }
    }
}

/// The pipelines of phase 2's layers (phase 2 design §11 and §12), each in its layer's file (`Compositor+<Layer>.swift`),
/// built at the end of `Compositor.init` with its `PipelineMaker`: none in the base of phase 2.
struct LayerPipelines {
    let captions: CaptionPipelines
    let keys: KeyPipelines
    let privacy: PrivacyPipelines
    let cameraLook: CameraLookPipelines
    let deviceFrame: DeviceFramePipelines

    init(maker: PipelineMaker) throws {
        deviceFrame = try DeviceFramePipelines(maker: maker)
        privacy = try PrivacyPipelines(maker: maker)
        cameraLook = try CameraLookPipelines(maker: maker)
        keys = try KeyPipelines(maker: maker)
        captions = try CaptionPipelines(maker: maker)
    }
}

extension Compositor {
    /// Steps 5 and 6 of phase 2 design §11, over the camera, into `pass`: the keys of `frame`, then its captions, and the
    /// textures of its captions ahead drawn in the background (`CaptionTextures.prepare`), which draws nothing into the
    /// frame. Every frame reaches it once (`DrawCounts.overlaySteps`), whatever its path; with neither, nothing is drawn.
    func drawOverlays(_ frame: RenderFrame, pass: LayerPass, encoder: any MTLRenderCommandEncoder, counts: inout DrawCounts) {
        counts.overlaySteps += 1
        drawKeys(frame.keys, outputSize: frame.outputSize, pass: pass, encoder: encoder, counts: &counts)
        drawCaptions(frame.captions, outputSize: frame.outputSize, pass: pass, encoder: encoder, counts: &counts)
        layers.captions.textures.prepare(frame.captionsAhead, device: device)
    }
}
