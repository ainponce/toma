// SPDX-License-Identifier: GPL-3.0-or-later
import Testing
import ProjectFormat

@testable import Analysis

@Suite struct StepNumberingTests {
    typealias F = AnnotationFixtures

    static func step(_ id: String, _ anchor: AnnotationAnchor, layer: Int = 0) -> Annotation {
        F.text(id, anchor: anchor, layer: layer, kind: .step(StepAnnotation()))
    }

    static func numbers(_ items: [Annotation]) -> [String: Int] {
        let d = F.document(items)
        return StepNumbering.numbers(in: d, timeMap: TimeMap(sequence: d.sequence))
    }

    @Test func numbersFollowTheOutputOrder() {
        let n = Self.numbers([
            Self.step("a-00000003", F.content(15, 17)), Self.step("a-00000001", .output(start: F.ns(2), end: F.ns(4))),
            Self.step("a-00000002", F.content(5, 7)),
        ])
        #expect(n == ["a-00000001": 1, "a-00000002": 2, "a-00000003": 3])
    }

    @Test func aCutAwayStepHasNoNumber() {
        let n = Self.numbers([
            Self.step("a-00000001", F.content(1, 2)), Self.step("a-00000002", F.content(8.2, 9.8)), Self.step("a-00000003", F.content(12, 13)),
        ])
        #expect(n == ["a-00000001": 1, "a-00000003": 2])
    }

    @Test func tiesByLayerThenOrder() {
        let n = Self.numbers([
            Self.step("a-00000001", .output(start: F.ns(3), end: F.ns(5)), layer: 2),
            Self.step("a-00000002", .output(start: F.ns(3), end: F.ns(5)), layer: 1),
            Self.step("a-00000003", .output(start: F.ns(3), end: F.ns(5)), layer: 1),
        ])
        #expect(n == ["a-00000002": 1, "a-00000003": 2, "a-00000001": 3])
    }

    @Test func onlyStepsCountAndOnesPastTheEndDoNot() {
        let n = Self.numbers([
            F.text("a-00000001", anchor: .whole), Self.step("a-00000002", .whole),
            Self.step("a-00000003", .output(start: F.ns(30), end: F.ns(31))),
        ])
        #expect(n == ["a-00000002": 1])
    }
}
