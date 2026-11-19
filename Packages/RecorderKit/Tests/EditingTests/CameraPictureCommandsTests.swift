// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import Testing
// Not @testable: the app uses only the public API.
import Editing
import ProjectFormat

private func document() -> EditDocument {
    EditDocument.legacy(
        take: TakeRecord(id: "take-001", status: .complete, startedAt: Date(timeIntervalSince1970: 1_800_000_000), tracks: []),
        events: [])
}

private func applied(_ step: EditStep?, to doc: EditDocument) throws -> EditDocument {
    try doc.applying(try #require(step).changes)
}

@Test func eachCommandSetsItsPlace() throws {
    let doc = document()
    let cases: [(EditStep?, EditLabel, String)] = [
        (CameraPictureCommands.setBackground(doc, .blurred), .cameraBackground, "/camera/background"),
        (CameraPictureCommands.setFramingMode(doc, .manual), .cameraFraming, "/camera/framing/mode"),
        (CameraPictureCommands.setFramingCenter(doc, NormalizedPoint(x: 0.2, y: 0.7)), .cameraFraming, "/camera/framing/center"),
        (CameraPictureCommands.setFramingZoom(doc, 2), .cameraFraming, "/camera/framing/zoom"),
        (CameraPictureCommands.setLookPreset(doc, .warm), .cameraLook, "/camera/look/preset"),
        (CameraPictureCommands.setLookIntensity(doc, 0.5), .cameraLook, "/camera/look/intensity"),
        (CameraPictureCommands.setCustomLook(doc, file: "assets/abc.cube"), .cameraLook, "/camera/look"),
    ]
    for (step, label, target) in cases {
        let step = try #require(step)
        #expect(step.label == label)
        #expect(step.target == target)
    }
    #expect(try applied(cases[0].0, to: doc).camera.background == .blurred)
    #expect(try applied(cases[2].0, to: doc).camera.framing.center == NormalizedPoint(x: 0.2, y: 0.7))
    #expect(try applied(cases[5].0, to: doc).camera.look.intensity == 0.5)
    // The same value is nothing.
    #expect(CameraPictureCommands.setBackground(doc, .original) == nil)
    #expect(CameraPictureCommands.setFramingMode(doc, .center) == nil)
    #expect(CameraPictureCommands.setFramingCenter(doc, NormalizedPoint(x: 0.5, y: 0.5)) == nil)
    #expect(CameraPictureCommands.setFramingZoom(doc, 1) == nil)
    #expect(CameraPictureCommands.setLookPreset(doc, .natural) == nil)
    #expect(CameraPictureCommands.setLookIntensity(doc, 1) == nil)
}

@Test func followFaceStartsAt1_4() throws {
    let doc = document()
    let step = try #require(CameraPictureCommands.setFramingMode(doc, .face))
    let after = try applied(step, to: doc)
    #expect(after.camera.framing.mode == .face)
    #expect(after.camera.framing.zoom == CameraFraming.faceZoom)
    #expect(step.changes.count == 2)

    var zoomed = doc
    zoomed.camera.framing.zoom = 2
    let kept = try applied(CameraPictureCommands.setFramingMode(zoomed, .face), to: zoomed)
    #expect(kept.camera.framing.zoom == 2)
}

@Test func valuesAreKeptInRange() throws {
    let doc = document()
    let center = try applied(CameraPictureCommands.setFramingCenter(doc, NormalizedPoint(x: -1, y: 2)), to: doc)
    #expect(center.camera.framing.center == NormalizedPoint(x: 0, y: 1))
    #expect(try applied(CameraPictureCommands.setFramingZoom(doc, 3), to: doc).camera.framing.zoom == 2.5)
    var dim = doc
    dim.camera.framing.zoom = 2
    #expect(try applied(CameraPictureCommands.setFramingZoom(dim, 0.2), to: dim).camera.framing.zoom == 1)
    dim.camera.look.intensity = 0.5
    #expect(try applied(CameraPictureCommands.setLookIntensity(dim, 1.2), to: dim).camera.look.intensity == 1)
    #expect(CameraPictureCommands.setFramingZoom(doc, .nan) == nil)
    #expect(CameraPictureCommands.setLookIntensity(doc, .nan) == nil)
    #expect(CameraPictureCommands.setFramingCenter(doc, NormalizedPoint(x: .nan, y: 0)) == nil)
}

@Test func customNeedsAFile() throws {
    let doc = document()
    #expect(CameraPictureCommands.setLookPreset(doc, .custom) == nil)
    let step = try #require(CameraPictureCommands.setCustomLook(doc, file: "assets/abc.cube"))
    #expect(step.changes.count == 1)
    let after = try applied(step, to: doc)
    #expect(after.camera.look.preset == .custom)
    #expect(after.camera.look.lut == "assets/abc.cube")
    // With a file in the document, the preset can come back to custom, and leaves the file where it is.
    let natural = try applied(CameraPictureCommands.setLookPreset(after, .mono), to: after)
    #expect(natural.camera.look.lut == "assets/abc.cube")
    #expect(CameraPictureCommands.setLookPreset(natural, .custom) != nil)
    #expect(CameraPictureCommands.setCustomLook(after, file: "assets/abc.cube") == nil)
    #expect(CameraPictureCommands.setCustomLook(doc, file: "") == nil)
}
