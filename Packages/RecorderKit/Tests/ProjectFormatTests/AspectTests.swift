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
