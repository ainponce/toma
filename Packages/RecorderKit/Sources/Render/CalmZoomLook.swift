// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import ProjectFormat

/// The look of the calm zoom (phase 3 design §6 and §19, plan 3b decision 7), frozen with its ids: `calmZoom-1` the focus,
/// Highlight and Dim, `loupe-1` the loupe's lens. Lengths are in points of the output: one is the output's short side /
/// 1080 pixels. Everything is mixed with what is under it by the layer's `amount`.
///
/// - Highlight: outside the focus 20 % darker; the focus's corners of 12 pt (at most half its shorter side); a ring of 3
///   pt, white at 90 %, outside its edge; and past the ring a white glow of 25 % that falls with σ 6 pt.
/// - Dim: outside the focus 60 % darker and blurred with σ 8 pt, through a soft edge (`smoothstep`) 24 pt wide from the
///   focus's edge outward; the same corners. The blur is the shaders' separable Gaussian (`blurFragment`) on the first
///   mipmap level of a copy of the frame where σ is at most 4 texels (`dimBlurLevel`).
/// - The loupe: a circle of the lens's radius `r`, or a rounded rectangle of half size (1.5 `r`, `r`) with corners of
///   0.25 `r`, centred on the focus; inside it, the frame at `c + (p − c) / m`, and in its outer 15 % (`r` × 0.15 in from
///   its edge) a bulge of up to 8 % (`× (1 + 0.08 s²)`, `s` from 0 to 1 across the band, continuous at its inner edge,
///   `lensSample`); a ring of 2 pt, white at 60 %, inside its edge; a black shadow of 30 %, σ 12 pt, 4 pt down.
enum CalmZoomLook {
    /// The focus, its entry and exit, Highlight and Dim.
    static let id = "calmZoom-1"
    /// The loupe's lens.
    static let loupeID = "loupe-1"

    /// The focus's corners, in points.
    static let cornerRadius = 12.0

    /// Highlight: how much darker outside the focus, the ring (across, in points, and its white) and the glow past it.
    static let highlightDarken = 0.2
    static let highlightRing = 3.0
    static let highlightRingOpacity = 0.9
    static let highlightGlowOpacity = 0.25
    static let highlightGlowSigma = 6.0

    /// Dim: how much darker outside the focus, its blur's σ and its soft edge, in points.
    static let dimDarken = 0.6
    static let dimSigma = 8.0
    static let dimTransition = 24.0
    /// The largest σ, in texels, Dim blurs at: past it, a mipmap level of the frame that brings it within.
    static let dimMaxTexelSigma = 4.0

    /// The loupe: its outer band (a fraction of `r`) and how much farther out it reads at its edge, the rounded
    /// rectangle's half width and corners (fractions of `r`), the ring (in points, and its white) and the shadow (its
    /// black, its σ and how far down it is, in points).
    static let lensBand = 0.15
    static let lensBulge = 0.08
    static let lensRectWidth = 1.5
    static let lensRectCorner = 0.25
    static let lensRing = 2.0
    static let lensRingOpacity = 0.6
    static let lensShadowOpacity = 0.3
    static let lensShadowSigma = 12.0
    static let lensShadowOffset = 4.0

    /// A point of an output of `outputSize`, in its pixels: its short side / 1080.
    static func point(outputSize: SIMD2<Int>) -> Double {
        Double(min(outputSize.x, outputSize.y)) / 1080
    }

    /// The mipmap level of a frame `size` big that Dim blurs at for `sigma` texels of it: the first at which σ / 2^level
    /// is at most `dimMaxTexelSigma`, never past the frame's last level; 0 for a σ that is not a number.
    static func dimBlurLevel(sigma: Double, size: SIMD2<Int>) -> Int {
        let lastLevel = Int(log2(Double(max(size.x, size.y, 1))).rounded(.down))
        var level = 0
        while level < lastLevel, sigma / Double(1 << level) > dimMaxTexelSigma { level += 1 }
        return level
    }

