// SPDX-License-Identifier: GPL-3.0-or-later
import Analysis
@testable import Export
import Foundation
import ProjectFormat
import RecorderKitTestSupport
@testable import Render
import Testing

// The files for external editors (phases 4 and 5 design §7.2, plan 4c task X2): next to an exported video, an FCPXML 1.11
// with the video as one clip and the markers, the clicks and the zoom blocks as Final Cut's markers, every time on the
// video's frames; and `metadata-1`, a JSON of what each frame draws (the cursor, the zoom camera) in the video's pixels,
// with the clicks, the zoom blocks, the markers, the chapters and the kept source ranges, all in output time.

private func at(_ seconds: Double) -> HostTime { base.adding(seconds: seconds) }

/// The export the tests write the files for: H.264 at 320 × 180 and 30 fps.
private let settings = ExportSettings(outputSize: [320, 180], framesPerSecond: 30)

/// Cursor samples every 1/120 s for 4 s, going back and forth across display 1 and down it.
private func cursorEvents() -> [InputEvent] {
    (0..<480).map { i in
        let phase = Double(i % 120) / 120
        let x = 40 + 560 * (phase < 0.5 ? 2 * phase : 2 - 2 * phase)
        return InputEvent(t: at(Double(i) / 120), kind: .cursor(x: x, y: 60 + 60 * Double(i) / 120))
    }
}

/// A take of 4 s in `dir/<name>.toma`: display 1 (640 × 360) and, with `microphone`, the microphone; the cursor moving,
/// a click at 0.8 s and one at 2.8 s, a recorded marker at 0.5 s and one at 1.7 s.
private func take(in dir: URL, name: String = "Demo", microphone: Bool = true) async throws -> LoadedProject {
    let builder = try TakeBuilder(in: dir, name: name)
    try await builder.addVideoTrack(id: displayID, source: displaySource, segments: [VideoSegmentSpec(start: base, seconds: 4)])
    if microphone {
        try await builder.addAudioTrack(id: micID, source: micSource, segments: [AudioSegmentSpec(start: base, seconds: 4)])
    }
    try builder.addEvents(cursorEvents())
    try builder.addEvents([
        InputEvent(t: at(0.8), kind: .mouseDown(.left, x: 200, y: 100)), InputEvent(t: at(0.9), kind: .mouseUp(.left, x: 200, y: 100)),
        InputEvent(t: at(2.8), kind: .mouseDown(.left, x: 400, y: 200)), InputEvent(t: at(2.9), kind: .mouseUp(.left, x: 400, y: 200)),
        InputEvent(t: at(0.5), kind: .marker), InputEvent(t: at(1.7), kind: .marker),
    ])
    return try builder.write()
}

/// The edit of `take`: its source `[0, 1.5)` and `[2, 4)` (a cut of 0.5 s), a zoom of the user of depth 2 over the source
/// `[1.2, 2.4)` (across the cut: `[1.2, 1.9)` of the output, frames 36 to 57), and a marker added at 3 s, "Intro & <fin>"
/// (2.5 s of output, frame 75). 3.5 s of output: 105 frames at 30 fps.
private func edit(of project: LoadedProject) -> EditDocument {
    var document = EditDocument.legacy(for: project)
    document.sequence = [
        Clip(id: "c-00000001", take: takeID, start: at(0), end: at(1.5), speed: 1),
        Clip(id: "c-00000002", take: takeID, start: at(2), end: at(4), speed: 1),
    ]
    document.zoom.regions = [
        ZoomRegion(id: "z-00000001", take: takeID, start: at(1.2), end: at(2.4), origin: .user, depth: 2, focus: .follow, instant: false),
    ]
    document.markers.items = [Marker(id: "m-00000001", take: takeID, t: at(3), name: "Intro & <fin>", origin: .added)]
    return document
}

/// The frames of the export of `edit`.
private let frameCount = 105

/// `metadata-1` as the tests read it.
private struct Metadata: Decodable {
    struct Video: Decodable {
        var file: String
        var width: Int
        var height: Int
        var frameRate: Int
        var frames: Int
        var duration: Double
        var alpha: Bool
    }

    struct Cut: Decodable {
        var take: String
        var sourceStart: UInt64
        var sourceEnd: UInt64
        var start: Double
        var end: Double
        var speed: Double
        var content: String?
    }

    struct Mark: Decodable {
        var id: String
        var name: String
        var time: Double
        var frame: Int
    }

    struct Chapter: Decodable {
        var title: String
        var time: Double
        var frame: Int
    }

    struct Click: Decodable {
        var time: Double
        var frame: Int
        var x: Double?
        var y: Double?
    }

