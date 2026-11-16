// SPDX-License-Identifier: GPL-3.0-or-later
import ProjectFormat

/// The generic macOS window drawn around the screen (design §7.3), no Apple artwork: a title bar `barHeight` tall at the
/// top of `rect`, the screen filling the rest of it (`ScreenLayer.rect`), and corners of `cornerRadius` on the whole
/// window, so the screen's top corners are square. The bar is light (#ECECEC) or dark (#2B2B2E); with `buttons`, it has
/// three generic circles (#FF5F57, #FEBC2E, #28C840) 0.42 of the bar across, their centres 0.66 of it apart and the
/// first's 0.6 of it from the window's left edge, at the bar's middle; and its title, centred (`TitleTexture`), none when
/// empty. A shadow goes under the whole window.
public struct WindowFrameLayer: Equatable, Sendable {
    /// The whole window, bar and screen, in output pixels, origin at the top left.
    public var rect: Rect
    /// In output pixels.
    public var barHeight: Double
    public var appearance: FrameAppearance
    public var title: String
    public var buttons: Bool
    /// In output pixels.
    public var cornerRadius: Double

    public init(rect: Rect, barHeight: Double, appearance: FrameAppearance, title: String, buttons: Bool, cornerRadius: Double) {
        self.rect = rect
        self.barHeight = barHeight
        self.appearance = appearance
        self.title = title
        self.buttons = buttons
        self.cornerRadius = cornerRadius
    }
}

extension WindowFrameLayer {
    /// The three buttons' colours, left to right: red, yellow and green.
    static let buttonColors: [SIMD4<Float>] = [rgb(0xFF5F57), rgb(0xFEBC2E), rgb(0x28C840)]
    /// The buttons' diameter, the distance between their centres and the first centre's from the left edge, as
    /// fractions of the bar's height.
    static let buttonDiameter = 0.42
    static let buttonSpacing = 0.66
    static let firstButtonCentre = 0.6

    /// The bar's colour, as the compositor writes it.
    var barColor: SIMD4<Float> {
        switch appearance {
        case .light: Self.rgb(0xECECEC)
        case .dark: Self.rgb(0x2B2B2E)
        }
    }

    /// The centre of the first button, in output pixels.
    var firstButton: SIMD2<Double> {
        SIMD2(rect.x + Self.firstButtonCentre * barHeight, rect.y + barHeight / 2)
    }

    /// How far the title keeps from each side of the window, in output pixels: past the third button by the first's
    /// margin with the buttons (2.73 of the bar), that margin without them (0.6 of it).
    var titleInset: Double {
        let buttonsEnd = Self.firstButtonCentre + 2 * Self.buttonSpacing + Self.buttonDiameter / 2
        return (buttons ? buttonsEnd + Self.firstButtonCentre : Self.firstButtonCentre) * barHeight
    }

    /// The whole output pixels the bar touches, where its title's texture is drawn: from the pixel of its top-left
    /// corner to that of its bottom-right one.
    var barPixels: (origin: SIMD2<Int>, size: SIMD2<Int>) {
        let left = rect.x.rounded(.down), top = rect.y.rounded(.down)
        let right = (rect.x + rect.width).rounded(.up), bottom = (rect.y + barHeight).rounded(.up)
        guard [left, top, right, bottom].allSatisfy(\.isFinite), right > left, bottom > top else { return (.zero, .zero) }
        return (SIMD2(Int(left), Int(top)), SIMD2(Int(right - left), Int(bottom - top)))
    }

    /// An opaque colour of `hex` (`0xRRGGBB`), sRGB-encoded as the output stores it.
    private static func rgb(_ hex: UInt32) -> SIMD4<Float> {
        SIMD4(Float((hex >> 16) & 0xFF) / 255, Float((hex >> 8) & 0xFF) / 255, Float(hex & 0xFF) / 255, 1)
    }
}
