// SPDX-License-Identifier: GPL-3.0-or-later
import AppKit
import Analysis
import AppSupport
import Editing
import ProjectFormat
import QuartzCore

#if DEBUG
/// `TOMA_BENCH_TIMELINE=1 Toma -TomaDumpEditorStructure <package>` (Debug): instead of describing the editor, measures
/// the timeline (design §7.9: an hour with 500 clips and 300 zooms scrolls and scales at the display's rate) and quits.
/// A timeline as wide as a 1440 pt window shows a take of an hour made up here (a screen, a camera, a microphone and the
/// system audio; 500 clips, a tenth of them at 2× and some at 0,5×; 300 zoom blocks, half automatic; 100 camera
/// changes; 40 markers; two spans hatched), and each frame is laid out and committed to the render server
/// (`CATransaction.flush()`) on the main thread: the time each frame takes there is what is printed, for five motions.
/// With `TOMA_BENCH_TIMELINE_SNAPSHOTS=<folder>`, it also writes there a PNG of the editor's own timeline (the package's
/// take) and of the hour's at four scales.
///
/// Then the main thread's work for each move of a drag and for each edit, on the same hour with an event log of a cursor
/// moving at 60 Hz all along (216 000 events, as `bench-preview`'s hour), before and after final review D-I3: a trim of a
/// clip moved 120 times (each move's step applied, and the timeline's content made from it); the overlay's stage points of
/// an edit with a fixed zoom selected; and "Follow the Cursor" of the screen track. "Before" is what each move or edit did
/// until then, made of the same calls: the timeline's pass over the events for its markers and the step applied by the
/// model and the timeline both; `StagePoints` from the events; the planner on the main thread.
@MainActor
enum TimelineBench {
    static var isAsked: Bool { ProcessInfo.processInfo.environment["TOMA_BENCH_TIMELINE"] == "1" }

