// SPDX-License-Identifier: GPL-3.0-or-later
import Analysis
import CoreGraphics
import Editing
import Export
import Foundation
import ImageIO
import ProjectFormat
import RecorderKitTestSupport
import Testing
@testable import ProjectAPI

/// Each command is the step of the app's gesture (fases 4 y 5 design §6.2, plan 4b decisions 3 to 5).
private struct Steps {
    let project: LoadedProject
    let base: CommandScope

    init(_ project: LoadedProject, transcript: Bool = true) throws {
        self.project = project
        base = try APIFixtures.scope(of: project, transcript: transcript, makeID: { $0 + "unused" })
    }

    var document: EditDocument { base.document }
    var bounds: [String: ClosedRange<HostTime>] { APIFixtures.takeBounds(of: project) }
    var takes: [(TakeRecord, [InputEvent])] { [(project.take, project.events)] }
    var recorded: MarkerList.Recorded { CommandScope.recordedMarkers(of: project) }

    /// The step of `command` on `document`, with ids that count from 1.
    func step(_ command: ProjectCommand, on document: EditDocument? = nil) throws(APIError) -> CommandStep {
        let ids = APIFixtures.IDs()
        var scope = base
        if let document { scope.document = document }
        scope.makeID = { ids.make($0) }
        return try CommandSteps.step(for: command, in: scope)
    }

    func error(_ command: ProjectCommand, on document: EditDocument? = nil) -> APIError? {
        do throws(APIError) {
            _ = try step(command, on: document)
            return nil
        } catch {
            return error
        }
    }
}

private func ns(_ seconds: Double) -> Int64 { APIFixtures.ns(seconds) }

private func applied(_ step: EditStep?, to document: EditDocument) throws -> EditDocument {
    try document.applying(try unwrap(step, "step").changes)
}

/// `document` with a block of the user's from 2 to 5 s, and a piece of music.
private func withZoomAndMusic(_ document: EditDocument) throws -> (EditDocument, zoom: String, music: String) {
    let ids = APIFixtures.IDs()
    let zoom = try unwrap(ZoomCommands.add(document, output: ns(2)..<ns(5), makeID: { ids.make($0) }), "zoom")
    let zoomed = try document.applying(zoom.changes)
    let music = try unwrap(
        MusicCommands.add(
            zoomed, source: MusicThemes.source("calm"), atOutput: 0, timeMap: TimeMap(sequence: zoomed.sequence),
            makeID: { ids.make($0) }), "music")
    return (try zoomed.applying(music.changes), zoom.target, music.target)
}

