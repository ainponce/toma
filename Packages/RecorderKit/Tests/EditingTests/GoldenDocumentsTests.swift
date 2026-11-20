// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import RecorderKitTestSupport
import Testing
// Not @testable: the app uses only the public API.
import Analysis
import Editing
import ProjectFormat

/// The documents of 1c that golden 2 records (`GoldenDocuments.v2Cases`), which `GoldenDocuments.makeDocument` builds by
/// hand (its target does not see `Editing`), are the ones 1c's editor writes: the case's take edited with the commands of
/// `Editing`, as the user would, gives the same document, so the golden files hold documents the app can have.
@Suite struct GoldenDocumentsTests {
    /// Ids from 1 for each prefix, in 8 hex digits: `l-00000001`, `l-00000002`…
    private final class IDs {
        private var counts: [String: Int] = [:]

        func make(_ prefix: String) -> String {
            let count = counts[prefix, default: 0] + 1
            counts[prefix] = count
            return prefix + String(format: "%08x", count)
        }
    }

    private static func output(_ seconds: Double) -> Int64 { TimeMap.outputNanoseconds(seconds: seconds) }

    private static func range(_ from: Double, _ to: Double) -> Range<Int64> { output(from)..<output(to) }

    /// `document` with `step` applied; the step must be there.
    private static func applying(_ step: EditStep?, to document: EditDocument) throws -> EditDocument {
        try document.applying(try #require(step).changes)
    }

    @Test func everyCaseOfGolden2HasItsDocument() async throws {
        #expect(GoldenDocuments.golden2Cases.map(\.name) == GoldenDocuments.cases.map(\.name) + GoldenDocuments.v2Cases.map(\.name))
        #expect(GoldenDocuments.cases.allSatisfy { $0.documentVersion == 1 })
        // Documents of 1c, in its version, whatever the current one is (3 since phase 2).
        #expect(GoldenDocuments.v2Cases.allSatisfy { $0.documentVersion == 2 })
        #expect(Set(GoldenDocuments.golden2Cases.map(\.name)).count == GoldenDocuments.golden2Cases.count)
    }

    /// Golden 3 draws and mixes golden 2's cases first, unchanged (their names, times, mix, versions and size, so their
    /// frames are golden 2's), then phase 2's, in their order, of documents of version 3, drawn at 360 px; only
    /// `keysOnScreen`'s package is of format version 4. Changing this order changes the golden files of phase 3.
    @Test func golden3CasesKeepThe2OnesFirst() {
        func fields(_ c: GoldenDocuments.Case) -> String {
            "\(c.name) \(c.times) \(c.mixes) \(c.documentVersion) \(c.formatVersion) \(c.shortSide)"
        }
        let golden2 = GoldenDocuments.golden2Cases
        #expect(golden2.count == 9)
        #expect(GoldenDocuments.golden3Cases.prefix(golden2.count).map(fields) == golden2.map(fields))
        #expect(golden2.allSatisfy { $0.formatVersion == 3 && $0.shortSide == 720 })
        #expect(GoldenDocuments.golden3Cases.dropFirst(golden2.count).map(fields) == GoldenDocuments.v3Cases.map(fields))
        #expect(GoldenDocuments.v3Cases.map(\.name) == [
            "captionsBold", "captionsClassicTop", "privacyManual", "keysOnScreen", "deviceFrameIPhone", "cameraLookWarm",
            "followCursorPortrait", "fourByFive", "likeTheRecording", "normalizedMix",
        ])
        #expect(GoldenDocuments.v3Cases.allSatisfy { $0.documentVersion == 3 && $0.shortSide == 360 })
        #expect(GoldenDocuments.v3Cases.filter { $0.formatVersion == 4 }.map(\.name) == ["keysOnScreen"])
        #expect(GoldenDocuments.v3Cases.filter(\.mixes).map(\.name) == ["captionsBold", "keysOnScreen", "cameraLookWarm", "normalizedMix"])
        #expect(Set(GoldenDocuments.golden3Cases.map(\.name)).count == GoldenDocuments.golden3Cases.count)
    }

    /// The Camera track's blocks made one after the other over the output, one Bubble given its own style and the
    /// Camera only made instant, and a zoom of the user's with its depth and a fixed point.
    @Test func layoutBlocksIsWhatTheCameraTrackWrites() async throws {
        try await withTemporaryDirectory { dir in
            let project = try await GoldenDocuments.makeProject("layoutBlocks", in: dir)
            var doc = EditDocument.legacy(for: project)
            let timeMap = TimeMap(sequence: doc.sequence)
            let ids = IDs()
            func add(_ kind: LayoutKind, _ from: Double, _ to: Double) throws {
                doc = try Self.applying(
                    LayoutCommands.add(doc, kind: kind, output: Self.range(from, to), timeMap: timeMap, makeID: ids.make), to: doc)
            }
            try add(.split, 0.4, 1.4)
            try add(.bubble, 1.4, 2.0)
            doc = try Self.applying(
                LayoutCommands.setBubbleStyle(
                    doc, id: "l-00000002", CameraStyle(shape: .roundedSquare, size: CameraStyle.large, anchor: .topLeading)),
                to: doc)
            try add(.cameraOnly, 2.0, 2.6)
            doc = try Self.applying(LayoutCommands.setInstant(doc, id: "l-00000003", true), to: doc)
            try add(.cameraFull, 2.6, 3.2)
            try add(.screenOnly, 3.2, 3.8)
            doc = try Self.applying(ZoomCommands.add(doc, output: Self.range(0.6, 1.35), makeID: ids.make), to: doc)
            doc = try Self.applying(ZoomCommands.change(doc, id: "z-00000001", depth: 1.6, focus: .fixed(x: 0.3, y: 0.35)), to: doc)

            let made = try GoldenDocuments.makeDocument("layoutBlocks", for: project)
            #expect(made.camera.layouts == doc.camera.layouts)
            #expect(made == doc)
        }
    }

    /// A new project with Toma's style, made 9:16, with a Split for its layout given a side and a share, a border, a
    /// shadow and a Bubble block, which takes the take's bubble.
    @Test func portraitSplitIsANewProjectEdited() async throws {
        try await withTemporaryDirectory { dir in
            let project = try await GoldenDocuments.makeProject("portraitSplit", in: dir)
            let ids = IDs()
            var doc = NewDocument.make(project: project, defaultStyle: .toma, makeID: ids.make)
            doc = try Self.applying(StyleCommands.setAspect(doc, .portrait), to: doc)
            doc = try Self.applying(LayoutCommands.setProjectLayout(doc, .split), to: doc)
            doc = try Self.applying(LayoutCommands.setSplit(doc, id: nil, side: .start, share: 0.4), to: doc)
            doc = try Self.applying(CameraLookCommands.setBorderWidth(doc, 0.6), to: doc)
            doc = try Self.applying(CameraLookCommands.setBorderColor(doc, CameraLookCommands.borderSwatches[3]), to: doc)
            doc = try Self.applying(CameraLookCommands.setShadow(doc, 0.7), to: doc)
            doc = try Self.applying(
                LayoutCommands.add(
                    doc, kind: .bubble, output: Self.range(2.0, 3.0), timeMap: TimeMap(sequence: doc.sequence), makeID: ids.make),
                to: doc)

            let made = try GoldenDocuments.makeDocument("portraitSplit", for: project)
            #expect(made.camera == doc.camera)
            #expect(made == doc)
        }
    }

    /// A project of 1b, made 1:1, with a style the user saved applied.
    @Test func namedStyleIsTheStyleApplied() async throws {
        try await withTemporaryDirectory { dir in
            let project = try await GoldenDocuments.makeProject("namedStyle", in: dir)
            var doc = EditDocument.legacy(for: project)
            doc = try Self.applying(StyleCommands.setAspect(doc, .square), to: doc)
            let style = NamedStyle(
                id: "5ca1ab1e", name: "Talks", look: GoldenDocuments.namedStyleLook, camera: GoldenDocuments.namedStyleCamera)
            doc = try Self.applying(StyleCommands.applyStyle(doc, style, take: project.take, events: project.events), to: doc)

            let made = try GoldenDocuments.makeDocument("namedStyle", for: project)
            #expect(made == doc)
            #expect(StyleCommands.matchingStyle(made, among: [style]) == .named(style.id))
        }
    }
}
