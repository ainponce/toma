// SPDX-License-Identifier: GPL-3.0-or-later
import CoreGraphics
import Foundation
import ImageIO
import ProjectFormat
import Synchronization
import UniformTypeIdentifiers

/// The Replay's working package as its ring leaves it when a save freezes it (fases 4 y 5 plan 5c, Task R3), written
/// without capture: `ReplayScratch.create` (the marker) in `<directory>/Replay/`, and its take `take-001`, `recording`,
/// written with `TakeBuilder`:
///
/// - `display-1` (640 × 360 pt, 10 fps), `camera-1` (320 × 180, 10 fps) and `microphone-1` (48 kHz), in segments
///   closed `rotated` every `segment` seconds from `start` (the last one shorter if `seconds` is not a multiple), all
///   three rotating at the same instants, each starting with its `segmentStarted` and the microphone with its anchors;
/// - the events in one file per segment of time (`events-0001.jsonl`… for `[start + (k − 1)·segment,
///   start + k·segment)`, the first also with what comes before `start`): the display's geometry just before `start`,
///   the cursor every 0.1 s across the display, a click (`mouseDown`, `mouseUp` 0.1 s later) at 0.7 s and every 1.5 s
///   after, two images of the cursor (`firstCursorHash` at 0.05 s, `secondCursorHash` at 1 s), a `cameraStyle` at 1.5 s
///   (`laterCameraStyle`, after the take's `initialCameraStyle`), and with `keys` a `keyPress` every 0.5 s (the
///   manifest raised to version 4, as the Replay's `FormatRaising` does);
/// - with `pruned` k, the first k segments of every track and the first k event files gone, as the ring prunes them:
///   files and manifest records, and the state of those event files folded into `snapshot.carried`
///   (`ReplayEventState`).
public struct ReplayFixture {
    /// The working package.
    public let package: ProjectPackage
    /// When the take's first segment started (before any pruning).
    public let start: HostTime
    public static let initialCameraStyle = CameraStyle(shape: .roundedSquare, size: CameraStyle.small, anchor: .topLeading)
    public static let laterCameraStyle = CameraStyle(shape: .circle, size: CameraStyle.large, anchor: .bottomTrailing)
    /// The hashes of the two images of the cursor (`cursors/<hash>.png`).
    public let firstCursorHash: String
    public let secondCursorHash: String
    public let snapshot: ReplaySnapshot
    private let replaySource: Source

    /// A Replay that freezes into `snapshot` and counts the calls to `thaw()`.
    public var source: any ReplaySource { replaySource }
    /// How many times `source.thaw()` was called.
    public var thawCount: Int { replaySource.thaws }