    struct ZoomBlock: Decodable {
        var id: String
        var start: Double
        var end: Double
        var startFrame: Int
        var endFrame: Int
        var depth: Double
        var mode: String
        var origin: String
    }

    struct Cursor: Decodable {
        var x: Double
        var y: Double
        var visible: Bool
        var pressed: Bool
    }

    struct Zoom: Decodable {
        var depth: Double
        var x: Double
        var y: Double
    }

    struct Frame: Decodable {
        var cursor: Cursor?
        var zoom: Zoom
    }

    var format: String
    var video: Video
    var cuts: [Cut]
    var markers: [Mark]
    var chapters: [Chapter]
    var clicks: [Click]
    var zoomBlocks: [ZoomBlock]
    var frames: [Frame]
}

/// The two files as a test reads them.
private struct Files: Sendable {
    var fcpxml: Data
    var metadata: Data

    var xml: XMLDocument {
        get throws { try XMLDocument(data: fcpxml, options: []) }
    }

    var json: Metadata {
        get throws { try JSONDecoder().decode(Metadata.self, from: metadata) }
    }
}

/// What an exported fixture is: the project, its edit, the video and the two files written next to it.
private struct Exported: Sendable {
    var project: LoadedProject
    var document: EditDocument
    var video: URL
    var files: Files
}

/// Exports `edit` of `take` (changed by `change`) with `settings` to `dir/out.mp4`, writes the two files next to it with
/// `ExternalEditorExport.write` (off the cooperative pool: it waits for the video's tracks to load), and reads them.
private func exported(
    in dir: URL, microphone: Bool = true, change: (inout EditDocument) -> Void = { _ in }
) async throws -> Exported {
    let project = try await take(in: dir, microphone: microphone)
    var document = edit(of: project)
    change(&document)
    let video = dir.appending(path: "out.mp4")
    try await MP4Exporter(project: project, document: document, settings: settings).export(to: video) { _ in }
    let (fcpxml, metadata) = ExternalEditorExport.sidecarURLs(of: video)
    try await offThePool { [document] in
        try ExternalEditorExport.write(
            project: project, document: document, video: video, settings: settings, fcpxml: fcpxml, metadata: metadata)
    }
    return Exported(
        project: project, document: document, video: video,
        files: Files(fcpxml: try Data(contentsOf: fcpxml), metadata: try Data(contentsOf: metadata)))
}

/// The files of `document` of `project` for a video `facts` describes, without one: `ExternalEditorExport.files`.
private func files(
    _ project: LoadedProject, _ document: EditDocument, facts: VideoFacts, settings: ExportSettings = settings
) throws -> Files {
    let files = try ExternalEditorExport.files(project: project, document: document, video: facts, settings: settings)
    return Files(fcpxml: files.fcpxml, metadata: files.metadata)
}

/// What `ExternalEditorExport.files` is given for the export of `document` at `fps` to `dir/name`, which is not read.
private func facts(
    of document: EditDocument, in dir: URL, name: String = "out.mp4", fps: Int = 30, audioChannels: Int? = 1
) -> VideoFacts {
    VideoFacts(
        url: dir.appending(path: name), size: settings.outputSize, frameRate: fps,
        frameCount: TimeMap(sequence: document.sequence).frameCount(frameRate: fps), audioChannels: audioChannels,
        hasAlpha: false)
}

/// The elements of `xml` that `path` names.
private func elements(_ xml: XMLDocument, _ path: String) throws -> [XMLElement] {
    try xml.nodes(forXPath: path).compactMap { $0 as? XMLElement }
}

/// The attribute `name` of `element`.
private func attribute(_ element: XMLElement, _ name: String) -> String? {
    element.attribute(forName: name)?.stringValue
}

/// The frame a time of the FCPXML is at `fps`: `"0s"` is 0, `"<n>/<fps>s"` is n; anything else is `nil`.
private func frame(of time: String, fps: Int) -> Int? {
    if time == "0s" { return 0 }
    guard time.hasSuffix("/\(fps)s"), let n = Int(time.dropLast("/\(fps)s".count)), n > 0 else { return nil }
    return n
}

/// The markers and chapter markers of the clip, in their order: their kind, start and duration in frames, and value.
private func markers(_ xml: XMLDocument, fps: Int = 30) throws -> [(kind: String, start: Int, duration: Int, value: String)] {
    try elements(xml, "//asset-clip/*").map { element in
        let start = try #require(attribute(element, "start").flatMap { frame(of: $0, fps: fps) })
        let duration = try #require(attribute(element, "duration").flatMap { frame(of: $0, fps: fps) })
        return (element.name ?? "", start, duration, attribute(element, "value") ?? "")
    }
}

