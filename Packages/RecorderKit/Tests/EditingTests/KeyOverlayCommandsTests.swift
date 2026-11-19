// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import Testing
// Not @testable: the app uses only the public API.
import Editing
import ProjectFormat

@Suite struct KeyOverlayCommandsTests {
    func document() -> EditDocument {
        EditDocument.legacy(
            take: TakeRecord(id: "take-001", status: .complete, startedAt: Date(timeIntervalSince1970: 1_800_000_000), tracks: []),
            events: [])
    }

    @Test func keysCommandIsOneSetPerField() throws {
        let doc = document()
        let step = try #require(KeyOverlayCommands.set(doc, mode: .all, position: .top, size: .large))
        #expect(step.label == .keysOverlay && step.target == "/keys" && step.changes.count == 3)
        let after = try doc.applying(step.changes)
        #expect(after.keys == KeyOverlayPlan(mode: .all, position: .top, size: .large))
        let one = try #require(KeyOverlayCommands.set(doc, mode: .shortcuts))
        #expect(one.changes.count == 1)
        // What is already there, or nothing, changes nothing.
        #expect(KeyOverlayCommands.set(doc, mode: .off, position: .bottomCenter, size: .medium) == nil)
        #expect(KeyOverlayCommands.set(doc) == nil)
        // Undoing is the inverse.
        #expect(try after.applying(step.changes.reversed().map(\.inverse)) == doc)
    }
}