@Test func eachCommandIsTheAppsStep() async throws {
    try await withTemporaryDirectory { dir in
        let s = try Steps(try await APIFixtures.package(in: dir))
        let doc = s.document
        let map = TimeMap(sequence: doc.sequence)
        let (full, zoomID, musicID) = try withZoomAndMusic(doc)
        let visible = MarkerList.visible(document: doc, recorded: s.recorded, timeMap: map)
        try #require(visible.count == 2)
        var auto = doc.zoom.auto
        auto.enabled.toggle()
        auto.followsFocus = true
        let text = AnnotationDefaults.kind(.text, text: "Clic")
        var rect = AnnotationDefaults.rect(for: text, aspect: nil, spaceAspect: 16.0 / 9)
        (rect.x, rect.y) = (0.5 - rect.width / 2, 0.5 - rect.height / 2)
        let background = Background.color(RGBA(0.1, 0.2, 0.3, 1))

        // The command, the document it is given, and the call the app's gesture makes with ids that count from 1.
        let cases: [(ProjectCommand, EditDocument, ((String) -> String) -> EditStep?)] = [
            (.cut(from: 1, to: 2), doc, { try? SequenceCommands.deleteRange(doc, output: ns(1)..<ns(2), takeBounds: s.bounds, makeID: $0).get() }),
            (.trimStart(to: 1), doc, { try? SequenceCommands.deleteRange(doc, output: 0..<ns(1), takeBounds: s.bounds, makeID: $0).get() }),
            (.trimEnd(from: 9), doc, { try? SequenceCommands.deleteRange(doc, output: ns(9)..<map.duration, takeBounds: s.bounds, makeID: $0).get() }),
            (.removeFillers, doc, { try? TranscriptCommands.removeFillers(doc, takeBounds: s.bounds, makeID: $0)?.get() }),
            (.shortenPauses(longerThan: 1), doc, {
                try? TranscriptCommands.shortenPauses(doc, threshold: ns(1), takeBounds: s.bounds, makeID: $0)?.get()
            }),
            (.addZoom(from: 2, to: 5, depth: nil, focus: nil), doc, { ZoomCommands.add(doc, output: ns(2)..<ns(5), makeID: $0) }),
            (.removeZoom(id: zoomID), full, { _ in ZoomCommands.delete(full, ids: [zoomID]) }),
            (.setAutoZoom(enabled: auto.enabled, followsFocus: true), doc, { _ in ZoomCommands.regenerate(doc, takes: s.takes, settings: auto) }),
            (.addMarker(at: 5, name: ""), doc, { MarkerCommands.add(doc, atOutput: ns(5), timeMap: map, recorded: s.recorded, makeID: $0) }),
            (.renameMarker(id: visible[0].id, name: "Uno"), doc, { MarkerCommands.rename(doc, visible[0], to: "Uno", makeID: $0) }),
            (.removeMarker(id: visible[1].id), doc, { MarkerCommands.delete(doc, visible[1], makeID: $0) }),
            (.setAspect(.square), doc, { _ in StyleCommands.setAspect(doc, .square) }),
            (.setBackground(background), doc, { _ in StyleCommands.set(doc, "/style/background", background, label: .background) }),
            (.setCameraLayout(.split, side: nil), doc, { _ in LayoutCommands.setProjectLayout(doc, .split) }),
            (.addTitleCard(at: .start, title: "Hola", subtitle: nil), doc, { ContentClipCommands.addCard(doc, at: .start, title: "Hola", makeID: $0) }),
            (.addTitleCard(at: .at(4), title: "Hola", subtitle: nil), doc, {
                ContentClipCommands.addCard(doc, at: .output(ns(4)), title: "Hola", makeID: $0)
            }),
            (.addText(from: 1, to: 4, text: "Clic", x: 0.5, y: 0.5), doc, {
                AnnotationCommands.add(doc, text, atOutput: ns(1), rect: rect, duration: ns(4) - ns(1), makeID: $0)
            }),
            (.addMusic(theme: "calm", volume: nil), doc, {
                MusicCommands.add(doc, source: MusicThemes.source("calm"), atOutput: 0, timeMap: map, makeID: $0)
            }),
            (.removeMusic, full, { _ in MusicCommands.delete(full, id: musicID) }),
            (.setTitle("Demo"), doc, { _ in InfoCommands.setTitle(doc, "Demo") }),
            (.setSummary("Resumen"), doc, { _ in InfoCommands.setSummary(doc, "Resumen") }),
        ]
        for (command, document, app) in cases {
            let ids = APIFixtures.IDs()
            let expected = try #require(app { ids.make($0) }, "\(command.name): the app's call made no step")
            let step = try s.step(command, on: document).editStep
            #expect(step == expected, "\(command.name)")
        }
    }
}