/// The drawn point of `stage` point `p` in a frame of `settings`' size, through `frame`'s transform.
private func drawn(_ p: SIMD2<Double>, in frame: RenderFrame) -> SIMD2<Double> {
    let transform = frame.card?.content ?? frame.stage ?? .identity(outputSize: settings.outputSize)
    return transform.outputPoint(ofStage: p, outputSize: settings.outputSize)
}

/// Whether `error` is `ExportError.writerFailed`.
private func isWriterFailed(_ error: (any Error)?) -> Bool {
    if case .writerFailed? = error as? ExportError { return true }
    return false
}

@Suite struct ExternalEditorExportTests {
    // MARK: - FCPXML

    /// `XMLDocument` parses it and it follows the DTD of the elements it uses (FCPXML 1.11's, `FCPXMLDTD`), version 1.11.
    @Test(.enabled(if: MetalCondition.isAvailable || MetalCondition.isRequired))
    func fcpxmlParsesAndFollowsTheDTD() async throws {
        try await withTemporaryDirectory { dir in
            let xml = try await exported(in: dir).files.xml
            let dtd = try XMLDTD(data: Data(FCPXMLDTD.source.utf8), options: [])
            dtd.name = "fcpxml"
            xml.dtd = dtd
            try xml.validate()
            #expect(xml.rootElement()?.name == "fcpxml")
            #expect(xml.rootElement().flatMap { attribute($0, "version") } == ExternalEditorExport.fcpxmlVersion)
            #expect(ExternalEditorExport.fcpxmlVersion == "1.11")
            #expect(try elements(xml, "//asset-clip").count == 1)
        }
    }

    /// Every `offset`, `start`, `duration` and `tcStart` is `"0s"` or `"<n>/30s"` with `n` a whole number, and what starts
    /// and lasts in the clip ends by its last frame.
    @Test(.enabled(if: MetalCondition.isAvailable || MetalCondition.isRequired))
    func everyTimeIsAFrame() async throws {
        try await withTemporaryDirectory { dir in
            let xml = try await exported(in: dir).files.xml
            var times = 0
            for element in try elements(xml, "//*") {
                for name in ["offset", "start", "duration", "tcStart"] {
                    guard let time = attribute(element, name) else { continue }
                    times += 1
                    #expect(frame(of: time, fps: 30) != nil, "\(element.name ?? "") \(name)=\(time)")
                }
                if let start = attribute(element, "start").flatMap({ frame(of: $0, fps: 30) }),
                   let duration = attribute(element, "duration").flatMap({ frame(of: $0, fps: 30) })
                {
                    #expect(start + duration <= frameCount, "\(element.name ?? "") \(start) + \(duration)")
                }
            }
            #expect(times > 10)
            #expect(try elements(xml, "//format").first.flatMap { attribute($0, "frameDuration") } == "1/30s")
            #expect(FCPXMLWriter.time(frame: 0, frameRate: 30) == "0s")
            #expect(FCPXMLWriter.time(frame: 36, frameRate: 30) == "36/30s")
        }
    }

    /// A chapter marker per marker the output shows (`MarkerList.visible`: the one recorded in the cut is not), on its
    /// frame, a frame long; the one without a name says "Marker".
    @Test(.enabled(if: MetalCondition.isAvailable || MetalCondition.isRequired))
    func markersAreTheVisibleOnes() async throws {
        try await withTemporaryDirectory { dir in
            let fixture = try await exported(in: dir)
            let recorded = [takeID: MarkerList.recordedInstants(in: fixture.project.events)]
            let visible = MarkerList.visible(
                document: fixture.document, recorded: recorded, timeMap: TimeMap(sequence: fixture.document.sequence))
            #expect(visible.count == 2)
            let chapters = try markers(fixture.files.xml).filter { $0.kind == "chapter-marker" }
            #expect(chapters.map(\.start) == visible.map { Int((Double($0.output) * 30 / 1e9).rounded()) })
            #expect(chapters.map(\.start) == [15, 75])
            #expect(chapters.map(\.duration) == [1, 1])
            #expect(chapters.map(\.value) == ["Marker", "Intro & <fin>"])

            let json = try fixture.files.json
            #expect(json.markers.map(\.frame) == [15, 75])
            #expect(json.markers.map(\.name) == ["", "Intro & <fin>"])
            #expect(json.markers.map(\.id) == visible.map(\.id))
            #expect(json.markers.map(\.time) == [0.5, 2.5])
        }
    }

