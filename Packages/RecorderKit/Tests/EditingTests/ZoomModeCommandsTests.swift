// SPDX-License-Identifier: GPL-3.0-or-later
import Analysis
import Foundation
import Testing
// Not @testable: the app uses only the public API.
import Editing
import ProjectFormat

/// A take of one display recorded for 60 s from `base` and a document of one clip over all of it, with Toma's automatic
/// zoom in `autoMode`, namespaced so that no other file of EditingTests meets its names.
private enum ModeFixture {
    static let takeID = "take-001"
    static let base = HostTime(nanoseconds: 5_000_000_000_000)

    static func at(_ seconds: Double) -> HostTime { base.adding(seconds: seconds) }
    static func output(_ seconds: Double) -> Int64 { TimeMap.outputNanoseconds(seconds: seconds) }

    static let take = TakeRecord(
        id: takeID, status: .complete, startedAt: Date(timeIntervalSince1970: 1_800_000_000),
        tracks: [
            TrackRecord(
                id: "display-1", kind: .display,
                source: TrackSource(name: "Display", displayID: 1, globalFrame: Rect(x: 0, y: 0, width: 1440, height: 900), pixelScale: 2),
                segments: [
                    SegmentRecord(
                        index: 1, file: "takes/take-001/display-1/seg-0001.mov", startHostTime: base, endHostTime: at(60),
                        endReason: .stopped, droppedFrames: 0, heartbeatFrames: 0)
                ])
        ])

    static func block(
        _ id: String, from: Double, to: Double, origin: Origin = .user, mode: ZoomMode? = nil, loupe: LoupeStyle? = nil
    ) -> ZoomRegion {
        ZoomRegion(
            id: id, take: takeID, start: at(from), end: at(to), origin: origin, depth: 1.6, focus: .follow, instant: false,
            mode: mode, loupe: loupe)
    }

    static func document(_ regions: [ZoomRegion] = [], autoMode: ZoomMode = .classic) -> EditDocument {
        var document = EditDocument.legacy(take: take, events: [])
        document.sequence = [Clip(id: "c-00000001", take: takeID, start: base, end: at(60), speed: 1)]
        document.screens = ScreenPlan(initial: [takeID: "display-1"], changes: [])
        document.zoom.auto = DefaultStyle.toma.zoomAuto
        document.zoom.auto.mode = autoMode
        document.zoom.regions = regions
        return document
    }

    static func applying(_ step: EditStep, to document: EditDocument) throws -> EditDocument {
        let edited = try document.applying(step.changes)
        #expect(try edited.applying(step.changes.reversed().map(\.inverse)) == document)
        return edited
    }

    final class IDs {
        private var next = 0x10
        func make(_ prefix: String) -> String {
            defer { next += 1 }
            return prefix + String(format: "%08x", next)
        }
    }
}

@Test func resolvedModeFollowsTheOrigin() {
    var auto = DefaultStyle.toma.zoomAuto
    auto.mode = .dim
    #expect(ModeFixture.block("z-1", from: 1, to: 2).resolvedMode(auto: auto) == .classic)
    #expect(ModeFixture.block("z-1", from: 1, to: 2, origin: .auto).resolvedMode(auto: auto) == .dim)
    #expect(ModeFixture.block("z-1", from: 1, to: 2, mode: .loupe).resolvedMode(auto: auto) == .loupe)
    #expect(ModeFixture.block("z-1", from: 1, to: 2, origin: .auto, mode: .highlight).resolvedMode(auto: auto) == .highlight)
    #expect(!ZoomMode.classic.isCalm)
    #expect(ZoomMode.highlight.isCalm && ZoomMode.dim.isCalm && ZoomMode.loupe.isCalm)
}

@Test func resolvedLoupeIsHeld() {
    func loupe(_ radius: Double?, _ shape: LoupeShape = .circle) -> LoupeStyle {
        ModeFixture.block("z-1", from: 1, to: 2, loupe: radius.map { LoupeStyle(radius: $0, shape: shape) }).resolvedLoupe
    }
    #expect(loupe(nil) == .default)
    #expect(loupe(0.5).radius == 0.4)
    #expect(loupe(0.01).radius == 0.06)
    #expect(loupe(.nan).radius == 0.16)
    #expect(loupe(0.2, .roundedRect) == LoupeStyle(radius: 0.2, shape: .roundedRect))
    #expect(loupe(.nan, .roundedRect).shape == .roundedRect)
}