@Test func compositeCommandsAreOneStep() async throws {
    try await withTemporaryDirectory { dir in
        let s = try Steps(try await APIFixtures.package(in: dir))
        let doc = s.document
        let map = TimeMap(sequence: doc.sequence)

        // The app's two gestures, one after the other, with ids that count from 1.
        func twoGestures(_ first: (EditDocument, (String) -> String) -> EditStep?, _ second: (EditDocument, EditStep, (String) -> String) -> EditStep?)
            throws -> EditDocument
        {
            let ids = APIFixtures.IDs()
            let make: (String) -> String = { ids.make($0) }
            let one = try unwrap(first(doc, make), "first gesture")
            let after = try doc.applying(one.changes)
            return try applied(second(after, one, make), to: after)
        }

        let cases: [(ProjectCommand, EditLabel, EditDocument)] = [
            (.setSpeed(from: 2, to: 4, speed: 2), .speed, try twoGestures(
                { SequenceCommands.split($0, range: ns(2)..<ns(4), makeID: $1) },
                { after, _, _ in SequenceCommands.setSpeed(after, clipIDs: [after.sequence[1].id], speed: 2, takeBounds: s.bounds) })),
            (.addZoom(from: 2, to: 5, depth: 2, focus: .fixed(x: 0.25, y: 0.4)), .zoomAdd, try twoGestures(
                { ZoomCommands.add($0, output: ns(2)..<ns(5), makeID: $1) },
                { after, add, _ in ZoomCommands.change(after, id: add.target, depth: .some(2), focus: .fixed(x: 0.25, y: 0.4)) })),
            (.addMarker(at: 5, name: "Medio"), .markerAdd, try twoGestures(
                { MarkerCommands.add($0, atOutput: ns(5), timeMap: map, recorded: s.recorded, makeID: $1) },
                { after, add, make in
                    let shown = MarkerList.visible(document: after, recorded: s.recorded, timeMap: TimeMap(sequence: after.sequence))
                    return shown.first { $0.id == add.target }.flatMap { MarkerCommands.rename(after, $0, to: "Medio", makeID: make) }
                })),
            (.addTitleCard(at: .start, title: "Hola", subtitle: "Mundo"), .clipCard, try twoGestures(
                { ContentClipCommands.addCard($0, at: .start, title: "Hola", makeID: $1) },
                { after, add, _ in ContentClipCommands.changeCard(after, clipID: add.target) { $0.subtitle = "Mundo" } })),
            (.addMusic(theme: "calm", volume: -20), .musicAdd, try twoGestures(
                { MusicCommands.add($0, source: MusicThemes.source("calm"), atOutput: 0, timeMap: map, makeID: $1) },
                { after, add, _ in MusicCommands.change(after, id: add.target) { $0.gain = -20 } })),
            (.setCameraLayout(.split, side: .start), .cameraLayout, try twoGestures(
                { document, _ in LayoutCommands.setProjectLayout(document, .split) },
                { after, _, _ in LayoutCommands.setSplit(after, id: nil, side: .start) })),
        ]
        for (command, label, expected) in cases {
            let step = try #require(try s.step(command).editStep, "\(command.name)")
            #expect(step.label == label, "\(command.name)")
            #expect(try doc.applying(step.changes) == expected, "\(command.name)")
        }
        // The speed's step is the clips' it changes: the middle one, at 2×.
        let speed = try applied(try s.step(.setSpeed(from: 2, to: 4, speed: 2)).editStep, to: doc)
        #expect(speed.sequence.map(\.speed) == [1, 2, 1])
        #expect(abs(TimeMap(sequence: speed.sequence).durationSeconds - (map.durationSeconds - 1)) < 0.001)
    }
}

@Test func outOfRangeTimes() async throws {
    try await withTemporaryDirectory { dir in
        let s = try Steps(try await APIFixtures.package(in: dir))
        let commands: [ProjectCommand] = [
            .cut(from: -1, to: 2), .cut(from: 1, to: 11), .cut(from: 2, to: 2), .cut(from: 3, to: 2), .cut(from: .nan, to: 2),
            .cut(from: 1, to: .infinity), .trimStart(to: 0), .trimStart(to: 12), .trimEnd(from: 10.5), .trimEnd(from: -0.1),
            .setSpeed(from: 1, to: 2, speed: 32), .setSpeed(from: 1, to: 2, speed: 0.1), .setSpeed(from: 1, to: 2, speed: .nan),
            .shortenPauses(longerThan: 0), .shortenPauses(longerThan: -1), .addZoom(from: 1, to: 3, depth: 9, focus: nil),
            .addZoom(from: 1, to: 3, depth: nil, focus: .fixed(x: 1.5, y: 0.5)), .addMarker(at: 10.5, name: ""),
            .addMarker(at: -2, name: ""), .addTitleCard(at: .at(11), title: "x", subtitle: nil),
            .addText(from: 1, to: 2, text: "x", x: 2, y: 0.5), .addText(from: 5, to: 1, text: "x", x: 0.5, y: 0.5),
            .addMusic(theme: "calm", volume: 12),
        ]
        for command in commands {
            #expect(s.error(command)?.code == .outOfRange, "\(command.json)")
        }
        // An unknown theme is not a command of the schema's.
        #expect(s.error(.addMusic(theme: "polka", volume: nil))?.code == .invalidCommand)
    }
}