    /// `editor`: the timeline of the editor's window.
    static func run(editor: NSView) {
        let snapshots = ProcessInfo.processInfo.environment["TOMA_BENCH_TIMELINE_SNAPSHOTS"].map { URL(fileURLWithPath: $0) }
        print("editor timeline: \(Int(editor.frame.width)) × \(Int(editor.frame.height)) pt")
        if let snapshots, let editor = editor.subviews.compactMap({ $0 as? EditorTimelineView }).first ?? editor as? EditorTimelineView {
            snapshot(editor, to: snapshots.appending(path: "timeline-editor.png"))
        }
        let (project, document) = makeProject()
        let view = EditorTimelineView(frame: NSRect(x: 0, y: 0, width: 1440, height: 236))
        let window = NSWindow(contentRect: view.frame, styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = view
        window.orderFrontRegardless()
        let caches = ProjectCaches(root: FileManager.default.temporaryDirectory.appending(path: "toma-timeline-bench"), projectID: "bench")
        view.tracks.thumbnailCaches = [project.take.id: ThumbnailCache(project: project, caches: caches)]
        let markers: MarkerList.Recorded = [project.take.id: MarkerList.recordedInstants(in: project.events)]
        view.show(take: project.take, recorded: markers, document: document, missing: [600...630, 1800...1802])
        for id in ["mic", "system-audio"] { view.setWaveform(WaveformLevels(syntheticWaveform()), take: project.take.id, track: id) }
        view.playhead = 1_234_000_000_000
        view.layoutSubtreeIfNeeded()

        var load = [0.0, 0.0, 0.0]
        getloadavg(&load, 3)
        let width = 1440 - TimelineLayout.headerWidth, duration = Double(TimeMap(sequence: document.sequence).duration) / 1e9
        let fit = TimelineLayout.fitScale(duration: duration, width: width)
        print("timeline bench: \(document.sequence.count) clips, \(document.zoom.regions.count) zooms, "
            + "\(String(format: "%.0f", duration)) s of output in \(Int(width)) pt (fitted: \(String(format: "%.3f", fit)) pt/s); "
            + "load \(String(format: "%.2f %.2f %.2f", load[0], load[1], load[2]))")

        func centered(_ scale: Double) -> (Double, Double) { (scale, duration / 2 * scale - width / 2) }
        let frames = 600
        measure(view, "fitted, everything in sight, scale changing", (0..<frames).map { i in (fit * (1 + Double(i % 2) * 0.001), 0) })
        measure(view, "pinch from fitted to 600 pt/s and back", (0..<frames).map { i in
            let t = 1 - abs(Double(i) / Double(frames / 2) - 1)
            return centered(fit * pow(TimelineLayout.maxPointsPerSecond / fit, t))
        })
        for scale in [fit * 10, 60, 600] {
            measure(view, "scrolling at \(String(format: "%.1f", scale)) pt/s, 40 pt a frame", (0..<frames).map { i in
                (scale, Double(i) * 40)
            })
        }
        var times: [Double] = []
        view.benchLayout(scale: 60, offset: 70_000)
        for i in 0..<frames {
            let start = DispatchTime.now().uptimeNanoseconds
            view.playhead = Int64(70_000 / 60 * 1e9) + Int64(i) * 16_666_667
            CATransaction.flush()
            times.append(Double(DispatchTime.now().uptimeNanoseconds - start) / 1e6)
        }
        report("the playhead alone, every frame", times, layers: view.benchLayerCount)
        paced(view, fit: fit, duration: duration, width: width)
        measureEdits(view, project: project, document: document, markers: markers)

        if let snapshots {
            for (name, scale, offset) in [("fitted", fit, 0.0), ("30", 30.0, 0.0), ("60", 60.0, 69_500.0), ("600", 600.0, 700_000.0)] {
                view.benchLayout(scale: scale, offset: offset)
                view.playhead = Int64((offset + 300) / scale * 1e9)
                CATransaction.flush()
                snapshot(view, to: snapshots.appending(path: "timeline-\(name).png"))
            }
        }
        fflush(stdout)
        exit(0)
    }

    /// The main thread's work for each drag move and edit (final review D-I3), before and after; see the type's notes.
    private static func measureEdits(
        _ view: EditorTimelineView, project: LoadedProject, document: EditDocument, markers: MarkerList.Recorded
    ) {
        print("edits on the hour: \(project.events.count) events, \(document.sequence.count) clips, \(document.zoom.regions.count) zooms")
        func milliseconds(_ body: () -> Void) -> Double {
            let start = DispatchTime.now().uptimeNanoseconds
            body()
            return Double(DispatchTime.now().uptimeNanoseconds - start) / 1e6
        }
        let clip = document.sequence[250]
        let limits = SequenceCommands.trimLimits(document, clipID: clip.id, edge: .end, take: project.take, events: project.events)
        let bounds = TakeTimeline.editableBounds(take: project.take, events: project.events)
        let steps = (1...120).compactMap { k in
            SequenceCommands.trim(
                document, clipID: clip.id, edge: .end, toSource: clip.end.adding(seconds: -Double(k) / 60), limits: limits,
                takeBounds: [project.take.id: bounds.start...bounds.end])
        }
        var before: [Double] = [], after: [Double] = []
        for step in steps {
            before.append(milliseconds {
                // The model's apply for the preview, the timeline's own, and its content with a pass over the events.
                let applied: EditDocument? = try? document.applying(step.changes)
                _ = try? document.applying(step.changes) as EditDocument
                _ = MarkerList.recordedInstants(in: project.events)
                view.setPreview(applied)
                view.layoutSubtreeIfNeeded()
            })
        }
        view.setPreview(nil)
        for step in steps {
            after.append(milliseconds {
                // The model's apply, whose document the timeline shows; its markers read once per take.
                let applied: EditDocument? = try? document.applying(step.changes)
                view.setPreview(applied)
                view.layoutSubtreeIfNeeded()
            })
        }
        view.setPreview(nil)
        let applying = steps.map { step in milliseconds { _ = try? document.applying(step.changes) as EditDocument } }
        times("a trim drag, each move, before", before)
        times("a trim drag, each move, after", after)
        times("  of which the step applied (once a move now, `EditDocument.applying`)", applying)

        let screens = TakeScreens(take: project.take, events: project.events)
        var stageBefore: [Double] = [], stageAfter: [Double] = []
        for _ in 0..<20 {
            stageBefore.append(milliseconds { _ = StagePoints(take: project.take, events: project.events, document: document) })
            stageAfter.append(milliseconds { _ = StagePoints(take: project.take, document: document, screens: screens) })
        }
        times("an edit with a fixed zoom selected, the overlay's stage points, before", stageBefore)
        times("an edit with a fixed zoom selected, the overlay's stage points, after", stageAfter)

        var follow: [Double] = []
        for _ in 0..<5 { follow.append(milliseconds { _ = TrackCommands.followCursor(document, project: project) }) }
        times("Follow the Cursor of the screen track on the main thread, before (after: off it, none)", follow)
    }

    /// The median, the 95th percentile and the largest of `times`, in milliseconds.
    private static func times(_ name: String, _ times: [Double]) {
        let sorted = times.sorted()
        func at(_ p: Double) -> Double { sorted[min(Int(Double(sorted.count) * p), sorted.count - 1)] }
        print("  \(name): \(times.count) times, p50 \(String(format: "%.2f", at(0.5))) ms, p95 \(String(format: "%.2f", at(0.95))) ms, "
            + "max \(String(format: "%.2f", sorted.last ?? 0)) ms")
    }

    private static func measure(_ view: EditorTimelineView, _ name: String, _ steps: [(Double, Double)]) {
        var times: [Double] = []
        var layers = 0
        for (scale, offset) in steps {
            let start = DispatchTime.now().uptimeNanoseconds
            view.benchLayout(scale: scale, offset: offset)
            CATransaction.flush()
            times.append(Double(DispatchTime.now().uptimeNanoseconds - start) / 1e6)
            layers = max(layers, view.benchLayerCount)
        }
        report(name, times, layers: layers)
    }

    /// For 4 s, a pinch from fitted to 600 pt/s and back once a second, a step on each refresh of the display (the view's
    /// display link, as the timeline's own): how many refreshes there were and how many came later than one and a half
    /// periods after the one before.
    private static func paced(_ view: EditorTimelineView, fit: Double, duration: Double, width: Double) {
        var stamps: [CFTimeInterval] = []
        var period = 0.0
        let ticker = BenchTicker { link in
            stamps.append(link.timestamp)
            period = link.duration
            let t = Double(stamps.count % 120) / 60
            let scale = fit * pow(TimelineLayout.maxPointsPerSecond / fit, 1 - abs(t - 1))
            view.benchLayout(scale: scale, offset: duration / 2 * scale - width / 2)
        }
        let link = view.displayLink(target: ticker, selector: #selector(BenchTicker.tick(_:)))
        link.add(to: .main, forMode: .common)
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 4))
        link.invalidate()
        guard stamps.count > 1, period > 0 else {
            print("  paced pinch: the display did not refresh (asleep?)")
            return
        }
        let late = zip(stamps.dropFirst(), stamps).filter { $0 - $1 > period * 1.5 }.count
        print("  paced pinch on the display link: \(stamps.count) refreshes in 4 s at \(String(format: "%.0f", 1 / period)) Hz, "
            + "\(late) more than 1.5 periods after the one before")
    }

