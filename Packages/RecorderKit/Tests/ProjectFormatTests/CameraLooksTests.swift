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

    /// The look of `preset` on `rgb`: tint and saturation in linear light, contrast and blacks encoded, each clamped.
    static func look(_ preset: CameraColorPreset, _ rgb: [Double]) -> [Double] {
        let (tint, saturation, contrast, blacks): ([Double], Double, Double, Double) = switch preset {
        case .warm: ([0.06, 0, -0.05], 1.05, 1, 0)
        case .cool: ([-0.04, 0, 0.06], 1, 1, 0)
        case .vivid: ([0, 0, 0], 1.3, 1.1, 0)
        case .soft: ([0, 0, 0], 0.9, 0.9, 0.04)
        case .mono: ([0, 0, 0], 0, 1.05, 0)
        case .natural, .custom: ([0, 0, 0], 1, 1, 0)
        }
        var c = rgb.map { linear(clamp($0)) }
        c = zip(c, tint).map { clamp($0 + $1) }
        let l = luma(c)
        c = c.map { clamp(l + saturation * ($0 - l)) }
        c = c.map(encoded)
        c = c.map { clamp(0.5 + contrast * ($0 - 0.5)) }
        return c.map { clamp(blacks + $0 * (1 - blacks)) }
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
    // Soft brings the channels together and lifts black: contrast 0.9 takes it to 0.05, then blacks to 0.04 + 0.05 × 0.96.
    let soft = CameraLooks.apply(.soft, to: skin)
    #expect(soft.max() - soft.min() < skin.max() - skin.min())
    let black = apply(.soft, 0, 0, 0)
    #expect(abs(black.x - 0.088) < 1e-6 && black.x == black.y && black.y == black.z)
    #expect(apply(.soft, 1, 1, 1).x < 1)

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
        .warm: "a87f4e9bdd3b813ead5dea5b1eded79e57cd01f66c06466ce74625522353c272",
        .cool: "28fd3ce793e62d4752f7c61496bc700652c638ad00ae3ff00813dfc28e3326d9",
        .vivid: "7689add145a6b3c311b4db19c91e78eabfecb95a7a4b1b8b55573fae1666e601",
        .soft: "fa6b12a84f85db63e780c31908a5bcc9cd2816e08a6c3d0d2f66c14d6e5c36cb",
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
