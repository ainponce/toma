// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import RecorderKitTestSupport
import Testing

@testable import ProjectFormat

@Test func fixedAspectsKeepTheirSizes() {
    #expect(StageLayout.outputSize(aspect: .landscape, shortSide: 720) == [1280, 720])
    #expect(StageLayout.outputSize(aspect: .landscape, shortSide: 1080) == [1920, 1080])
    #expect(StageLayout.outputSize(aspect: .landscape, shortSide: 2160) == [3840, 2160])
    #expect(StageLayout.outputSize(aspect: .portrait, shortSide: 1080) == [1080, 1920])
    #expect(StageLayout.outputSize(aspect: .square, shortSide: 1080) == [1080, 1080])
    for side in 2...2160 {
        let long = Int((Double(side) * 16 / 9 / 2).rounded()) * 2
        #expect(StageLayout.outputSize(aspect: .landscape, shortSide: side) == [long, side])
        #expect(StageLayout.outputSize(aspect: .portrait, shortSide: side) == [side, long])
        #expect(StageLayout.outputSize(aspect: .square, shortSide: side) == [side, side])
    }
}

@Test func newAspectsFollowTheShortSide() {
    #expect(StageLayout.outputSize(aspect: .fourByFive, shortSide: 1080) == [1080, 1350])
    #expect(StageLayout.outputSize(aspect: .fourByThree, shortSide: 1080) == [1440, 1080])
    #expect(StageLayout.outputSize(aspect: .threeByFour, shortSide: 1080) == [1080, 1440])
    #expect(StageLayout.outputSize(aspect: .fourByFive, shortSide: 720) == [720, 900])
    #expect(StageLayout.outputSize(aspect: .fourByThree, shortSide: 720) == [960, 720])
}

@Test func autoFollowsTheContent() {
    for ratio in [nil, 1.77, .nan, 0, -1, .infinity] as [Double?] {
        #expect(StageLayout.outputSize(aspect: .auto, shortSide: 1080, contentRatio: ratio) == [1920, 1080], "\(String(describing: ratio))")
    }
    #expect(StageLayout.outputSize(aspect: .auto, shortSide: 1080, contentRatio: 1.6) == [1728, 1080])
    #expect(StageLayout.outputSize(aspect: .auto, shortSide: 1080, contentRatio: 2.4) == [2592, 1080])
    #expect(StageLayout.outputSize(aspect: .auto, shortSide: 1080, contentRatio: 0.5) == [1080, 2160])
    #expect(Aspect.auto.ratio == 16.0 / 9)
    #expect(Aspect.fourByFive.ratio(contentRatio: 3) == 0.8)
}

@Test func aspectValuesAndOrder() throws {
    #expect(Aspect.allCases.map(\.rawValue) == ["16:9", "9:16", "1:1", "4:5", "4:3", "3:4", "auto"])
    for aspect in Aspect.allCases {
        let data = try JSONEncoder().encode([aspect])
        #expect(try JSONDecoder().decode([Aspect].self, from: data) == [aspect])
    }
    #expect(throws: (any Error).self) { try JSONDecoder().decode([Aspect].self, from: Data(#"["5:4"]"#.utf8)) }
}

@Test func aVersion3DocumentWithANewAspectDoesNotRevertToVersion2() throws {
    let v2 = try ProjectJSON.decoder().decode(JSONValue.self, from: Data(DesignExample.canonical.utf8))
    let document = try DocumentMigration.migrate(v2, from: 2)
    #expect(DocumentMigration.reverted(document, to: 2) != nil)
    for aspect in [Aspect.fourByFive, .fourByThree, .threeByFour, .auto] {
        var changed = document
        guard case .object(var members) = changed else { Issue.record("not an object"); return }
        members["aspect"] = .string(aspect.rawValue)
        changed = .object(members)
        #expect(DocumentMigration.reverted(changed, to: 2) == nil, "\(aspect)")
        #expect(DocumentMigration.reverted(changed, to: 1) == nil, "\(aspect)")
        #expect(DocumentMigration.reverted(changed, to: 3) == changed)
    }
}

@Test func autoIsHeldBetweenAQuarterAndFour() {
    // A crafted window of 10¹⁷ × 1 (or 1 × 10¹⁷) points, and the extremes a Double holds.
    for (content, held) in [(1e17, 4.0), (1e-17, 0.25), (.greatestFiniteMagnitude, 4), (.leastNonzeroMagnitude, 0.25), (4, 4), (0.25, 0.25)] {
        #expect(Aspect.auto.ratio(contentRatio: content) == held, "\(content)")
    }
    for short in [292, 720, 1080, 1440, 2160] {
        #expect(StageLayout.outputSize(aspect: .auto, shortSide: short, contentRatio: 1e17) == [short * 4, short])
        #expect(StageLayout.outputSize(aspect: .auto, shortSide: short, contentRatio: 1e-17) == [short, short * 4])
    }
    // An Area strip of 2560 × 64 points (40:1) is 4:1: 8640 × 2160 in 4K, which the encoders take.
    #expect(StageLayout.outputSize(aspect: .auto, shortSide: 2160, contentRatio: 2560.0 / 64) == [8640, 2160])
    #expect(StageLayout.outputSize(aspect: .auto, shortSide: 2160, contentRatio: 64.0 / 2560) == [2160, 8640])
    // Inside the range, as before.
    #expect(StageLayout.outputSize(aspect: .auto, shortSide: 1080, contentRatio: 3.9) == [4212, 1080])
    #expect(StageLayout.outputSize(aspect: .auto, shortSide: 1080, contentRatio: 1 / 3.9) == [1080, 4212])
}

@Test func noOutputSideIsOver16384() {
    #expect(StageLayout.maximumSide == 16_384)
    // Both sides scaled down, even, the longer one to 16384.
    #expect(StageLayout.outputSize(aspect: .auto, shortSide: 8192, contentRatio: 40) == [16_384, 4096])
    #expect(StageLayout.outputSize(aspect: .auto, shortSide: 5000, contentRatio: 4) == [16_384, 4096])
    #expect(StageLayout.outputSize(aspect: .landscape, shortSide: 10_000) == [16_384, 9216])
    #expect(StageLayout.outputSize(aspect: .portrait, shortSide: 10_000) == [9216, 16_384])
    #expect(StageLayout.outputSize(aspect: .square, shortSide: 20_000) == [16_384, 16_384])
    #expect(StageLayout.outputSize(aspect: .fourByThree, shortSide: 13_000) == [16_384, 12_288])
    // Up to it, as before: 16:9 of 9216 is 16384 × 9216.
    #expect(StageLayout.outputSize(aspect: .landscape, shortSide: 9216) == [16_384, 9216])
    for short in [2, 3, 1000, 2160, 4096, 9000, 9216, 9217, 12_000, 40_000] {
        for aspect in Aspect.allCases {
            for content in [nil, 1e17, 1e-17, 2.5] as [Double?] {
                let size = StageLayout.outputSize(aspect: aspect, shortSide: short, contentRatio: content)
                #expect(size.x <= 16_384 && size.y <= 16_384 && size.x > 0 && size.y > 0, "\(aspect) \(short)")
                if max(size.x, size.y) == 16_384 || short % 2 == 0 { #expect(size.x % 2 == 0 && size.y % 2 == 0, "\(aspect) \(short)") }
            }
        }
    }
}