@Test func unchangedSetterIsNotAnError() async throws {
    try await withTemporaryDirectory { dir in
        let s = try Steps(try await APIFixtures.package(in: dir))
        let doc = s.document
        let commands: [ProjectCommand] = [
            .setAspect(doc.aspect), .setBackground(doc.style.background), .setCameraLayout(doc.camera.layout.kind, side: nil),
            .setAutoZoom(enabled: doc.zoom.auto.enabled, followsFocus: doc.zoom.auto.followsFocus), .setTitle(""), .setSummary("  "),
            .removeMusic,
        ]
        for command in commands {
            #expect(try s.step(command).isUnchanged, "\(command.name)")
        }
        // Named, a title is a change; the same title again is not.
        let titled = try applied(try s.step(.setTitle("Demo")).editStep, to: doc)
        #expect(try s.step(.setTitle("Demo"), on: titled).isUnchanged)
        // The commands that need the session say so.
        if case .needsSession = try s.step(.applyStyle(id: "toma")) {} else { Issue.record("applyStyle") }
        if case .needsSession = try s.step(.setBackground(.image(file: "/tmp/back.png"))) {} else { Issue.record("an outside image") }
        if case .needsSession = try s.step(.transcribe(language: nil, replace: false)) {} else { Issue.record("transcribe") }
    }
}

@Test func refusedSaysWhy() async throws {
    try await withTemporaryDirectory { dir in
        let s = try Steps(try await APIFixtures.package(in: dir))
        // The take recorded a marker at 3 s.
        let marker = try #require(s.error(.addMarker(at: 3, name: "")))
        #expect(marker.code == .refused && marker.message.contains("another marker"))
        let zoom = try #require(s.error(.removeZoom(id: "z-gone")))
        #expect(zoom.code == .refused && zoom.message.contains("z-gone"))
        #expect(s.error(.removeMarker(id: "m-gone"))?.code == .refused)
        let duration = TimeMap(sequence: s.document.sequence).durationSeconds
        let last = try #require(s.error(.cut(from: 0, to: duration)))
        #expect(last.code == .refused && last.message.contains("at least one"))
        let side = try #require(s.error(.setCameraLayout(.bubble, side: .start)))
        #expect(side.code == .refused && side.message.contains("split"))
        #expect(s.error(.setBackground(.image(file: "assets/0123456789abcdef0123456789abcdef.png")))?.code == .refused)
        #expect(s.error(.setBackground(.image(file: "back.png")))?.code == .invalidCommand)
        let blank = try Steps(s.project, transcript: false)
        let fillers = try #require(blank.error(.removeFillers))
        #expect(fillers.code == .refused && fillers.message.contains("transcript"))
        // Music over all of the video: no room for more.
        let music = try applied(try s.step(.addMusic(theme: "calm", volume: nil)).editStep, to: s.document)
        #expect(s.error(.addMusic(theme: "focus", volume: nil), on: music)?.code == .refused)
    }
}