    /// Two "Click" markers a frame long, on the clicks' frames; a "Zoom 2.0×" marker that starts and lasts what the block
    /// does in the output, the cut closed (`[1.2, 1.9)` s: frames 36 to 57). All the clip's markers in order of start.
    @Test(.enabled(if: MetalCondition.isAvailable || MetalCondition.isRequired))
    func clicksAndZoomsAreMarkers() async throws {
        try await withTemporaryDirectory { dir in
            let all = try markers(try await exported(in: dir).files.xml)
            let plain = all.filter { $0.kind == "marker" }
            #expect(plain.filter { $0.value == "Click" }.map { [$0.start, $0.duration] } == [[24, 1], [69, 1]])
            #expect(plain.filter { $0.value == "Zoom 2.0×" }.map { [$0.start, $0.duration] } == [[36, 21]])
            #expect(plain.count == 3)
            #expect(all.map(\.start) == [15, 24, 36, 69, 75])
        }
    }

    /// The names come back as they were, `& < > " '` and all (a line break too), through `XMLDocument`: the marker's, the
    /// event's (the project's package) and the video's; a control character is left out.
    @Test func namesAreEscaped() async throws {
        try await withTemporaryDirectory { dir in
            let project = try await take(in: dir, name: "R&D <\"1\">")
            var document = edit(of: project)
            document.markers.items.append(
                Marker(id: "m-00000002", take: takeID, t: at(3.5), name: "Say \"hi\" & <b>'s\u{7}\nnext", origin: .added))
            let xml = try files(project, document, facts: facts(of: document, in: dir, name: "a & b <'c'>.mp4")).xml
            let values = try elements(xml, "//chapter-marker").compactMap { attribute($0, "value") }
            #expect(values == ["Marker", "Intro & <fin>", "Say \"hi\" & <b>'s\nnext"])
            #expect(try elements(xml, "//event").first.flatMap { attribute($0, "name") } == "R&D <\"1\">")
            #expect(try elements(xml, "//project").first.flatMap { attribute($0, "name") } == "a & b <'c'>")
            #expect(try elements(xml, "//asset").first.flatMap { attribute($0, "name") } == "a & b <'c'>")
            #expect(FCPXMLWriter.escaped("a\u{1}b\u{1F}c\u{7F}\td\r\ne") == "abc\u{7F}&#9;d&#10;e")
            #expect(FCPXMLWriter.escaped("& < > \" '") == "&amp; &lt; &gt; &quot; &apos;")
        }
    }

    /// The asset is the exported video: `media-rep@src` is its URL, it lasts its 105 frames, with the microphone's one
    /// channel at 48 kHz (a mono sequence); without the microphone, no audio attributes at all.
    @Test(.enabled(if: MetalCondition.isAvailable || MetalCondition.isRequired))
    func fcpxmlNamesTheVideo() async throws {
        try await withTemporaryDirectory { dir in
            let fixture = try await exported(in: dir)
            let xml = try fixture.files.xml
            let asset = try #require(try elements(xml, "//asset").first)
            #expect(try elements(xml, "//media-rep").first.flatMap { attribute($0, "src") } == fixture.video.absoluteString)
            #expect(attribute(asset, "duration") == "105/30s")
            #expect(attribute(asset, "name") == "out")
            #expect(attribute(asset, "hasVideo") == "1")
            #expect(attribute(asset, "hasAudio") == "1")
            #expect(attribute(asset, "audioChannels") == "1")
            #expect(attribute(asset, "audioRate") == "48000")
            #expect(try elements(xml, "//sequence").first.flatMap { attribute($0, "audioLayout") } == "mono")
            #expect(try elements(xml, "//sequence").first.flatMap { attribute($0, "duration") } == "105/30s")
            #expect(try elements(xml, "//asset-clip").first.flatMap { attribute($0, "duration") } == "105/30s")
            #expect(try elements(xml, "//event").first.flatMap { attribute($0, "name") } == "Demo")
            #expect(try elements(xml, "//project").first.flatMap { attribute($0, "name") } == "out")
        }
        try await withTemporaryDirectory { dir in
            let asset = try #require(try elements(try await exported(in: dir, microphone: false).files.xml, "//asset").first)
            for name in ["hasAudio", "audioSources", "audioChannels", "audioRate"] {
                #expect(attribute(asset, name) == nil, "\(name)")
            }
            #expect(attribute(asset, "hasVideo") == "1")
        }
    }

