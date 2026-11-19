// SPDX-License-Identifier: GPL-3.0-or-later
import CryptoKit
import Foundation
import Testing

@testable import ProjectFormat

// MARK: - The design's numbers, written again here

/// `cameraLook-1` as phase 2 design §6.3 and plan decision 7 state it, apart from the code under test.
private enum Reference {
    static func linear(_ c: Double) -> Double { c <= 0.04045 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4) }
    static func encoded(_ l: Double) -> Double { l <= 0.0031308 ? 12.92 * l : 1.055 * pow(l, 1 / 2.4) - 0.055 }
    static func clamp(_ c: Double) -> Double { min(max(c, 0), 1) }
    static func luma(_ c: [Double]) -> Double { 0.2126 * c[0] + 0.7152 * c[1] + 0.0722 * c[2] }

    /// The look of `preset` on `rgb`: white balance (gains) and saturation in linear light, contrast and blacks
    /// encoded, each clamped. The blacks take what the contrast made of black to `blacks`, and keep 1 at 1.
    static func look(_ preset: CameraColorPreset, _ rgb: [Double]) -> [Double] {
        let (gain, saturation, contrast, blacks): ([Double], Double, Double, Double) = switch preset {
        case .warm: ([1.06, 1, 0.95], 1.05, 1, 0)
        case .cool: ([0.96, 1, 1.06], 1, 1, 0)
        case .vivid: ([1, 1, 1], 1.3, 1.1, 0)
        case .soft: ([1, 1, 1], 0.9, 0.9, 0.04)
        case .mono: ([1, 1, 1], 0, 1.05, 0)
        case .natural, .custom: ([1, 1, 1], 1, 1, 0)
        }
        var c = rgb.map { linear(clamp($0)) }
        c = zip(c, gain).map { clamp($0 * $1) }
        let l = luma(c)
        c = c.map { clamp(l + saturation * ($0 - l)) }
        c = c.map(encoded)
        c = c.map { clamp(0.5 + contrast * ($0 - 0.5)) }
        let black = max(0, 0.5 - 0.5 * contrast)
        return c.map { clamp(blacks + ($0 - black) * ((1 - blacks) / (1 - black))) }
    }
}

private let looks: [CameraColorPreset] = [.warm, .cool, .vivid, .soft, .mono]

private func apply(_ preset: CameraColorPreset, _ r: Float, _ g: Float, _ b: Float) -> SIMD3<Float> {
    CameraLooks.apply(preset, to: SIMD3(r, g, b))
}

// MARK: - Tests

@Test func naturalIsNoLUTAndLooksMoveAsTheDesignSays() throws {
    #expect(CameraLooks.id == "cameraLook-1")
    #expect(CameraLooks.size == 33)
    #expect(CameraLooks.lut(.natural) == nil)
    #expect(CameraLooks.lut(.custom) == nil)
    for rgb in [SIMD3<Float>(0, 0, 0), SIMD3(0.25, 0.5, 0.75), SIMD3(1, 1, 1)] {
        #expect(CameraLooks.apply(.natural, to: rgb) == rgb)
        #expect(CameraLooks.apply(.custom, to: rgb) == rgb)
    }

    // On a mid gray, Warm raises red and lowers blue; Cool the other way round; neither touches green much.
    let warm = apply(.warm, 0.5, 0.5, 0.5), cool = apply(.cool, 0.5, 0.5, 0.5)
    #expect(warm.x > 0.5 && warm.z < 0.5)
    #expect(cool.x < 0.5 && cool.z > 0.5)
    #expect(abs(warm.y - 0.5) < 0.02 && abs(cool.y - 0.5) < 0.02)

    // Vivid moves a color away from its gray: its channels spread.
    let skin = SIMD3<Float>(0.8, 0.6, 0.5)
    let vivid = CameraLooks.apply(.vivid, to: skin)
    #expect(vivid.max() - vivid.min() > skin.max() - skin.min())
    // Soft brings the channels together (its black and white in `softsBlackIsPointZeroFour`).
    let soft = CameraLooks.apply(.soft, to: skin)
    #expect(soft.max() - soft.min() < skin.max() - skin.min())

    // Black and white is the Rec. 709 luma in linear light, the same in the three channels.
    for rgb in [SIMD3<Float>(1, 0, 0), SIMD3(0, 1, 0), SIMD3(0, 0, 1), SIMD3(0.8, 0.6, 0.5)] {
        let mono = CameraLooks.apply(.mono, to: rgb)
        #expect(mono.x == mono.y && mono.y == mono.z)
        let luma = Reference.luma([rgb.x, rgb.y, rgb.z].map { Reference.linear(Double($0)) })
        #expect(abs(Double(mono.x) - Reference.clamp(0.5 + 1.05 * (Reference.encoded(luma) - 0.5))) < 1e-6)
    }
    #expect(apply(.mono, 0, 1, 0).x > apply(.mono, 1, 0, 0).x)
    #expect(apply(.mono, 1, 0, 0).x > apply(.mono, 0, 0, 1).x)

    // Each look is the design's math, and stays in 0…1, on a grid and outside it.
    let steps: [Float] = [0, 0.02, 0.1, 0.25, 0.5, 0.75, 0.9, 0.98, 1]
    for preset in looks {
        for r in steps {
            for g in steps {
                for b in steps {
                    let got = apply(preset, r, g, b)
                    let want = Reference.look(preset, [Double(r), Double(g), Double(b)])
                    for i in 0..<3 {
                        #expect(abs(Double(got[i]) - want[i]) < 1e-6, "\(preset) \(r) \(g) \(b)")
                        #expect((0...1).contains(got[i]))
                    }
                }
            }
        }
        for rgb in [SIMD3<Float>(-1, 2, 0.5), SIMD3(.infinity, -.infinity, 0)] {
            let got = CameraLooks.apply(preset, to: rgb)
            #expect((0..<3).allSatisfy { (0...1).contains(got[$0]) }, "\(preset)")
        }
    }
}