@Test func createdIsTheNewID() async throws {
    try await withTemporaryDirectory { dir in
        let s = try Steps(try await APIFixtures.package(in: dir))
        let doc = s.document
        let zoom = try s.step(.addZoom(from: 2, to: 5, depth: 2, focus: nil))
        let zoomID = try #require(zoom.created)
        #expect(try applied(zoom.editStep, to: doc).zoom.regions.contains { $0.id == zoomID && $0.depth == 2 })
        let marker = try s.step(.addMarker(at: 5, name: "Medio"))
        let markerID = try #require(marker.created)
        #expect(try applied(marker.editStep, to: doc).markers.items.contains { $0.id == markerID && $0.name == "Medio" })
        let card = try s.step(.addTitleCard(at: .end, title: "Fin", subtitle: nil))
        let cardID = try #require(card.created)
        #expect(try applied(card.editStep, to: doc).sequence.last?.id == cardID)
        let text = try s.step(.addText(from: 1, to: 3, text: "Hola", x: 0.5, y: 0.5))
        let textID = try #require(text.created)
        #expect(try applied(text.editStep, to: doc).annotations.items.contains { $0.id == textID })
        let music = try s.step(.addMusic(theme: "piano", volume: nil))
        let musicID = try #require(music.created)
        #expect(try applied(music.editStep, to: doc).music.items.map(\.id) == [musicID])
        // What makes nothing new has no id.
        #expect(try s.step(.cut(from: 1, to: 2)).created == nil)
        #expect(try s.step(.setTitle("Demo")).created == nil)
    }
}

/// A 32 × 32 PNG.
private func png() throws -> Data {
    guard let context = CGContext(
        data: nil, width: 32, height: 32, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue),
        context.makeImage() != nil
    else { throw TestSupportError.failed("no context") }
    context.setFillColor(CGColor(red: 0.8, green: 0.3, blue: 0.5, alpha: 1))
    context.fill(CGRect(x: 0, y: 0, width: 32, height: 32))
    let data = NSMutableData()
    guard let image = context.makeImage(),
        let destination = CGImageDestinationCreateWithData(data as CFMutableData, "public.png" as CFString, 1, nil)
    else { throw TestSupportError.failed("no image") }
    CGImageDestinationAddImage(destination, image, nil)
    guard CGImageDestinationFinalize(destination) else { throw TestSupportError.failed("no PNG") }
    return data as Data
}

@MainActor @Test func sessionCommandsAreTheApps() async throws {
    try await withTemporaryDirectory { dir in
        let environment = APIFixtures.environment(in: dir)
        let url = try await APIFixtures.transcribed(in: dir, environment: environment)
        let project = try await TomaProject.open(url, mode: .edit, environment: environment)
        // A look of its own first, so Toma's style changes it.
        _ = try await project.apply(.setBackground(.color(RGBA(0, 0, 0, 1))))
        let toma = try await project.apply(.applyStyle(id: "toma"))
        #expect(toma.changed && toma.label == "style.apply")
        #expect(project.document.style.background == DefaultStyle.toma.style.background)
        #expect(try await !project.apply(.applyStyle(id: "toma")).changed)
        #expect(await APIFixtures.apiError { _ = try await project.apply(.applyStyle(id: "0badf00d")) }?.code == .refused)

        // An image from outside comes into `assets/` and is the background, in one step.
        let image = dir.appending(path: "Back.png")
        try png().write(to: image)
        let set = try await project.apply(.setBackground(.image(file: image.path)))
        #expect(set.changed && set.label == "style.background")
        guard case let .image(file) = project.document.style.background else {
            Issue.record("the background is \(project.document.style.background)")
            return
        }
        #expect(DocumentRules.isAssetPath(file, as: .asset))
        #expect(FileManager.default.fileExists(atPath: url.appending(path: file).path))
        #expect(try await project.undo().label == "style.background")
        #expect(project.document.style.background == DefaultStyle.toma.style.background)
        let notAnImage = dir.appending(path: "Notes.png")
        try Data("not an image".utf8).write(to: notAnImage)
        #expect(await APIFixtures.apiError { _ = try await project.apply(.setBackground(.image(file: notAnImage.path))) }?.code == .refused)

        // Transcribing comes with Task A2.
        #expect(await APIFixtures.apiError { _ = try await project.apply(.transcribe(language: nil, replace: false)) }?.code == .notAvailable)
        await project.close()
    }
}