    /// The labels are in the language of the chapters (`ExportSettings.chapterLanguage`, controller ruling): Spanish for
    /// `es` ("Clic", "Zoom 2,0×", "Marcador"), English otherwise; the modes' names too.
    @Test func labelsFollowTheChapterLanguage() async throws {
        try await withTemporaryDirectory { dir in
            let project = try await take(in: dir)
            var document = edit(of: project)
            document.zoom.regions.append(
                ZoomRegion(id: "z-00000002", take: takeID, start: at(0.1), end: at(0.4), origin: .user, depth: 1.5, focus: .follow,
                           instant: false, mode: .dim))
            for (language, expected) in [
                ("es", ["Lupa 3,0×", "Atenuar 1,5×", "Marcador", "Clic", "Zoom 2,0×", "Clic", "Intro & <fin>"]),
                ("es-419", ["Atenuar 1,5×", "Marcador", "Clic", "Zoom 2,0×", "Clic", "Intro & <fin>"]),
                ("en", ["Dim 1.5×", "Marker", "Click", "Zoom 2.0×", "Click", "Intro & <fin>"]),
                (nil, ["Dim 1.5×", "Marker", "Click", "Zoom 2.0×", "Click", "Intro & <fin>"]),
            ] as [(String?, [String])] {
                var spanish = settings
                spanish.chapterLanguage = language
                var shown = document
                if language == "es" {
                    shown.zoom.regions.append(
                        ZoomRegion(id: "z-00000003", take: takeID, start: at(0), end: at(0.1), origin: .user, depth: 3,
                                   focus: .follow, instant: false, mode: .loupe))
                }
                let values = try markers(try files(project, shown, facts: facts(of: shown, in: dir), settings: spanish).xml)
                    .map(\.value)
                #expect(values == expected, "\(language ?? "nil")")
            }
        }
    }

    // MARK: - metadata-1

    /// A frame per frame of the video, and the video as it is: 320 × 180, 30 fps, 105 frames, 3.5 s, no alpha.
    @Test(.enabled(if: MetalCondition.isAvailable || MetalCondition.isRequired))
    func metadataHasAFramePerVideoFrame() async throws {
        try await withTemporaryDirectory { dir in
            let fixture = try await exported(in: dir)
            let json = try fixture.files.json
            #expect(json.format == ExternalEditorExport.metadataID)
            #expect(ExternalEditorExport.metadataID == "metadata-1")
            #expect(json.frames.count == frameCount)
            #expect(json.video.file == "out.mp4")
            #expect([json.video.width, json.video.height, json.video.frameRate, json.video.frames] as [Int] == [320, 180, 30, frameCount])
            #expect(json.video.duration == 3.5)
            #expect(json.video.alpha == false)
            #expect(json.chapters.isEmpty)
            // Compact, with its keys sorted, and the slashes of a path as they are.
            let text = try #require(String(data: fixture.files.metadata, encoding: .utf8))
            #expect(text.hasPrefix("{\"chapters\":[],\"clicks\":["))
            #expect(!text.contains("\n"))
        }
    }

    /// In three frames, the cursor is the frame's hotspot drawn through its zoom (±0.01 px), pressed while the button is
    /// down; inside the zoom block the depth is above 1, before it 1.
    @Test(.enabled(if: MetalCondition.isAvailable || MetalCondition.isRequired))
    func cursorIsWhereTheFrameDrawsIt() async throws {
        try await withTemporaryDirectory { dir in
            let fixture = try await exported(in: dir)
            let json = try fixture.files.json
            let readable = LayoutTimeline.cameraReadable(take: fixture.project.take) {
                SegmentAvailability.classify($0, in: fixture.project.package)
            }
            let scene = FrameEvaluator(
                project: fixture.project, document: fixture.document, outputSize: settings.outputSize, frameRate: 30,
                cameraReadable: [takeID: readable])
            for n in [10, 25, 50] {
                let frame = scene.frame(at: Double(TimeMap.frameTime(n, frameRate: 30)) / 1e9) { _ in true }
                let layer = try #require(frame.cursor)
                let expected = drawn(layer.hotspot, in: frame)
                let cursor = try #require(json.frames[n].cursor)
                #expect(abs(cursor.x - expected.x) <= 0.01 && abs(cursor.y - expected.y) <= 0.01, "frame \(n): \(cursor) \(expected)")
                #expect(cursor.visible)
                let transform = frame.card?.content ?? frame.stage ?? .identity(outputSize: settings.outputSize)
                #expect(abs(json.frames[n].zoom.depth - transform.depth) <= 0.01)
                #expect(abs(json.frames[n].zoom.x - transform.center.x) <= 0.01)
                #expect(abs(json.frames[n].zoom.y - transform.center.y) <= 0.01)
            }
            #expect(json.frames[25].cursor?.pressed == true)
            #expect(json.frames[10].cursor?.pressed == false)
            #expect(json.frames[50].zoom.depth > 1)
            #expect(json.frames[5].zoom.depth == 1)
            #expect(json.frames[5].zoom.x == 160 && json.frames[5].zoom.y == 90)
        }
    }

