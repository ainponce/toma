// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import RecorderKitTestSupport
import Synchronization
import Testing
// Not @testable: the app uses only the public API.
import Analysis
import Editing
import ProjectFormat

/// The fixture of the tests of "Follow the Focus" in the document (fases 4 y 5 design §5.2 and plan 4a decision 11),
/// namespaced so that no other file of EditingTests meets its names: a take of 6 s of one display of 640 × 360 pt with a
/// click at 0.5 s, typing from 3.5 s to 4.5 s and, with `focus`, the field and the text cursor where it types.
private enum FocusFixture {
    static let base = HostTime(nanoseconds: 5_000_000_000_000)

    static func at(_ seconds: Double) -> HostTime { base.adding(seconds: seconds) }

    /// The focus of the take: the field at the start, and the text cursor every 0.1 s while it types, 8 pt apart.
    static let focus: [InputEvent] =
        [InputEvent(t: at(0), kind: .focus(x: 280, y: 240, width: 240, height: 24, kind: .element))]
        + (0..<10).map { k in
            InputEvent(t: at(3.55 + 0.1 * Double(k)), kind: .focus(x: 300 + 8 * Double(k), y: 244, width: 0, height: 16, kind: .caret))
        }

    /// The take in a new package `<name>.toma`, with its focus if `focus`. Written off the main actor.
    @concurrent static func take(in dir: URL, name: String, focus: Bool) async throws -> LoadedProject {
        let builder = try TakeBuilder(in: dir, name: name)
        let frame = Rect(x: 0, y: 0, width: 640, height: 360)
        try await builder.addVideoTrack(
            id: "display-1", source: TrackSource(name: "Synthetic Display", displayID: 1, globalFrame: frame, pixelScale: 1),
            segments: [VideoSegmentSpec(start: base, seconds: 6, framesPerSecond: 10)])
        try builder.addEvents([InputEvent(t: base.adding(seconds: -0.01), kind: .displayGeometry(displayID: 1, frame: frame, scale: 1))])
        try builder.addEvents([
            InputEvent(t: at(0.5), kind: .mouseDown(.left, x: 300, y: 250)),
            InputEvent(t: at(0.55), kind: .mouseUp(.left, x: 300, y: 250)),
        ])
        try builder.addEvents((0...4).map { InputEvent(t: at(3.5 + 0.25 * Double($0)), kind: .keyActivity) })
        if focus { try builder.addEvents(self.focus) }
        return try builder.write()
    }

    static func make(_ project: LoadedProject) -> EditDocument {
        let count = Mutex(0)
        return NewDocument.make(project: project, defaultStyle: .toma) { prefix in
            count.withLock { count in
                count += 1
                return prefix + String(format: "%08x", count)
            }
        }
    }

    /// The blocks fixed on the text cursor's first place: (300, 244) to (300, 260) on the screen.
    static func caretBlocks(_ regions: [ZoomRegion]) -> [ZoomRegion] {
        regions.filter { region in
            guard case let .fixed(x, y) = region.focus else { return false }
            return abs(x - 300.0 / 640) < 1e-9 && abs(y - 252.0 / 360) < 1e-9
        }
    }

    /// A look unlike Toma's (another padding), its automatic zoom following the focus as `followsFocus` says.
    static func look(followsFocus: Bool) -> DefaultStyle {
        var look = DefaultStyle.toma
        look.style.padding = 0.12
        look.zoomAuto.groupGap = 2.0
        look.zoomAuto.followsFocus = followsFocus
        return look
    }
}

@Test func newDocumentFollowsFocusOnlyWithFocusEvents() async throws {
    try await withTemporaryDirectory { dir in
        let focused = try await FocusFixture.take(in: dir, name: "focused", focus: true)
        let plain = try await FocusFixture.take(in: dir, name: "plain", focus: false)
        let document = FocusFixture.make(focused)
        #expect(document.zoom.auto.followsFocus)
        // Everything else of the zoom's settings is the default style's.
        var auto = document.zoom.auto
        auto.followsFocus = false
        #expect(auto == DefaultStyle.toma.zoomAuto)
        // The blocks planned with it: the click's, and the text cursor's, from 0.5 s before it to 1.0 s after the
        // typing (4.75 s).
        #expect(document.zoom.regions == AutoZoomPlanner.plan(take: focused.take, events: focused.events, document: document))
        let caret = try #require(FocusFixture.caretBlocks(document.zoom.regions).first)
        #expect(caret.start == FocusFixture.at(3.05) && caret.end == FocusFixture.at(5.75))

        // Without focus, the default style's settings and the blocks of always: the typing makes one at the click.
        let usual = FocusFixture.make(plain)
        #expect(!usual.zoom.auto.followsFocus)
        #expect(usual.zoom.auto == DefaultStyle.toma.zoomAuto)
        #expect(!usual.zoom.regions.isEmpty)
        #expect(FocusFixture.caretBlocks(usual.zoom.regions).isEmpty)
        #expect(usual.zoom.regions.allSatisfy { $0.focus == .follow })
        #expect(usual.zoom.regions == AutoZoomPlanner.plan(take: plain.take, events: plain.events, document: usual))
        // The same take with its focus, followed or not, gives the blocks of always with it off.
        var off = document
        off.zoom.auto.followsFocus = false
        off.zoom.regions = []
        #expect(AutoZoomPlanner.plan(take: focused.take, events: focused.events, document: off) == usual.zoom.regions)
    }
}