    private static func report(_ name: String, _ times: [Double], layers: Int) {
        let sorted = times.sorted()
        func at(_ p: Double) -> Double { sorted[min(Int(Double(sorted.count) * p), sorted.count - 1)] }
        print("  \(name): \(times.count) frames, p50 \(String(format: "%.2f", at(0.5))) ms, p95 \(String(format: "%.2f", at(0.95))) ms, "
            + "max \(String(format: "%.2f", sorted.last ?? 0)) ms, up to \(layers) layers of items")
    }

    private static func snapshot(_ view: EditorTimelineView, to url: URL) {
        let scale = view.window?.backingScaleFactor ?? 2
        let size = view.bounds.size
        guard let layer = view.layer,
            let context = CGContext(
                data: nil, width: Int(size.width * scale), height: Int(size.height * scale), bitsPerComponent: 8, bytesPerRow: 0,
                space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return }
        context.scaleBy(x: scale, y: scale)
        // The layers are drawn top down, as the window shows them.
        context.translateBy(x: 0, y: size.height)
        context.scaleBy(x: 1, y: -1)
        layer.render(in: context)
        guard let image = context.makeImage(),
            let destination = CGImageDestinationCreateWithURL(url as CFURL, "public.png" as CFString, 1, nil)
        else { return }
        CGImageDestinationAddImage(destination, image, nil)
        CGImageDestinationFinalize(destination)
    }