    /// The half size of a lens of `radius`: (`r`, `r`) for a circle, (1.5 `r`, `r`) for a rounded rectangle.
    static func lensHalfSize(radius: Double, shape: LoupeShape) -> SIMD2<Double> {
        switch shape {
        case .circle: SIMD2(radius, radius)
        case .roundedRect: SIMD2(lensRectWidth * radius, radius)
        }
    }

    /// The corners of a lens of `radius`: `r` for a circle (all of it), 0.25 `r` for a rounded rectangle.
    static func lensCorner(radius: Double, shape: LoupeShape) -> Double {
        switch shape {
        case .circle: radius
        case .roundedRect: lensRectCorner * radius
        }
    }

    /// The signed distance from `p` to a rectangle of `halfSize` with corners of `radius`, centred at the origin:
    /// negative inside. The shaders' `roundedRectDistance`.
    static func roundedRectDistance(_ p: SIMD2<Double>, halfSize: SIMD2<Double>, radius: Double) -> Double {
        let q = SIMD2(abs(p.x), abs(p.y)) - halfSize + radius
        let outside = SIMD2(max(q.x, 0), max(q.y, 0))
        return (outside * outside).sum().squareRoot() + min(max(q.x, q.y), 0) - radius
    }

    /// Where the lens of `radius` and `shape` centred at `center` reads what is under it for its pixel at `p` (output
    /// pixels), magnifying by `magnification`: `c + (p − c) / m`, up to 8 % farther out across its outer band, as
    /// `loupeFragment` does; `p` itself outside the lens.
    static func lensSample(
        _ p: SIMD2<Double>, center: SIMD2<Double>, radius: Double, shape: LoupeShape, magnification: Double
    ) -> SIMD2<Double> {
        let d = roundedRectDistance(
            p - center, halfSize: lensHalfSize(radius: radius, shape: shape), radius: lensCorner(radius: radius, shape: shape))
        guard d <= 0 else { return p }
        let band = lensBand * radius
        let s = min(max((d + band) / band, 0), 1)
        return center + (p - center) / magnification * (1 + lensBulge * s * s)
    }

    /// The uniforms of Highlight's or Dim's `mode` (`calmHighlightFragment`, `calmDimFragment`) at `amount` (0 to 1) for
    /// `focus` as it is drawn (output pixels) in an output of `outputSize`.
    static func focusUniforms(_ mode: ZoomMode, amount: Double, focus: Rect, outputSize: SIMD2<Int>) -> CalmFocusUniforms {
        let pt = point(outputSize: outputSize)
        let corner = min(cornerRadius * pt, min(focus.width, focus.height) / 2)
        let highlight = mode == .highlight
        return CalmFocusUniforms(
            focusOrigin: SIMD2(Float(focus.x), Float(focus.y)), focusSize: SIMD2(Float(focus.width), Float(focus.height)),
            cornerRadius: Float(max(corner, 0)), amount: Float(amount),
            darken: Float(highlight ? highlightDarken : dimDarken), ring: highlight ? Float(highlightRing * pt) : 0,
            ringOpacity: highlight ? Float(highlightRingOpacity) : 0, glowOpacity: highlight ? Float(highlightGlowOpacity) : 0,
            glowSigma: Float(highlightGlowSigma * pt), transition: Float(dimTransition * pt))
    }

    /// The uniforms of the lens `lens` centred at `center` (output pixels) at `amount` in an output of `outputSize`,
    /// reading the copy of what is under it at `sampleOrigin` and `sampleSize` (output pixels).
    static func loupeUniforms(
        _ lens: LoupeLayer, center: SIMD2<Double>, amount: Double, sampleOrigin: SIMD2<Double>, sampleSize: SIMD2<Double>,
        outputSize: SIMD2<Int>
    ) -> LoupeUniforms {
        let pt = point(outputSize: outputSize)
        return LoupeUniforms(
            center: SIMD2<Float>(center), halfSize: SIMD2<Float>(lensHalfSize(radius: lens.radius, shape: lens.shape)),
            sampleOrigin: SIMD2<Float>(sampleOrigin), sampleSize: SIMD2<Float>(sampleSize),
            corner: Float(lensCorner(radius: lens.radius, shape: lens.shape)), magnification: Float(max(lens.magnification, 1)),
            band: Float(lensBand * lens.radius), bulge: Float(lensBulge), ring: Float(lensRing * pt),
            ringOpacity: Float(lensRingOpacity), amount: Float(amount))
    }