@Test func aNewBlockIsBornWithTheSettingsMode() throws {
    for mode in [ZoomMode.loupe, .classic] {
        let document = ModeFixture.document(autoMode: mode)
        let ids = ModeFixture.IDs()
        let added = try #require(
            ZoomCommands.add(document, output: ModeFixture.output(2)..<ModeFixture.output(5), makeID: ids.make))
        let centered = try #require(ZoomCommands.addCentered(document, at: ModeFixture.output(20), makeID: ids.make))
        for step in [added, centered] {
            let region = try #require(try ModeFixture.applying(step, to: document).zoom.regions.first)
            #expect(region.mode == (mode == .classic ? nil : mode))
            #expect(region.loupe == nil)
            #expect(region.origin == .user)
        }
    }
}

@Test func setModeMakesAnAutomaticBlockTheUsers() throws {
    let auto = ModeFixture.block("z-0000000a", from: 2, to: 4, origin: .auto)
    let document = ModeFixture.document([auto])
    let step = try #require(ZoomCommands.setMode(document, id: "z-0000000a", mode: .highlight))
    #expect(step.label == .zoomMode)
    #expect(step.target == "z-0000000a")
    let region = try #require(try ModeFixture.applying(step, to: document).zoom.regions.first)
    #expect(region.origin == .user)
    #expect(region.mode == .highlight)
    #expect(region.id == "z-0000000a")
    // The same mode, nothing; a block that is not there, nothing.
    let user = ModeFixture.document([ModeFixture.block("z-0000000b", from: 2, to: 4, mode: .dim)])
    #expect(ZoomCommands.setMode(user, id: "z-0000000b", mode: .dim) == nil)
    #expect(ZoomCommands.setMode(user, id: "z-nope", mode: .dim) == nil)
    #expect(ZoomCommands.setMode(ModeFixture.document([auto]), id: "z-0000000a", mode: .classic) == nil)
    // Classic in a block of the user's is no mode at all.
    let back = try #require(ZoomCommands.setMode(user, id: "z-0000000b", mode: .classic))
    #expect(try ModeFixture.applying(back, to: user).zoom.regions.first?.mode == nil)
    // An automatic block that shows `loupe` made classic by hand does not come back to `loupe`.
    let loupeAuto = ModeFixture.document([auto], autoMode: .loupe)
    let classic = try #require(ZoomCommands.setMode(loupeAuto, id: "z-0000000a", mode: .classic))
    let edited = try ModeFixture.applying(classic, to: loupeAuto).zoom.regions[0]
    #expect(edited.mode == nil && edited.origin == .user)
    #expect(edited.resolvedMode(auto: loupeAuto.zoom.auto) == .classic)
}

