// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import RecorderKitTestSupport
import Synchronization
import Testing
// Not @testable: the app uses only the public API.
import Editing
import ProjectFormat

/// The editor keeps the rules of the document of phase 3 (base plan decision 6): a step that breaks one is refused and
/// writes nothing, and a document edited by hand that breaks one opens read-only, shown as it can be drawn.
@MainActor @Suite struct DocumentRulesTests {
    nonisolated private static let base = HostTime(nanoseconds: 5_000_000_000_000)

    /// `c-00000001`, `c-00000002`… from 1 for each new instance.
    private final class IDs: Sendable {
        private let count = Mutex(0)

        func make(_ prefix: String) -> String {
            count.withLock { count in
                count += 1
                return prefix + String(format: "%08x", count)
            }
        }
    }

    private static func context(caches: URL) -> EditContext {
        let ids = IDs()
        let clock = Mutex(Date(timeIntervalSince1970: 1_794_773_523))
        return EditContext(
            app: AppInfo(name: "Toma", version: "0.3.0"), cachesRoot: caches, defaultStyle: .toma,
            now: { clock.withLock { date in defer { date += 2 }; return date } }, makeID: { ids.make($0) })
    }

    /// A take of 2 s of one display, in a new package `<name>.toma`, written off the main actor.
    @concurrent private static func package(in dir: URL, name: String) async throws -> LoadedProject {
        let builder = try TakeBuilder(in: dir, name: name)
        let frame = Rect(x: 0, y: 0, width: 640, height: 360)
        try await builder.addVideoTrack(
            id: "display-1", source: TrackSource(name: "Synthetic Display", displayID: 1, globalFrame: frame, pixelScale: 1),
            segments: [VideoSegmentSpec(start: base, seconds: 2, framesPerSecond: 10)])
        try builder.addEvents([InputEvent(t: base.adding(seconds: -0.01), kind: .displayGeometry(displayID: 1, frame: frame, scale: 1))])
        return try builder.write()
    }

    /// `clip` as the sequence holds it.
    private static func encoded(_ clip: Clip) throws -> JSONValue { try JSONValue(encoding: clip) }

    /// The step that replaces clip `k` of `document` with `change` made to it.
    private static func replacing(_ k: Int, of document: EditDocument, _ change: (inout Clip) -> Void) throws -> EditStep {
        var clip = document.sequence[k]
        change(&clip)
        return EditStep(
            label: .clipContent, target: clip.id,
            changes: [.replace(
                collection: EditCollection.sequence.pointer, id: clip.id, before: try encoded(document.sequence[k]), after: try encoded(clip))])
    }

    @Test func anEditBreakingARuleIsRefused() async throws {
        try await withTemporaryDirectory { dir in
            let project = try await Self.package(in: dir, name: "Rules")
            let session = try await EditSession.open(project.package.url, take: nil, context: Self.context(caches: dir.appending(path: "Caches")))
            #expect(session.access == .editable)
            // Two clips of 1 s, the second where the first ends.
            let split = try #require(SequenceCommands.split(session.document, atOutput: 1_000_000_000, makeID: { _ in "c-00000abc" }))
            #expect(session.perform(split) == .applied)
            _ = await session.flushed()
            let entries = try EditLogReader.read(project.package.editLogURL).entries.count
            let document = session.document

            // A frozen frame that is not a point.
            #expect(session.perform(try Self.replacing(1, of: document) { $0.content = .freeze(duration: 2_000_000_000) }) == .refused)
            // A cut of the sound past half of the shorter clip, or at the first clip.
            #expect(session.perform(try Self.replacing(1, of: document) { $0.audioShift = 600_000_000 }) == .refused)
            #expect(session.perform(try Self.replacing(0, of: document) { $0.audioShift = -1 }) == .refused)
            // The clips of the take out of order.
            #expect(session.perform(try Self.replacing(1, of: document) { $0.start = document.sequence[0].start }) == .refused)
            // A theme from outside the package.
            let theme = EditStep(
                label: .musicAdd, target: "mu-00000001",
                changes: [.insert(
                    collection: EditCollection.music.pointer, index: 0,
                    value: try JSONValue(encoding: MusicItem(id: "mu-00000001", source: "/tmp/a.mp3", start: 0, end: 1_000_000_000)))])
            #expect(session.perform(theme) == .refused)
            #expect(session.document == document)
            _ = await session.flushed()
            #expect(try EditLogReader.read(project.package.editLogURL).entries.count == entries)

            // Within the rules, the same steps apply.
            #expect(session.perform(try Self.replacing(1, of: document) { $0.audioShift = 500_000_000 }) == .applied)
            #expect(session.perform(try Self.replacing(1, of: session.document) { clip in
                clip.end = clip.start
                clip.content = .freeze(duration: 2_000_000_000)
                clip.audioShift = 0
            }) == .applied)
            await session.close()
        }
    }

    @Test func aHandEditedDocumentOpensReadOnlyDrawable() async throws {
        try await withTemporaryDirectory { dir in
            let caches = dir.appending(path: "Caches")
            let project = try await Self.package(in: dir, name: "Hand")
            let opened = try await EditSession.open(project.package.url, take: nil, context: Self.context(caches: caches))
            var document = opened.document
            await opened.close()
            // By hand: a frozen frame over the take's first second, a cut of the sound at the first clip, an image from
            // outside the package and a theme of another library.
            let clip = document.sequence[0]
            document.sequence.insert(
                Clip(id: "c-0000f00f", take: clip.take, start: clip.start, end: clip.start.adding(seconds: 1), speed: 1,
                     content: .freeze(duration: 90_000_000_000)),
                at: 0)
            document.sequence[1].audioShift = 250_000_000
            document.annotations.items = [
                Annotation(
                    id: "a-00000001", anchor: .whole, layer: 0, kind: .image(ImageAnnotation(asset: "../outside.png", fit: .fit)),
                    rect: NormalizedRect(x: 0, y: 0, width: 0.2, height: 0.2)),
                Annotation(
                    id: "a-00000002", anchor: .whole, layer: 1, kind: .text(TextAnnotation(string: "Hola", preset: .plain)),
                    rect: NormalizedRect(x: 0, y: 0, width: 0.2, height: 0.2)),
            ]
            document.music.items = [MusicItem(id: "mu-00000001", source: "library:music-2/x", start: 0, end: 1_000_000_000)]
            #expect(!DocumentRules.problems(in: document).isEmpty)
            try ProjectJSON.encoder().encode(document).write(to: project.package.editURL)
            try FileManager.default.removeItem(at: project.package.editLogURL)
            let before = try treeHash(project.package.url)

            let session = try await EditSession.open(project.package.url, take: nil, context: Self.context(caches: caches))
            #expect(session.access == .readOnly(.unsafeEditFiles))
            let shown = session.document
            #expect(shown.sequence[0].end == shown.sequence[0].start)
            #expect(shown.sequence[0].content == .freeze(duration: 60_000_000_000))
            #expect(shown.sequence[1].audioShift == 0)
            #expect(shown.annotations.items.map(\.id) == ["a-00000002"])
            #expect(shown.music.items.isEmpty)
            #expect(DocumentRules.problems(in: shown) == [])
            #expect(session.perform(try Self.replacing(1, of: shown) { $0.speed = 2 }) == .refused)
            await session.close()
            #expect(try treeHash(project.package.url) == before)
            let (_, read) = try EditSession.readDocument(project.package.url, take: nil, context: Self.context(caches: caches))
            #expect(read == shown)
        }
    }
}