    /// The lens's shadow (the core's `ShadowUniforms`, `shadowValue`): its shape moved `lensShadowOffset` down.
    static func lensShadow(_ lens: LoupeLayer, center: SIMD2<Double>, outputSize: SIMD2<Int>) -> LensShadowUniforms {
        let pt = point(outputSize: outputSize)
        let half = lensHalfSize(radius: lens.radius, shape: lens.shape)
        let moved = center + SIMD2(0, lensShadowOffset * pt)
        return LensShadowUniforms(
            lower: SIMD2<Float>(moved - half), upper: SIMD2<Float>(moved + half), sigma: Float(lensShadowSigma * pt),
            corner: Float(lensCorner(radius: lens.radius, shape: lens.shape)), opacity: Float(lensShadowOpacity))
    }

    /// How far past its shape a lens of `radius` draws, in output pixels: its shadow's offset and three σ, and a pixel.
    static func lensReach(outputSize: SIMD2<Int>) -> Double {
        (lensShadowOffset + 3 * lensShadowSigma) * point(outputSize: outputSize) + 1
    }

    /// Checks that the uniforms keep the layout of the shaders' structs: in `CalmZoomPipelines.init`, as
    /// `Compositor.init` checks its own.
    static func checkLayouts() {
        precondition(
            MemoryLayout<CalmFocusUniforms>.stride == 48, "CalmFocusUniforms must keep the layout of the shaders' struct: 48 bytes")
        precondition(MemoryLayout<LoupeUniforms>.stride == 64, "LoupeUniforms must keep the layout of the shaders' struct: 64 bytes")
        precondition(
            MemoryLayout<LensShadowUniforms>.stride == 32, "LensShadowUniforms must keep the layout of the shaders' struct: 32 bytes")
        precondition(
            MemoryLayout<CalmBlurUniforms>.stride == 16, "CalmBlurUniforms must keep the layout of the shaders' struct: 16 bytes")
    }
}

/// `CalmFocusUniforms` in `ShaderSource.calmZoomMetal`: 48 bytes. The focus as it is drawn and Highlight's or Dim's look,
/// in output pixels.
struct CalmFocusUniforms: Equatable {
    var focusOrigin: SIMD2<Float>
    var focusSize: SIMD2<Float>
    var cornerRadius: Float
    var amount: Float
    var darken: Float
    var ring: Float
    var ringOpacity: Float
    var glowOpacity: Float
    var glowSigma: Float
    var transition: Float
}

/// `LoupeUniforms` in `ShaderSource.calmZoomMetal`: 64 bytes. The lens and the copy of what is under it, in output pixels.
struct LoupeUniforms: Equatable {
    var center: SIMD2<Float>
    var halfSize: SIMD2<Float>
    var sampleOrigin: SIMD2<Float>
    var sampleSize: SIMD2<Float>
    var corner: Float
    var magnification: Float
    var band: Float
    var bulge: Float
    var ring: Float
    var ringOpacity: Float
    var amount: Float
    var padding: Float = 0
}

/// The core's `ShadowUniforms` in `ShaderSource.metal` (the compositor's own is private to it): 32 bytes.
struct LensShadowUniforms: Equatable {
    var lower: SIMD2<Float>
    var upper: SIMD2<Float>
    var sigma: Float
    var corner: Float
    var opacity: Float
    var padding: Float = 0
}

/// The core's `BlurUniforms` in `ShaderSource.metal` (`BackgroundImages`' own is private to it): 16 bytes.
struct CalmBlurUniforms {
    var direction: SIMD2<Float>
    var sigma: Float
    var radius: Int32
}
