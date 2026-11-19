// SPDX-License-Identifier: GPL-3.0-or-later
import Metal
import ProjectFormat

/// The zoom inside the screen's card (1c design §5.4 and §14.2): a frame in a card's mode (`RenderFrame.card` and
/// `backgroundTransform`) draws its background, its shadow and its window frame through the background's transform, and
/// its screens, its cursor and its click effects through the card's content, cut to the card; then the camera, as always.
///
/// - Without a motion blur, in one render pass, as the stage is drawn.
/// - With the zoom's (`subframes`), in the motion blur's pass: each subsample is the card's content alone, over nothing,
///   through its transform, added to the sum; then the rest of the stage is drawn once into the subsample and the
///   average goes over it into the target (`resolveCursorFragment`). So the background is the same bytes as without the
///   blur, and only the card is blurred.
/// - With the cursor's (`cursorSamples`), as 1b's: the stage drawn once, the cursor's samples cut to the card added to
///   the sum, and their average over the stage.
extension Compositor {
    /// Which parts of the stage `drawStage` draws.
    struct StageParts: OptionSet {
        let rawValue: Int
        /// The background, the shadow and the window frame.
        static let frame = StageParts(rawValue: 1)
        /// The screens and the cursor.
        static let content = StageParts(rawValue: 2)
        static let all: StageParts = [.frame, .content]
    }

    /// How a card's content is drawn (`RenderFrame.card`): through `transform` (as it is when `nil`), cut to `clip`, the
    /// image of a quad (`imageCoverage`): all of it for the screens, `strength` of it (0 to 1) for what can go past the
    /// screen's edge, the cursor and the click effects.
    struct CardContent {
        var transform: StageTransform?
        var clip: QuadUniforms
        var strength: Float
    }

    /// How `frame`'s card content is drawn: through `card.content`, cut to the card's rect with its corners and, with a
    /// window frame, by the window drawn through the background's transform, as the screen under its bar is cut; by
    /// `card.mix`, read from 0 to 1 (0 if not a number), of the cut for the cursor and the click effects. `nil` without a
    /// card.
    static func cardContent(of frame: RenderFrame) -> CardContent? {
        guard let card = frame.card else { return nil }
        let size = frame.outputSize, viewport = SIMD2<Float>(Float(size.x), Float(size.y))
        let background = moving(frame.backgroundTransform, outputSize: size)
        let window = frame.windowFrame.map { background?.drawn($0, outputSize: size) ?? $0 }
        let clip = window.map { window in
            imageQuad(
                in: card.rect, cornerRadius: window.cornerRadius, uvOrigin: .zero, uvSize: .one,
                shape: (window.rect, bottomRadius: window.bottomCornerRadius, imageTopRadius: window.screenTopCornerRadius),
                viewport: viewport)
        } ?? shape(card.rect, cornerRadius: card.cornerRadius, viewport: viewport)
        let strength = card.mix.isNaN ? 0 : min(max(card.mix, 0), 1)
        return CardContent(transform: moving(card.content, outputSize: size), clip: clip, strength: Float(strength))
    }

    /// Sets `content`'s cut as the fragment's buffers `index` (the clip) and `index + 1` (its strength).
    static func setClip(_ content: CardContent, at index: Int, encoder: any MTLRenderCommandEncoder) {
        var clip = content.clip, strength = content.strength
        encoder.setFragmentBytes(&clip, length: MemoryLayout<QuadUniforms>.stride, index: index)
        encoder.setFragmentBytes(&strength, length: MemoryLayout<Float>.stride, index: index + 1)
    }

    /// Encodes `frame`, in a card's mode, into `target` (see the extension's notes), with `textures`, the camera's texture
    /// `camera` and what its colour and background are drawn with, `cameraLook`, and the blur's `tileMemory` (`nil` without
    /// a blur), counting what it draws in `counts`. The background is drawn once, as without the blur, so a sharp
    /// wallpaper's mesh is not asked for (`FrameRenderer.backgroundTexture`); the device frame goes with it, its island or
    /// notch through the background's transform too.
    func encodeCard(
        _ frame: RenderFrame, textures: StageTextures, camera: (any MTLTexture)?, cameraLook: CameraLookTextures?,
        tileMemory: (subsample: any MTLTexture, sum: any MTLTexture)?, into target: any MTLTexture,
        commandBuffer: any MTLCommandBuffer, counts: inout DrawCounts
    ) {
        let background = Self.moving(frame.backgroundTransform, outputSize: frame.outputSize)
        let card = Self.cardContent(of: frame)
        // What the content and the click effects are drawn through: the card's content, or the background without one.
        let content = card.map(\.transform) ?? background
        let targetSize = SIMD2(target.width, target.height)

        guard let tileMemory else {
            let encoder = renderPass(into: target, commandBuffer: commandBuffer)
            counts.renderPasses += 1
            drawStage(
                frame, through: background, card: card, cursor: frame.cursor, textures: textures, pipelines: direct,
                targetSize: targetSize, encoder: encoder, counts: &counts)
            drawOverTheStage(
                frame, through: content, card: card, device: background, camera: camera, cameraLook: cameraLook,
                clickEffect: card == nil ? clickEffectPipeline : clippedClickEffectPipeline, cameraPipelines: directCamera,
                encoder: encoder, counts: &counts)
            encoder.endEncoding()
            return
        }
        let encoder = blurPass(into: target, tileMemory: tileMemory, commandBuffer: commandBuffer)
        counts.renderPasses += 1
        if !frame.subframes.isEmpty {
            var weight = Float(1 / Double(frame.subframes.count))
            for subframe in frame.subframes {
                // The card's content alone, over nothing, through the subframe's transform.
                encoder.setRenderPipelineState(blur.clear)
                encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
                var through = card
                through?.transform = Self.moving(subframe.stage, outputSize: frame.outputSize)
                drawStage(
                    frame, through: background, card: through, parts: .content, cursor: subframe.cursor, textures: textures,
                    pipelines: subsample, targetSize: targetSize, encoder: encoder, counts: &counts)
                encoder.setRenderPipelineState(blur.accumulate)
                encoder.setFragmentBytes(&weight, length: MemoryLayout<Float>.stride, index: 0)
                encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
                counts.accumulations += 1
            }
            // The rest of the stage, once, under the content's average.
            drawStage(
                frame, through: background, card: card, parts: .frame, cursor: nil, textures: textures, pipelines: subsample,
                targetSize: targetSize, encoder: encoder, counts: &counts)
        } else {
            drawStage(
                frame, through: background, card: card, cursor: nil, textures: textures, pipelines: subsample, culling: true,
                targetSize: targetSize, encoder: encoder, counts: &counts)
            let share = 1 / Double(frame.cursorSamples.count)
            for layer in frame.cursorSamples {
                drawCursor(
                    layer, through: content, outputSize: frame.outputSize, share: share, texture: textures.cursor, clip: card,
                    pipeline: card == nil ? blur.cursorSample : blur.clippedCursorSample, encoder: encoder, counts: &counts)
            }
        }
        // The average over the stage drawn once, into the target.
        encoder.setRenderPipelineState(blur.resolveCursor)
        encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
        drawOverTheStage(
            frame, through: content, card: card, device: background, camera: camera, cameraLook: cameraLook,
            clickEffect: card == nil ? blur.clickEffect : blur.clippedClickEffect, cameraPipelines: blur.camera,
            encoder: encoder, counts: &counts)
        encoder.endEncoding()
    }
}