    /// The clicks are at their output times (the one after the cut 0.5 s before its source time), on the frame of that
    /// instant, where that frame draws the cursor.
    @Test(.enabled(if: MetalCondition.isAvailable || MetalCondition.isRequired))
    func clicksAreInOutputTimeAndPixels() async throws {
        try await withTemporaryDirectory { dir in
            let json = try await exported(in: dir).files.json
            #expect(json.clicks.map(\.time) == [0.8, 2.3])
            #expect(json.clicks.map(\.frame) == [24, 69])
            for click in json.clicks {
                let cursor = try #require(json.frames[click.frame].cursor)
                #expect(click.x == cursor.x && click.y == cursor.y)
            }
        }
    }

    /// Two kept ranges, with their sources in ns of host time, one after the other in the output.
    @Test(.enabled(if: MetalCondition.isAvailable || MetalCondition.isRequired))
    func cutsAreTheKeptSourceRanges() async throws {
        try await withTemporaryDirectory { dir in
            let fixture = try await exported(in: dir)
            let json = try fixture.files.json
            #expect(json.cuts.map(\.take) == [takeID, takeID])
            #expect(json.cuts.map(\.sourceStart) == [at(0).nanoseconds, at(2).nanoseconds])
            #expect(json.cuts.map(\.sourceEnd) == [at(1.5).nanoseconds, at(4).nanoseconds])
            #expect(json.cuts.map(\.start) == [0, 1.5])
            #expect(json.cuts.map(\.end) == [1.5, 3.5])
            #expect(json.cuts.map(\.speed) == [1, 1])
            #expect(json.cuts.map(\.content) == [nil, nil])
            let text = try #require(String(data: fixture.files.metadata, encoding: .utf8))
            #expect(text.contains("\"content\":null"))
        }
    }

    /// The zoom blocks are the document's: none with `zoom.show` off (and no zoom marker in the FCPXML); an automatic one
    /// without a depth of its own has `auto.depth`, and its mode is `auto.mode`; one in a cut is not there.
    @Test func zoomBlocksFollowTheDocument() async throws {
        try await withTemporaryDirectory { dir in
            let project = try await take(in: dir)
            var document = edit(of: project)
            document.zoom.auto.depth = 1.75
            document.zoom.auto.mode = .highlight
            document.zoom.regions += [
                ZoomRegion(id: "z-00000002", take: takeID, start: at(2.5), end: at(3), origin: .auto, focus: .follow, instant: false),
                ZoomRegion(id: "z-00000003", take: takeID, start: at(1.6), end: at(1.9), origin: .user, depth: 3, focus: .follow, instant: false),
            ]
            let shown = try files(project, document, facts: facts(of: document, in: dir))
            let json = try shown.json
            #expect(json.zoomBlocks.map(\.id) == ["z-00000001", "z-00000002"])
            #expect(json.zoomBlocks.map(\.depth) == [2, 1.75])
            #expect(json.zoomBlocks.map(\.mode) == ["classic", "highlight"])
            #expect(json.zoomBlocks.map(\.origin) == ["user", "auto"])
            #expect(json.zoomBlocks.map(\.startFrame) == [36, 60])
            #expect(json.zoomBlocks.map(\.endFrame) == [57, 75])
            #expect(json.zoomBlocks.map(\.start) == [1.2, 2])
            #expect(json.zoomBlocks.map(\.end) == [1.9, 2.5])
            #expect(try markers(shown.xml).map(\.value).contains("Highlight 1.8×"))

            document.zoom.show = false
            let hidden = try files(project, document, facts: facts(of: document, in: dir))
            #expect(try hidden.json.zoomBlocks.isEmpty)
            #expect(try markers(hidden.xml).allSatisfy { !$0.value.contains("×") })
            #expect(try hidden.json.frames.allSatisfy { $0.zoom.depth == 1 })
        }
    }

    // MARK: - What is refused

