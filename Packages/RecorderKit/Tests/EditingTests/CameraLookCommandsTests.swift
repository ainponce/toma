// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import Testing
// Not @testable: the app uses only the public API.
import Editing
import ProjectFormat

private enum LookFixture {
    static let take = "take-001"
    static let base = HostTime(nanoseconds: 5_000_000_000_000)
    static let style = CameraStyle(shape: .circle, size: CameraStyle.medium, anchor: .bottomTrailing)

    static func change(_ n: Int, origin: CameraOrigin) -> CameraChange {
        CameraChange(
            id: "k-0000000\(n)", take: take, t: base.adding(seconds: Double(n)),
            style: CameraStyle(shape: .circle, size: CameraStyle.medium, anchor: .topLeading), origin: origin)
    }

    static func document(changes: [CameraChange] = []) -> EditDocument {
        var document = EditDocument.legacy(take: TakeRecord(
            id: take, status: .complete, startedAt: Date(timeIntervalSince1970: 1_800_000_000), tracks: []), events: [])
        document.camera = CameraPlan(show: true, initial: [take: style], changes: changes)
        return document
    }

    static func apply(_ step: EditStep?, to doc: EditDocument) throws -> EditDocument {
        try doc.applying(try #require(step).changes)
    }
}

@Test func deleteAllChangesIsOneStep() throws {
    let changes = [
        LookFixture.change(1, origin: .recorded), LookFixture.change(2, origin: .user), LookFixture.change(3, origin: .user),
    ]
    let doc = LookFixture.document(changes: changes)
    let step = try #require(CameraLookCommands.deleteAllChanges(doc))
    #expect(step.label == .cameraChangesDeleteAll)
    #expect(step.changes.count == 3)
    #expect(step.changes.allSatisfy { if case .remove = $0 { true } else { false } })
    let after = try LookFixture.apply(step, to: doc)
    #expect(after.camera.changes.isEmpty)
    let back = try after.applying(step.changes.reversed().map(\.inverse))
    #expect(back.camera.changes == changes)
    #expect(CameraLookCommands.deleteAllChanges(after) == nil)
}

@Test func borderAndShadowAreClamped() throws {
    let doc = LookFixture.document()
    #expect(try LookFixture.apply(CameraLookCommands.setBorderWidth(doc, 1.5), to: doc).camera.border.width == 1)
    var shadowed = doc
    shadowed.camera.shadow = 0.4
    #expect(try LookFixture.apply(CameraLookCommands.setShadow(shadowed, -0.2), to: shadowed).camera.shadow == 0)
    let colour = try LookFixture.apply(CameraLookCommands.setBorderColor(doc, RGBA(2, -1, 0.5, 1)), to: doc)
    #expect(colour.camera.border.color == RGBA(1, 0, 0.5, 1))
    #expect(CameraLookCommands.setBorderWidth(doc, .nan) == nil)
    #expect(CameraLookCommands.setShadow(doc, .nan) == nil)
    #expect(CameraLookCommands.setBorderColor(doc, RGBA(.nan, 0, 0, 1)) == nil)
}

@Test func commandsSetTheirValueAndKeepTheirLabels() throws {
    let doc = LookFixture.document()
    let mirrored = CameraLookCommands.setMirror(doc, true)
    #expect(mirrored?.label == .cameraMirror)
    #expect(try LookFixture.apply(mirrored, to: doc).camera.mirror)
    let width = CameraLookCommands.setBorderWidth(doc, 0.5)
    #expect(width?.label == .cameraBorder)
    #expect(try LookFixture.apply(width, to: doc).camera.border.width == 0.5)
    let colour = CameraLookCommands.setBorderColor(doc, CameraLookCommands.borderSwatches[3])
    #expect(colour?.label == .cameraBorder)
    #expect(colour?.target != width?.target)
    let shadow = CameraLookCommands.setShadow(doc, 0.7)
    #expect(shadow?.label == .cameraShadow)
    #expect(try LookFixture.apply(shadow, to: doc).camera.shadow == 0.7)
}

@Test func sameValueIsNoStep() {
    let doc = LookFixture.document()
    #expect(CameraLookCommands.setMirror(doc, false) == nil)
    #expect(CameraLookCommands.setBorderWidth(doc, 0) == nil)
    #expect(CameraLookCommands.setBorderColor(doc, RGBA(1, 1, 1, 1)) == nil)
    #expect(CameraLookCommands.setShadow(doc, 0) == nil)
    #expect(CameraLookCommands.deleteAllChanges(doc) == nil)
}

@Test func swatchesAreTheDecisionColors() {
    #expect(CameraLookCommands.borderSwatches == [
        RGBA(1, 1, 1, 1), RGBA(0, 0, 0, 1), RGBA(0.5, 0.5, 0.5, 1),
        RGBA(127 / 255, 90 / 255, 240 / 255, 1), RGBA(44 / 255, 177 / 255, 188 / 255, 1), RGBA(1, 107 / 255, 107 / 255, 1),
    ])
}

@Test func lookAppliesToACameraKeepingItsStyles() {
    let legacy = LookFixture.document(changes: [LookFixture.change(1, origin: .user)]).camera
    let look = CameraLook.newProjects.applied(to: legacy)
    #expect(look.mirror && look.shadow == 0.4 && look.sizeReference == .shortSide && look.border == .none)
    #expect(look.initial == legacy.initial && look.changes == legacy.changes && look.layouts == legacy.layouts)
}
