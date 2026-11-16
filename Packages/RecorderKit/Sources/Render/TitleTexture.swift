// SPDX-License-Identifier: GPL-3.0-or-later
import CoreGraphics
import CoreText
import Foundation
import Metal
import ProjectFormat

/// The title of one renderer's window frames (`WindowFrameLayer`): a premultiplied `.bgra8Unorm` texture of the whole
/// pixels the bar touches (`barPixels`), the compositor's to draw at them one texel per pixel, with the title in the
/// system's window-title font at a size of 13/28 of the bar's height (macOS's 13 pt title in its 28 pt bar), black
/// (light) or white (dark) at 85 %, its capitals centred in the bar and the line centred in the window, cut with "…" where
/// it would come closer to the sides than `titleInset` (the buttons).
///
/// CoreText draws it into a `CGContext` of fixed sRGB without font smoothing, without subpixel positioning and
/// antialiased, so the texture depends neither on the system's settings nor on a display: the preview and the export
/// draw the same. The system font itself changes from one macOS to another, and its bytes with it.
///
/// Drawn the first time a title is asked for and kept while the frames ask for the same: only another title, appearance,
/// rect, bar or buttons draws it again (the corners do not change it). An empty title, or one with no room, has none.
///
/// Not thread-safe: `FrameRenderer` uses it with its lock held.
final class TitleTexture {
    /// How many textures have been drawn, for tests.
    private(set) var drawCount = 0

    private let device: any MTLDevice
    /// The title last asked for, and its texture (`nil` when it has none).
    private var drawn: (key: Key, texture: (any MTLTexture)?)?

    /// What a title's texture depends on: everything of its layer but the corners.
    private struct Key: Equatable {
        let title: String
        let appearance: FrameAppearance
        let rect: Rect
        let barHeight: Double
        let buttons: Bool

        init(_ layer: WindowFrameLayer) {
            (title, appearance, rect, barHeight, buttons) = (layer.title, layer.appearance, layer.rect, layer.barHeight, layer.buttons)
        }
    }

    init(device: any MTLDevice) {
        self.device = device
    }

    /// The texture of `layer`'s title, `layer.barPixels.size` big; `nil` for an empty title or one with no room.
    /// - Throws: `RenderError.metalResourceUnavailable` if CoreGraphics or Metal cannot make what it needs.
    func texture(for layer: WindowFrameLayer) throws -> (any MTLTexture)? {
        let key = Key(layer)
        if let drawn, drawn.key == key { return drawn.texture }
        // The previous title's memory goes before the next one is drawn.
        drawn = nil
        let texture = try draw(layer)
        drawn = (key, texture)
        return texture
    }

    /// `layer`'s title drawn into a new texture; `nil` when it has nothing to draw.
    private func draw(_ layer: WindowFrameLayer) throws -> (any MTLTexture)? {
        let box = layer.barPixels
        let room = layer.rect.width - 2 * layer.titleInset
        guard !layer.title.isEmpty, box.size.x > 0, box.size.y > 0, room > 0, layer.barHeight > 0,
              let font = CTFontCreateUIFontForLanguage(.windowTitle, layer.barHeight * 13 / 28, nil)
        else { return nil }
        let white: CGFloat = layer.appearance == .light ? 0 : 1
        let color = CGColor(srgbRed: white, green: white, blue: white, alpha: 0.85)
        let attributes: [NSAttributedString.Key: Any] = [
            NSAttributedString.Key(kCTFontAttributeName as String): font,
            NSAttributedString.Key(kCTForegroundColorAttributeName as String): color,
        ]
        func line(_ text: String) -> CTLine {
            CTLineCreateWithAttributedString(NSAttributedString(string: text, attributes: attributes))
        }
        var title = line(layer.title)
        if CTLineGetTypographicBounds(title, nil, nil, nil) > room {
            guard let truncated = CTLineCreateTruncatedLine(title, room, .end, line("…")) else { return nil }
            title = truncated
        }
        let width = CTLineGetTypographicBounds(title, nil, nil, nil)
        guard width > 0 else { return nil }
        // Where the line starts and its baseline, in output pixels (y down), then in the context's (y up from the box's
        // bottom).
        let start = layer.rect.x + (layer.rect.width - width) / 2
        let baseline = layer.rect.y + (layer.barHeight + CTFontGetCapHeight(font)) / 2
        let origin = CGPoint(x: start - Double(box.origin.x), y: Double(box.origin.y + box.size.y) - baseline)

        let (columns, rows) = (box.size.x, box.size.y)
        var bytes = [UInt8](repeating: 0, count: columns * rows * 4)
        try bytes.withUnsafeMutableBytes { buffer in
            guard let space = CGColorSpace(name: CGColorSpace.sRGB),
                  let context = CGContext(
                    data: buffer.baseAddress, width: columns, height: rows, bitsPerComponent: 8, bytesPerRow: columns * 4,
                    space: space, bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)
            else { throw RenderError.metalResourceUnavailable("title bitmap") }
            context.setShouldSmoothFonts(false)
            context.setAllowsFontSubpixelPositioning(false)
            context.setShouldAntialias(true)
            context.textMatrix = .identity
            context.textPosition = origin
            CTLineDraw(title, context)
        }
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .bgra8Unorm, width: columns, height: rows, mipmapped: false)
        descriptor.usage = .shaderRead
        descriptor.storageMode = .shared
        guard let texture = device.makeTexture(descriptor: descriptor) else {
            throw RenderError.metalResourceUnavailable("title texture")
        }
        texture.replace(region: MTLRegionMake2D(0, 0, columns, rows), mipmapLevel: 0, withBytes: bytes, bytesPerRow: columns * 4)
        drawCount += 1
        return texture
    }
}
