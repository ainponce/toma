// SPDX-License-Identifier: GPL-3.0-or-later
import Analysis
import Export
import Foundation
import ProjectFormat
import RecorderKitTestSupport
import Testing

/// "Like the Recording" has one rule for the size of the preview, the MP4 and the GIF (phase 3 design §9): the ratio of
/// the take of the sequence's first clip (a clip with content first: its point's take), whichever take the project is
/// focused on. The editor works it out from the takes' screens read once (`TakeScreens.contentRatio(of:takes:ownTake:
/// screens:)`, which sizes its preview and the MP4 of its export sheet), the GIF from the events
/// (`StageLayout.contentRatio(project:document:)`): the same ratio, so the same shape.
@Test func previewMP4AndGIFFollowTheFirstClipsTake() async throws {
    try await withTemporaryDirectory { dir in
        // take-001 of a 16:9 display, take-002 of a 4:3 one.
        let loaded = try await MultiTakeFixtures.twoTakes(
            in: dir, name: "Proportions", secondScreen: Rect(x: 0, y: 0, width: 480, height: 360))
        let gif = GIFSettings(longSide: 1280, range: ExportRange(start: 0, end: 1_000_000_000))
        for own in ["take-001", "take-002"] {
            let project = try #require(loaded.focused(on: own))
            let screens = Dictionary(uniqueKeysWithValues: project.takes.map {
                ($0.id, TakeScreens(take: $0, events: project.events(ofTake: $0.id)))
            })
            /// The sizes of `document`: the preview's (1080 px on its short side), the MP4's at 720 and the GIF's.
            func sizes(_ document: EditDocument) -> (ratio: Double?, preview: SIMD2<Int>, mp4: SIMD2<Int>, gif: SIMD2<Int>) {
                let editor = TakeScreens.contentRatio(of: document, takes: project.takes, ownTake: own, screens: screens)
                #expect(editor == StageLayout.contentRatio(project: project, document: document), "\(own)")
                let mp4 = ExportSettings(
                    aspect: document.aspect, resolution: .p720, framesPerSecond: 30, quality: .standard, contentRatio: editor)
                return (
                    editor, StageLayout.outputSize(aspect: document.aspect, shortSide: 1080, contentRatio: editor), mp4.outputSize,
                    gif.outputSize(project: project, document: document))
            }

            var document = MultiTakeFixtures.sequence(of: project, [("take-001", 0, 2), ("take-002", 0, 2)])
            document.aspect = .auto
            let wide = sizes(document)
            #expect(wide.ratio == 640.0 / 360, "\(own)")
            #expect(wide.preview == [1920, 1080] && wide.mp4 == [1280, 720] && wide.gif == [1280, 720], "\(own)")

            // The 4:3 take first: 4:3 everywhere.
            document = MultiTakeFixtures.sequence(of: project, [("take-002", 0, 2), ("take-001", 0, 2)])
            document.aspect = .auto
            let narrow = sizes(document)
            #expect(narrow.ratio == 480.0 / 360, "\(own)")
            #expect(narrow.preview == [1440, 1080] && narrow.mp4 == [960, 720] && narrow.gif == [1280, 960], "\(own)")

            // A frozen frame of the 4:3 take before the 16:9 one: its point's take.
            document = MultiTakeFixtures.sequence(of: project, [("take-001", 0, 2)])
            document.aspect = .auto
            let point = try #require(MultiTakeFixtures.sequence(of: project, [("take-002", 0.5, 2)]).sequence.first?.start)
            document.sequence.insert(
                Clip(id: "c-000000ff", take: "take-002", start: point, end: point, speed: 1, content: .freeze(duration: 1_000_000_000)),
                at: 0)
            document.screens.initial["take-002"] = "display-1"
            #expect(sizes(document).gif == [1280, 960], "\(own)")
            #expect(sizes(document).mp4 == [960, 720], "\(own)")
        }
    }
}