@Test func touchingAnAutomaticBlockKeepsItsMode() throws {
    let id = "z-0000000a"
    for autoMode in [ZoomMode.loupe, .classic] {
        let document = ModeFixture.document([ModeFixture.block(id, from: 10, to: 14, origin: .auto)], autoMode: autoMode)
        let expected: ZoomMode? = autoMode == .classic ? nil : autoMode
        let steps: [EditStep?] = [
            ZoomCommands.trim(document, id: id, edge: .end, toOutput: ModeFixture.output(13)),
            ZoomCommands.change(document, id: id, depth: .some(2.5)),
            ZoomCommands.change(document, id: id, focus: .fixed(x: 0.2, y: 0.3)),
            ZoomCommands.change(document, id: id, instant: true),
            ZoomCommands.setLoupe(document, id: id, radius: 0.3),
            ZoomCommands.move(document, id: id, toOutputStart: ModeFixture.output(20), makeID: ModeFixture.IDs().make),
        ]
        for step in steps {
            let edited = try ModeFixture.applying(try #require(step), to: document).zoom.regions
            #expect(edited.count == 1)
            #expect(edited[0].origin == .user)
            #expect(edited[0].mode == expected)
            #expect(edited[0].resolvedMode(auto: document.zoom.auto) == autoMode)
        }
    }
    // A block of the user's keeps what it has.
    let user = ModeFixture.document([ModeFixture.block(id, from: 10, to: 14, mode: .dim)], autoMode: .loupe)
    let step = try #require(ZoomCommands.change(user, id: id, depth: .some(3)))
    #expect(try ModeFixture.applying(step, to: user).zoom.regions[0].mode == .dim)
    let plain = ModeFixture.document([ModeFixture.block(id, from: 10, to: 14)], autoMode: .loupe)
    let plainStep = try #require(ZoomCommands.change(plain, id: id, depth: .some(3)))
    #expect(try ModeFixture.applying(plainStep, to: plain).zoom.regions[0].mode == nil)
}

@Test func setLoupeHoldsTheRadius() throws {
    let id = "z-0000000a"
    let document = ModeFixture.document([ModeFixture.block(id, from: 10, to: 14, mode: .loupe)])
    func loupe(radius: Double? = nil, shape: LoupeShape? = nil, in document: EditDocument = document) throws -> LoupeStyle? {
        let step = try #require(ZoomCommands.setLoupe(document, id: id, radius: radius, shape: shape))
        #expect(step.label == .zoomChange)
        return try ModeFixture.applying(step, to: document).zoom.regions[0].loupe
    }
    #expect(try loupe(radius: 0.5) == LoupeStyle(radius: 0.4))
    #expect(try loupe(radius: 0.01)?.radius == 0.06)
    #expect(ZoomCommands.setLoupe(document, id: id, radius: .nan) == nil)
    #expect(ZoomCommands.setLoupe(document, id: id, radius: 0.16) == nil)
    #expect(ZoomCommands.setLoupe(document, id: "z-nope", radius: 0.2) == nil)
    #expect(try loupe(shape: .roundedRect) == LoupeStyle(radius: 0.16, shape: .roundedRect))
    // A radius and a shape on their own leave the other field.
    let wide = ModeFixture.document([ModeFixture.block(id, from: 10, to: 14, mode: .loupe, loupe: LoupeStyle(radius: 0.3, shape: .roundedRect))])
    #expect(try loupe(radius: 0.2, in: wide) == LoupeStyle(radius: 0.2, shape: .roundedRect))
    #expect(try loupe(shape: .circle, in: wide) == LoupeStyle(radius: 0.3, shape: .circle))
    // Back to the default lens is no lens.
    let back = try loupe(radius: 0.16, shape: .circle, in: wide)
    #expect(back == nil)
}

@Test func setAutoModeIsOneStepWithoutPlanning() throws {
    let auto = ModeFixture.block("z-0000000a", from: 2, to: 4, origin: .auto)
    let own = ModeFixture.block("z-0000000b", from: 6, to: 8, mode: .highlight)
    let document = ModeFixture.document([auto, own])
    let step = try #require(ZoomCommands.setAutoMode(document, .dim))
    #expect(step.label == .zoomMode)
    #expect(step.target == "/zoom/auto/mode")
    #expect(step.changes.count == 1)
    let edited = try ModeFixture.applying(step, to: document)
    #expect(edited.zoom.regions == document.zoom.regions)
    #expect(edited.zoom.auto.mode == .dim)
    #expect(edited.zoom.regions[0].resolvedMode(auto: edited.zoom.auto) == .dim)
    #expect(edited.zoom.regions[1].resolvedMode(auto: edited.zoom.auto) == .highlight)
    #expect(ZoomCommands.setAutoMode(edited, .dim) == nil)
}

@Test func regenerateCarriesTheSettingsMode() throws {
    let events = [
        InputEvent(t: ModeFixture.at(5), kind: .mouseDown(.left, x: 720, y: 450)),
        InputEvent(t: ModeFixture.at(5.05), kind: .mouseUp(.left, x: 720, y: 450)),
    ]
    let document = ModeFixture.document()
    var settings = document.zoom.auto
    settings.mode = .dim
    let step = ZoomCommands.regenerate(document, take: ModeFixture.take, events: events, settings: settings)
    let edited = try ModeFixture.applying(step, to: document)
    #expect(edited.zoom.auto.mode == .dim)
    #expect(!edited.zoom.regions.isEmpty)
    for region in edited.zoom.regions {
        #expect(region.origin == .auto)
        #expect(region.mode == nil)
        #expect(region.resolvedMode(auto: edited.zoom.auto) == .dim)
    }
}