@Test func blackStaysBlackInWarmAndCool() throws {
    // A white balance is a gain per channel in linear light: black has nothing to multiply.
    for preset in [CameraColorPreset.warm, .cool] {
        #expect(apply(preset, 0, 0, 0) == SIMD3(0, 0, 0), "\(preset)")
        #expect(try #require(CameraLooks.lut(preset)).values[0] == SIMD3(0, 0, 0), "\(preset)")
        // Each channel scales by its gain: a dark gray moves as little as the gain says, never by an offset.
        let dark = apply(preset, 0.02, 0.02, 0.02)
        #expect((0..<3).allSatisfy { dark[$0] < 0.03 }, "\(preset) \(dark)")
    }
    // Warm on white: red is already at the top, blue comes down to 0.95 in linear light (with saturation 1.05).
    let white = apply(.warm, 1, 1, 1)
    #expect(white.x == 1 && white.z < 1)
    let cool = apply(.cool, 1, 1, 1)
    #expect(cool.x < 1 && cool.z == 1)
    // The design's gains, on a mid gray in linear light (0.2, where nothing clamps), before saturation and encoding.
    let gray = Float(Reference.encoded(0.2))
    let warm = apply(.warm, gray, gray, gray), coolGray = apply(.cool, gray, gray, gray)
    #expect(abs(Reference.linear(Double(coolGray.x)) - 0.2 * 0.96) < 1e-5)
    #expect(abs(Reference.linear(Double(coolGray.z)) - 0.2 * 1.06) < 1e-5)
    #expect(Reference.linear(Double(warm.x)) > 0.2 * 1.06 && Reference.linear(Double(warm.z)) < 0.2 * 0.95, "saturation 1.05 spreads them")
}

@Test func softsBlackIsPointZeroFour() throws {
    // Contrast 0.9 around mid-grey takes black to 0.05 and white to 0.95; then the blacks put black at exactly 0.04,
    // keeping 1 at 1.
    #expect(apply(.soft, 0, 0, 0) == SIMD3(repeating: 0.04))
    #expect(try #require(CameraLooks.lut(.soft)).values[0] == SIMD3(repeating: 0.04))
    let white = apply(.soft, 1, 1, 1)
    #expect(white.x == white.y && white.y == white.z)
    #expect(abs(Double(white.x) - (0.04 + 0.9 * 0.96 / 0.95)) < 1e-6)
    #expect(white.x <= 1)
    // Mid-grey stays where contrast leaves it, near the middle, and the order of grays is kept.
    let middle = apply(.soft, 0.5, 0.5, 0.5).x
    #expect(abs(Double(middle) - (0.04 + 0.45 * 0.96 / 0.95)) < 1e-6)
    #expect(apply(.soft, 0, 0, 0).x < apply(.soft, 0.1, 0.1, 0.1).x && middle < white.x)
}

@Test func eachLookIsItsLUT() throws {
    for preset in looks {
        let lut = try #require(CameraLooks.lut(preset))
        #expect(lut.size == 33)
        #expect(lut.domainMin == SIMD3(0, 0, 0) && lut.domainMax == SIMD3(1, 1, 1))
        #expect(lut.values.count == 33 * 33 * 33)
        // Red the fastest, as a `.cube`'s table.
        for (r, g, b) in [(0, 0, 0), (32, 0, 0), (0, 32, 0), (0, 0, 32), (5, 17, 29), (32, 32, 32)] {
            let value = lut.values[r + 33 * g + 33 * 33 * b]
            #expect(value == CameraLooks.apply(preset, to: SIMD3(Float(r), Float(g), Float(b)) / 32), "\(preset) \(r) \(g) \(b)")
        }
    }
}

@Test func cameraLook1IsFrozen() throws {
    // The SHA-256 of each LUT's table as the render uploads it: each value as a `Float16`, red, green and blue, little
    // endian, red the fastest. `cameraLook-1` never changes once merged; a new look is a new id.
    let frozen: [CameraColorPreset: String] = [
        .warm: "0e7e13f2bc0ed158d2df5cbb2f47621ad48117174d37679a16cdbdca344bc051",
        .cool: "9aff38bce286d1005240b9c7673e5e7a640ba26d64e35996f14e4c9e716c92ea",
        .vivid: "7689add145a6b3c311b4db19c91e78eabfecb95a7a4b1b8b55573fae1666e601",
        .soft: "bdcc9150444c9025406976cc0ae23ad47d70a39ca92d17abf969c9c7b51ca9b0",
        .mono: "b6ab83374def472994b57fced56ce00385b757e3848b2753a199d9456030268e",
    ]
    for preset in looks {
        let lut = try #require(CameraLooks.lut(preset))
        var bytes: [UInt8] = []
        bytes.reserveCapacity(lut.values.count * 6)
        for value in lut.values {
            for i in 0..<3 {
                let bits = Float16(value[i]).bitPattern
                bytes += [UInt8(truncatingIfNeeded: bits), UInt8(truncatingIfNeeded: bits >> 8)]
            }
        }
        let digest = SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
        #expect(digest == frozen[preset], "\(preset) \(digest)")
    }
}