    /// The video of a range of the output is not the whole export: `writerFailed`, and neither file is written.
    @Test(.enabled(if: MetalCondition.isAvailable || MetalCondition.isRequired))
    func aRangeVideoIsRefused() async throws {
        try await withTemporaryDirectory { dir in
            let project = try await take(in: dir)
            let document = edit(of: project)
            let video = dir.appending(path: "range.mp4")
            try await MP4Exporter(project: project, document: document, settings: settings, range: ExportRange(start: 0, end: 2_000_000_000))
                .export(to: video) { _ in }
            let (fcpxml, metadata) = ExternalEditorExport.sidecarURLs(of: video)
            let error = await #expect(throws: ExportError.self) {
                try await offThePool {
                    try ExternalEditorExport.write(
                        project: project, document: document, video: video, settings: settings, fcpxml: fcpxml, metadata: metadata)
                }
            }
            #expect(isWriterFailed(error), "\(String(describing: error))")
            #expect(!FileManager.default.fileExists(atPath: fcpxml.path))
            #expect(!FileManager.default.fileExists(atPath: metadata.path))
            // Another size, or another frame rate, is not it either.
            for other in [ExportSettings(outputSize: [640, 360], framesPerSecond: 30), ExportSettings(outputSize: [320, 180], framesPerSecond: 60)] {
                var facts = facts(of: document, in: dir, fps: other.framesPerSecond)
                facts.size = settings.outputSize
                facts.frameRate = 30
                #expect(throws: ExportError.self) { try files(project, document, facts: facts, settings: other) }
            }
            var empty = document
            empty.sequence = []
            #expect(throws: ExportError.nothingToExport) { try files(project, empty, facts: facts(of: document, in: dir)) }
            // A file that is not a movie cannot be read: nothing is written either.
            let notAMovie = dir.appending(path: "not.mp4")
            try Data("not a movie".utf8).write(to: notAMovie)
            let unread = await #expect(throws: ExportError.self) {
                try await offThePool {
                    try ExternalEditorExport.write(
                        project: project, document: document, video: notAMovie, settings: settings, fcpxml: fcpxml, metadata: metadata)
                }
            }
            #expect(isWriterFailed(unread), "\(String(describing: unread))")
            #expect(!FileManager.default.fileExists(atPath: fcpxml.path))
        }
    }

    /// Sampling the frames stops once `isCancelled` says so: `cancelled`.
    @Test func cancellingStopsBetweenFrames() async throws {
        try await withTemporaryDirectory { dir in
            let project = try await take(in: dir)
            let document = edit(of: project)
            #expect(throws: ExportError.cancelled) {
                try ExternalEditorExport.files(
                    project: project, document: document, video: facts(of: document, in: dir), settings: settings) { true }
            }
        }
    }

    /// A file inside a `.toma` package (the project's or any other) is `destinationNotAllowed`, before anything is read.
    @Test func pathsInsideAPackageAreRefused() async throws {
        try await withTemporaryDirectory { dir in
            let project = try await take(in: dir)
            let document = edit(of: project)
            let other = dir.appending(path: "Other.toma")
            try FileManager.default.createDirectory(at: other, withIntermediateDirectories: true)
            let video = dir.appending(path: "missing.mp4")
            let outside = ExternalEditorExport.sidecarURLs(of: video)
            for (fcpxml, metadata) in [
                (project.package.url.appending(path: "out.fcpxml"), outside.metadata),
                (outside.fcpxml, other.appending(path: "out.toma-metadata.json")),
                (outside.fcpxml, outside.fcpxml),
                (video, outside.metadata),
            ] {
                await #expect(throws: ExportError.destinationNotAllowed) {
                    try await offThePool {
                        try ExternalEditorExport.write(
                            project: project, document: document, video: video, settings: settings, fcpxml: fcpxml,
                            metadata: metadata)
                    }
                }
            }
            #expect(try FileManager.default.contentsOfDirectory(atPath: other.path).isEmpty)
        }
    }

    // MARK: - Every time the same

    /// Two writes of the same export give the same bytes; the files sit next to the video.
    @Test(.enabled(if: MetalCondition.isAvailable || MetalCondition.isRequired))
    func writingTwiceGivesTheSameBytes() async throws {
        try await withTemporaryDirectory { dir in
            let fixture = try await exported(in: dir)
            let again = (fcpxml: dir.appending(path: "again.fcpxml"), metadata: dir.appending(path: "again.json"))
            try await offThePool { [fixture] in
                try ExternalEditorExport.write(
                    project: fixture.project, document: fixture.document, video: fixture.video, settings: settings,
                    fcpxml: again.fcpxml, metadata: again.metadata)
            }
            #expect(try Data(contentsOf: again.fcpxml) == fixture.files.fcpxml)
            #expect(try Data(contentsOf: again.metadata) == fixture.files.metadata)
            let sidecars = ExternalEditorExport.sidecarURLs(of: fixture.video)
            #expect(sidecars.fcpxml.lastPathComponent == "out.fcpxml")
            #expect(sidecars.metadata.lastPathComponent == "out.toma-metadata.json")
            #expect(sidecars.fcpxml.deletingLastPathComponent() == fixture.video.deletingLastPathComponent())
        }
    }

    /// At 24, 25, 30, 50 and 60 fps, the format's frame lasts `1/<fps>s`, every time is a frame of that rate, and there is
    /// a frame of the JSON per frame of the video.
    @Test func everyFrameRate() async throws {
        try await withTemporaryDirectory { dir in
            let project = try await take(in: dir)
            let document = edit(of: project)
            for fps in [24, 25, 30, 50, 60] {
                var rate = settings
                rate.framesPerSecond = fps
                let facts = facts(of: document, in: dir, fps: fps)
                let shown = try files(project, document, facts: facts, settings: rate)
                let xml = try shown.xml
                #expect(try elements(xml, "//format").first.flatMap { attribute($0, "frameDuration") } == "1/\(fps)s")
                for element in try elements(xml, "//*") {
                    for name in ["offset", "start", "duration", "tcStart"] {
                        guard let time = attribute(element, name) else { continue }
                        #expect(frame(of: time, fps: fps) != nil, "\(fps) fps: \(element.name ?? "") \(name)=\(time)")
                    }
                }
                #expect(try markers(xml, fps: fps).allSatisfy { $0.start + $0.duration <= facts.frameCount })
                #expect(try shown.json.frames.count == facts.frameCount)
                #expect(try shown.json.video.frameRate == fps)
            }
        }
    }

    // MARK: - Speed

    /// The files of 10 minutes at 60 fps of a synthetic take (1920 × 1080, the cursor at 120 Hz with its spring, a click every
    /// 3 s and a zoom block every 30 s): the time goes to `docs/performance.md`.
    @Test(.enabled(if: ProcessInfo.processInfo.environment["TOMA_BENCH"] == "1"))
    func metadataSpeed() async throws {
        try await withTemporaryDirectory { dir in
            let minutes = 10.0, seconds = minutes * 60
            let builder = try TakeBuilder(in: dir, name: "Long")
            try await builder.addVideoTrack(id: displayID, source: displaySource, segments: [VideoSegmentSpec(start: base, seconds: 1)])
            try builder.addEmptySegment(
                track: displayID, index: 2, start: at(1), end: at(seconds), endReason: .stopped, file: .absent)
            try builder.addEvents((0..<Int(seconds * 120)).map { i in
                let phase = Double(i % 600) / 600
                let x = 40 + 560 * (phase < 0.5 ? 2 * phase : 2 - 2 * phase)
                return InputEvent(t: at(Double(i) / 120), kind: .cursor(x: x, y: 60 + 240 * abs(sin(Double(i) / 900))))
            })
            try builder.addEvents(stride(from: 1.0, to: seconds, by: 3).flatMap { t in
                [InputEvent(t: at(t), kind: .mouseDown(.left, x: 300, y: 150)), InputEvent(t: at(t + 0.1), kind: .mouseUp(.left, x: 300, y: 150))]
            })
            let project = try builder.write()
            var document = EditDocument.legacy(for: project)
            document.sequence = [Clip(id: "c-00000001", take: takeID, start: at(0), end: at(seconds), speed: 1)]
            document.cursor.smoothing = .spring(SpringSpec(damping: 1, response: 0.16))
            document.zoom.regions = stride(from: 5.0, to: seconds, by: 30).enumerated().map { k, t in
                ZoomRegion(
                    id: String(format: "z-%08x", k + 1), take: takeID, start: at(t), end: at(t + 8), origin: .user, depth: 2,
                    focus: .follow, instant: false)
            }
            let hd = ExportSettings(outputSize: [1920, 1080], framesPerSecond: 60)
            let facts = VideoFacts(
                url: dir.appending(path: "long.mp4"), size: hd.outputSize, frameRate: 60,
                frameCount: TimeMap(sequence: document.sequence).frameCount(frameRate: 60), audioChannels: 1, hasAlpha: false)
            let clock = ContinuousClock()
            let start = clock.now
            let written = try await offThePool { [document] in
                try ExternalEditorExport.files(project: project, document: document, video: facts, settings: hd)
            }
            let elapsed = clock.now - start
            // Where the time goes: sampling the frames, then each file.
            let parts = try await offThePool { [document] in
                let clock = ContinuousClock()
                let start = clock.now
                let timeline = try EditorTimeline.make(
                    project: project, document: document, settings: hd, frameCount: facts.frameCount, isCancelled: { false })
                let sampled = clock.now
                _ = FCPXMLWriter.document(timeline, video: facts, event: "Long", project: "long")
                let fcpxml = clock.now
                _ = try EditorMetadataFile.data(timeline, video: facts)
                return (sampled - start, fcpxml - sampled, clock.now - fcpxml)
            }
            print(
                "metadataSpeed: \(facts.frameCount) frames in \(elapsed) (frames \(parts.0), FCPXML \(parts.1), JSON \(parts.2)); "
                    + "FCPXML \(written.fcpxml.count) B, metadata \(written.metadata.count) B")
            #expect(try JSONDecoder().decode(Metadata.self, from: written.metadata).frames.count == 36_000)
        }
    }
}