@Test func applyingAStyleKeepsFollowsFocus() async throws {
    try await withTemporaryDirectory { dir in
        let project = try await FocusFixture.take(in: dir, name: "focused", focus: true)
        let followed = FocusFixture.make(project)
        var unfollowed = followed
        unfollowed.zoom.auto.followsFocus = false
        for document in [followed, unfollowed] {
            for saved in [true, false] {
                let look = FocusFixture.look(followsFocus: saved)
                let comment: Comment = "document \(document.zoom.auto.followsFocus), style \(saved)"
                let named = NamedStyle(id: "0a1b2c3d", name: "Tutoriales", look: look, camera: .newProjects)
                let steps = [
                    StyleCommands.applyDefaultStyle(document, look, take: project.take, events: project.events),
                    StyleCommands.applyStyle(document, named, take: project.take, events: project.events),
                ]
                for step in steps {
                    let step = try #require(step, comment)
                    let edited = try document.applying(step.changes)
                    #expect(edited.zoom.auto.followsFocus == document.zoom.auto.followsFocus, comment)
                    // The rest of the style's settings are the project's now.
                    #expect(edited.zoom.auto.groupGap == 2.0, comment)
                    #expect(edited.style.padding == 0.12, comment)
                    // Its blocks are planned with the document's own choice.
                    #expect(
                        edited.zoom.regions == AutoZoomPlanner.plan(take: project.take, events: project.events, document: edited),
                        comment)
                    #expect(FocusFixture.caretBlocks(edited.zoom.regions).isEmpty != document.zoom.auto.followsFocus, comment)
                    // And it is the style's, followed or not.
                    #expect(StyleCommands.matchingStyle(edited, among: [named]) == .named(named.id), comment)
                }
            }
        }
    }
}

@Test func aFocusProjectStillMatchesTomasStyle() async throws {
    try await withTemporaryDirectory { dir in
        let project = try await FocusFixture.take(in: dir, name: "focused", focus: true)
        let document = FocusFixture.make(project)
        #expect(document.zoom.auto.followsFocus)
        #expect(StyleCommands.matchingStyle(document, among: []) == .toma)
        // Turned off, it still is: whether it follows the focus is the take's, not the style's.
        var off = document
        off.zoom.auto.followsFocus = false
        #expect(StyleCommands.matchingStyle(off, among: []) == .toma)
        // A saved style just like Toma's that follows the focus is named first for both.
        let likeToma = NamedStyle(id: "22222222", name: "Como Toma", look: FocusFixture.look(followsFocus: true), camera: .newProjects)
        var padded = document
        padded.style.padding = 0.12
        padded.zoom.auto.groupGap = 2.0
        #expect(StyleCommands.matchingStyle(padded, among: [likeToma]) == .named(likeToma.id))
        padded.zoom.auto.followsFocus = false
        #expect(StyleCommands.matchingStyle(padded, among: [likeToma]) == .named(likeToma.id))
    }
}

@Test func followsFocusIsOneUndoableStep() async throws {
    try await withTemporaryDirectory { dir in
        let project = try await FocusFixture.take(in: dir, name: "focused", focus: true)
        let takes = [(project.take, project.events)]
        let followed = FocusFixture.make(project)
        // Off: one step that sets `/zoom/auto` and plans the blocks of always.
        var settings = followed.zoom.auto
        settings.followsFocus = false
        let off = ZoomCommands.regenerate(followed, takes: takes, settings: settings)
        #expect(off.label == .zoomRegenerate && off.target == "/zoom/auto")
        let unfollowed = try followed.applying(off.changes)
        #expect(!unfollowed.zoom.auto.followsFocus)
        #expect(FocusFixture.caretBlocks(unfollowed.zoom.regions).isEmpty)
        #expect(try unfollowed.applying(off.changes.reversed().map(\.inverse)) == followed)

        // On again: the text cursor's blocks come back, in one step that undoes.
        let on = ZoomCommands.regenerate(unfollowed, takes: takes, settings: followed.zoom.auto)
        #expect(on.label == .zoomRegenerate && on.target == "/zoom/auto")
        #expect(on.changes.contains { change in
            if case let .set(path, _, _) = change { path.string == "/zoom/auto" } else { false }
        })
        let refollowed = try unfollowed.applying(on.changes)
        #expect(refollowed.zoom.auto.followsFocus)
        #expect(FocusFixture.caretBlocks(refollowed.zoom.regions).count == 1)
        #expect(refollowed.zoom.regions == followed.zoom.regions)
        #expect(try refollowed.applying(on.changes.reversed().map(\.inverse)) == unfollowed)
    }
}