    /// Writes the working package in `<directory>/Replay/current.toma`: `seconds` of take in segments of `segment` s.
    public init(in directory: URL, seconds: Double, segment: Double = 2, pruned: Int = 0, keys: Bool = false) async throws {
        let start = HostTime(nanoseconds: 5_000_000_000_000)
        let root = directory.appending(path: "Replay", directoryHint: .isDirectory)
        let package = try ReplayScratch.create(in: root, app: AppInfo(name: "Tests", version: "0"), now: Date())
        if keys { try ManifestStore(package: package).update(raisingTo: 4) { _ in } }
        let builder = try TakeBuilder(appendingTo: package, take: ReplayScratch.takeID)
        builder.cameraStyle = Self.initialCameraStyle

        // The edges of the segments, from `start`.
        var edges: [Double] = [0]
        while let last = edges.last, last < seconds - 1e-9 { edges.append(min(seconds, last + segment)) }
        let spans = zip(edges, edges.dropFirst()).map { (start: $0, seconds: $1 - $0) }
        let frame = Rect(x: 0, y: 0, width: 640, height: 360)
        try await builder.addVideoTrack(
            id: "display-1", source: TrackSource(name: "Synthetic Display", displayID: 1, globalFrame: frame, pixelScale: 1),
            segments: spans.map {
                VideoSegmentSpec(start: start.adding(seconds: $0.start), seconds: $0.seconds, framesPerSecond: 10, endReason: .rotated)
            })
        try await builder.addVideoTrack(
            id: "camera-1", kind: .camera, source: TrackSource(name: "Synthetic Camera", deviceUniqueID: "camera-1"),
            segments: spans.map {
                VideoSegmentSpec(
                    start: start.adding(seconds: $0.start), seconds: $0.seconds, framesPerSecond: 10, width: 320, height: 180,
                    endReason: .rotated)
            })
        try await builder.addAudioTrack(
            id: "microphone-1", kind: .microphone, source: TrackSource(name: "Synthetic Microphone", deviceUniqueID: "mic-1"),
            segments: spans.map { AudioSegmentSpec(start: start.adding(seconds: $0.start), seconds: $0.seconds, endReason: .rotated) })

        func at(_ seconds: Double) -> HostTime { start.adding(seconds: seconds) }
        try builder.addEvents([InputEvent(t: at(-0.01), kind: .displayGeometry(displayID: 1, frame: frame, scale: 1))])
        let png = try Self.png()
        firstCursorHash = try builder.addCursorImage(png, hotspot: SIMD2(0.1, 0.1), size: SIMD2(16, 16), kind: .arrow, at: at(0.05))
        secondCursorHash = try builder.addCursorImage(png, hotspot: SIMD2(0.5, 0.5), size: SIMD2(16, 16), kind: .arrow, at: at(1))
        let moves = Int((seconds * 10).rounded(.down))
        try builder.addEvents((0..<moves).map { i in
            InputEvent(t: at(Double(i) / 10), kind: .cursor(x: 20 + Double(i % 60) * 10, y: 180))
        })
        var click = 0.7
        while click + 0.1 < seconds {
            let x = 20 + Double(Int((click * 10).rounded()) % 60) * 10
            try builder.addEvents([
                InputEvent(t: at(click), kind: .mouseDown(.left, x: x, y: 180)),
                InputEvent(t: at(click + 0.1), kind: .mouseUp(.left, x: x, y: 180)),
            ])
            click += 1.5
        }
        try builder.addEvents([InputEvent(t: at(1.5), kind: .cameraStyle(Self.laterCameraStyle))])
        if keys {
            try builder.addEvents(stride(from: 0.25, to: seconds, by: 0.5).map {
                InputEvent(t: at($0), kind: .keyPress(code: 0, chars: "a", mods: 0, isRepeat: false))
            })
        }
        _ = try builder.write(status: .recording)

        // The one event log becomes one file per segment of time.
        let log = package.eventsURL(take: ReplayScratch.takeID)
        let events = try EventLogReader.read(log).events
        try FileManager.default.removeItem(at: log)
        var shards: [URL] = []
        for (index, span) in spans.enumerated() {
            let url = ReplayScratch.shardURL(of: package, index: index + 1)
            let writer = try EventLogWriter(url: url)
            let isLast = index == spans.count - 1
            for event in events {
                let after = index == 0 || event.t >= at(span.start)
                let before = isLast || event.t < at(span.start + span.seconds)
                if after && before { writer.append(event) }
            }
            try writer.close()
            shards.append(url)
        }

        // The ring's pruning of the first `pruned` segments and event files.
        let store = try ManifestStore(package: package)
        let prunedCount = min(pruned, spans.count - 1)
        var state = ReplayEventState(cameraStyle: Self.initialCameraStyle)
        for url in shards.prefix(prunedCount) {
            state.fold(try EventLogReader.read(url).events)
            try FileManager.default.removeItem(at: url)
        }
        try store.update { manifest in
            for i in manifest.takes[0].tracks.indices {
                let segments = manifest.takes[0].tracks[i].segments
                for segment in segments.prefix(prunedCount) {
                    try FileManager.default.removeItem(at: package.url.appending(path: segment.file))
                }
                manifest.takes[0].tracks[i].segments = Array(segments.dropFirst(prunedCount))
            }
        }
        let manifest = store.manifest

        self.package = package
        self.start = start
        snapshot = ReplaySnapshot(
            package: package, take: manifest.takes[0], formatVersion: manifest.formatVersion,
            shards: Array(shards.dropFirst(prunedCount)), carried: state.events)
        replaySource = Source(snapshot)
    }

    /// A Replay frozen into one snapshot.
    private final class Source: ReplaySource {
        private let snapshot: ReplaySnapshot
        private let thawed = Mutex(0)

        init(_ snapshot: ReplaySnapshot) {
            self.snapshot = snapshot
        }

        var thaws: Int { thawed.withLock { $0 } }

        func freeze() async throws -> ReplaySnapshot { snapshot }

        func thaw() async {
            thawed.withLock { $0 += 1 }
        }
    }

    /// A 16 × 16 PNG of a dark arrow-ish block.
    private static func png() throws -> Data {
        guard let context = CGContext(
            data: nil, width: 16, height: 16, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { throw TestSupportError.failed("no context") }
        context.setFillColor(CGColor(red: 0, green: 0, blue: 0, alpha: 1))
        context.fill(CGRect(x: 2, y: 2, width: 8, height: 12))
        guard let image = context.makeImage() else { throw TestSupportError.failed("no image") }
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data as CFMutableData, UTType.png.identifier as CFString, 1, nil)
        else { throw TestSupportError.failed("no destination") }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else { throw TestSupportError.failed("no PNG") }
        return data as Data
    }
}