    /// A take of an hour from host 1 s, and its document: 500 clips of 7 s with 0.2 s cut between them, 300 zooms, 100
    /// camera changes and 40 markers, and a cursor moving at 60 Hz all along.
    private static func makeProject() -> (LoadedProject, EditDocument) {
        let second: UInt64 = 1_000_000_000
        func at(_ seconds: Double) -> HostTime { HostTime(nanoseconds: second + UInt64(seconds * 1e9)) }
        func track(_ id: String, _ kind: TrackKind, frame: Rect? = nil) -> TrackRecord {
            TrackRecord(
                id: id, kind: kind, source: TrackSource(name: id == "display-1" ? "Built-in Display" : id, globalFrame: frame),
                segments: [SegmentRecord(
                    index: 1, file: "takes/take-001/\(id)/seg-0001.mov", startHostTime: at(0), endHostTime: at(3600),
                    endReason: .stopped, droppedFrames: 0, heartbeatFrames: 0)])
        }
        let take = TakeRecord(
            id: "take-001", status: .complete, startedAt: Date(), tracks: [
                track("display-1", .display, frame: Rect(x: 0, y: 0, width: 1728, height: 1117)), track("camera", .camera),
                track("mic", .microphone), track("system-audio", .systemAudio),
            ])
        let cursor = (0..<(3600 * 60)).map { i in
            InputEvent(t: at(Double(i) / 60), kind: .cursor(x: 800 + 600 * sin(Double(i) / 97), y: 550 + 400 * cos(Double(i) / 61)))
        }
        let events = ((0..<40).map { InputEvent(t: at(Double($0) * 90 + 45), kind: .marker) } + cursor).sorted { $0.t < $1.t }
        var document = EditDocument.legacy(take: take, events: events)
        func id(_ prefix: String, _ n: Int) -> String { prefix + String(format: "%08x", n) }
        document.sequence = (0..<500).map { i in
            let speed: Double = i % 10 == 3 ? 2 : (i % 25 == 7 ? 0.5 : 1)
            return Clip(id: id("c-", i), take: take.id, start: at(Double(i) * 7.2), end: at(Double(i) * 7.2 + 7), speed: speed)
        }
        document.zoom.regions = (0..<300).map { (j: Int) -> ZoomRegion in
            let start: Double = Double(j) * 12 + 2
            let depth: Double? = j % 3 == 0 ? nil : 1.5 + Double(j % 5) * 0.25
            let origin: Origin = j % 2 == 0 ? .auto : .user
            return ZoomRegion(
                id: id("z-", j), take: take.id, start: at(start), end: at(start + 3), origin: origin, depth: depth, focus: .follow,
                instant: false)
        }
        document.camera.changes = (0..<100).map { k in
            CameraChange(id: id("k-", k), take: take.id, t: at(Double(k) * 36 + 10), style: .default, origin: .user)
        }
        let package = ProjectPackage(url: FileManager.default.temporaryDirectory.appending(path: "toma-timeline-bench.toma"))
        let manifest = Manifest(formatVersion: 3, app: AppInfo(name: "Toma", version: "bench"), createdAt: Date(), takes: [take])
        return (LoadedProject(package: package, manifest: manifest, take: take, events: events), document)
    }

    /// The target of the paced run's display link.
    private final class BenchTicker: NSObject {
        let body: (CADisplayLink) -> Void
        init(_ body: @escaping (CADisplayLink) -> Void) { self.body = body }
        @objc func tick(_ link: CADisplayLink) { body(link) }
    }

    /// An hour of a waveform that rises and falls.
    private static func syntheticWaveform() -> Waveform {
        Waveform(pairs: (0..<(3600 * Waveform.pairsPerSecond)).map { k in
            let level = Float(0.2 + 0.7 * abs(sin(Double(k) / 37)))
            return SIMD2(-level, level * 0.9)
        })
    }
}
#endif
