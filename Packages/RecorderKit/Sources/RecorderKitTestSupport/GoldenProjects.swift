// SPDX-License-Identifier: GPL-3.0-or-later
import CoreMedia
import CoreVideo
import Foundation
import ProjectFormat

/// The projects of the golden files of milestone 1b (plan decision 3): takes of version 1 and 2 without edits whose
/// frames (`goldenFramesMatch`) and mix (`goldenMixMatches`) were recorded before the first change of 1b to the render,
/// so that every later change can show that such a project still draws and sounds the same, byte for byte.
///
/// Each case is written by `TakeBuilder` with its format version given, the same way on every run, and lasts at least
/// 3 s; its frames are drawn at 1280 × 720 at its `times`, all shorter than that. A case without times is only mixed.
/// Changing a case, or the order of `cases`, changes the golden files: never do it once they are recorded.
public enum GoldenProjects {
    public struct Case: Sendable {
        public var name: String
        /// Output times its frames are drawn at, in order; none for a case that is only mixed.
        public var times: [Double]
    }

    /// In the order of their frames in the golden file.
    public static let cases: [Case] = [
        Case(name: "phaseZero", times: [0, 0.5, 1.7]),
        Case(name: "windowMoving", times: [0.5, 1.5, 2.5]),
        Case(name: "areaOnDisplay", times: [0.5, 1.5]),
        Case(name: "cameraWithStyleChanges", times: [0.9, 1.25, 2.0]),
        Case(name: "geometryChange", times: [1.0, 2.0]),
        Case(name: "pausedTake", times: [0.5, 1.5, 2.5]),
        Case(name: "twoAudioTracks", times: []),
    ]

    /// Writes case `name` into `dir`, as the package `<name>.toma` (so the cases fit in one folder), and returns its
    /// take. `formatVersion` `nil` gives the case's own version (1 for `phaseZero`, 2 for the others); another one is
    /// passed to `TakeBuilder`, for example 3 for `pausedTake` as a version 3 package.
    /// - Throws: `TestSupportError.missing` for a name that is not a case, or what writing the take throws.
    public static func make(_ name: String, in dir: URL, formatVersion: Int? = nil) async throws -> LoadedProject {
        switch name {
        case "phaseZero": return try await phaseZero(in: dir, formatVersion: formatVersion ?? 1)
        case "windowMoving": return try await windowMoving(in: dir, formatVersion: formatVersion ?? 2)
        case "areaOnDisplay": return try await areaOnDisplay(in: dir, formatVersion: formatVersion ?? 2)
        case "cameraWithStyleChanges": return try await cameraWithStyleChanges(in: dir, formatVersion: formatVersion ?? 2)
        case "geometryChange": return try await geometryChange(in: dir, formatVersion: formatVersion ?? 2)
        case "pausedTake": return try await pausedTake(in: dir, formatVersion: formatVersion ?? 2)
        case "twoAudioTracks": return try await twoAudioTracks(in: dir, formatVersion: formatVersion ?? 2)
        default: throw TestSupportError.missing("golden case \(name)")
        }
    }

    // MARK: - The cases

    /// The take of 1a's golden frames as the phase 0 recorder left it: a version 1 package with a 3 s display segment,
    /// the display's `displayGeometry` logged as the take starts (its `globalFrame`), the cursor moving over it the
    /// whole time and a microphone. Its frames are the first of the golden file, the bytes 1a recorded.
    private static func phaseZero(in dir: URL, formatVersion: Int) async throws -> LoadedProject {
        let builder = try TakeBuilder(in: dir, name: "phaseZero", formatVersion: formatVersion)
        try await builder.addVideoTrack(
            id: displayTrack, source: displaySource(globalFrame: screenFrame), segments: [VideoSegmentSpec(start: base, seconds: 3)])
        try await builder.addAudioTrack(id: "mic", source: microphone, segments: [AudioSegmentSpec(start: base, seconds: 3)])
        try builder.addEvents([startGeometry(screenFrame)])
        try builder.addEvents(cursorEvents(from: base, seconds: 3, across: screenFrame))
        return try builder.write()
    }

    /// A window that moves 200 pt right at 1 s and leaves the screen at 2 s, with the cursor moving from 0.05 s before
    /// its first segment, so a frame sees the sample before `timelineStart`.
    private static func windowMoving(in dir: URL, formatVersion: Int) async throws -> LoadedProject {
        let window = "window-4242"
        let frame = Rect(x: 100, y: 100, width: 800, height: 600)
        let moved = Rect(x: 300, y: 100, width: 800, height: 600)
        let builder = try TakeBuilder(in: dir, name: "windowMoving", formatVersion: formatVersion)
        try await builder.addVideoTrack(
            id: window, kind: .window,
            source: TrackSource(name: "Synthetic Window", globalFrame: frame, pixelScale: 1, windowID: 4242, bundleIdentifier: "dev.toma.tests"),
            segments: [VideoSegmentSpec(start: base, seconds: 3, width: 800, height: 600)])
        try builder.addEvents([
            // Where it is as the take starts, as the coordinator logs it; then the window watcher's changes.
            InputEvent(t: base.adding(seconds: -0.01), kind: .windowGeometry(track: window, frame: frame, onScreen: true)),
            InputEvent(t: base.adding(seconds: 1), kind: .windowGeometry(track: window, frame: moved, onScreen: true)),
            InputEvent(t: base.adding(seconds: 2), kind: .windowGeometry(track: window, frame: moved, onScreen: false)),
        ])
        try builder.addEvents(cursorEvents(from: base.adding(seconds: -0.05), seconds: 3, across: frame))
        return try builder.write()
    }

    /// Area mode: a 1512 × 982 display of which the area (100, 100, 800, 450) is shown, the cursor moving over the display.
    private static func areaOnDisplay(in dir: URL, formatVersion: Int) async throws -> LoadedProject {
        let display = Rect(x: 0, y: 0, width: 1512, height: 982)
        var source = displaySource(globalFrame: display)
        source.captureArea = Rect(x: 100, y: 100, width: 800, height: 450)
        let builder = try TakeBuilder(in: dir, name: "areaOnDisplay", formatVersion: formatVersion)
        try await builder.addVideoTrack(
            id: displayTrack, source: source, segments: [VideoSegmentSpec(start: base, seconds: 3, width: 1512, height: 982)])
        try builder.addEvents([startGeometry(display)])
        try builder.addEvents(cursorEvents(from: base, seconds: 3, across: display))
        return try builder.write()
    }

    /// The display and a 4:3 camera, which starts as a small landscape box at the top left and changes to a large
    /// portrait one at the top at 1 s and, 0.1 s later, in the middle of that change, to a medium circle at the bottom
    /// right. The camera's colours are inverted: otherwise it would have the colour of the screen frame behind it.
    private static func cameraWithStyleChanges(in dir: URL, formatVersion: Int) async throws -> LoadedProject {
        let builder = try TakeBuilder(in: dir, name: "cameraWithStyleChanges", formatVersion: formatVersion)
        builder.cameraStyle = CameraStyle(shape: .landscape, size: 0.17, anchor: .topLeading)
        try await builder.addVideoTrack(
            id: displayTrack, source: displaySource(globalFrame: screenFrame), segments: [VideoSegmentSpec(start: base, seconds: 3)])
        try await builder.addVideoTrack(
            id: "camera", kind: .camera, source: TrackSource(name: "Synthetic Camera", deviceUniqueID: "synthetic-camera"),
            segments: [VideoSegmentSpec(start: base, seconds: 3, width: 640, height: 480, transform: invertingColors)])
        try builder.addEvents([
            startGeometry(screenFrame),
            InputEvent(t: base.adding(seconds: 1), kind: .cameraStyle(CameraStyle(shape: .portrait, size: 0.33, anchor: .top))),
            InputEvent(t: base.adding(seconds: 1.1), kind: .cameraStyle(CameraStyle(shape: .circle, size: 0.24, anchor: .bottomTrailing))),
        ])
        try builder.addEvents(cursorEvents(from: base, seconds: 3, across: screenFrame))
        return try builder.write()
    }

    /// The display, whose frame grows 1.25 times at 1.5 s (another resolution) with its segment going on.
    private static func geometryChange(in dir: URL, formatVersion: Int) async throws -> LoadedProject {
        let grown = Rect(x: 0, y: 0, width: screenFrame.width * 1.25, height: screenFrame.height * 1.25)
        let builder = try TakeBuilder(in: dir, name: "geometryChange", formatVersion: formatVersion)
        try await builder.addVideoTrack(
            id: displayTrack, source: displaySource(globalFrame: screenFrame), segments: [VideoSegmentSpec(start: base, seconds: 3)])
        try builder.addEvents([
            startGeometry(screenFrame),
            InputEvent(t: base.adding(seconds: 1.5), kind: .displayGeometry(displayID: 1, frame: grown, scale: 1)),
        ])
        try builder.addEvents(cursorEvents(from: base, seconds: 3, across: screenFrame))
        return try builder.write()
    }

    /// The display and the microphone, paused by the user from 1 to 2 s: segments [0, 1] and [2, 3] s of each, and no
    /// cursor samples while paused, as the recorder leaves it.
    private static func pausedTake(in dir: URL, formatVersion: Int) async throws -> LoadedProject {
        let resume = base.adding(seconds: 2)
        let builder = try TakeBuilder(in: dir, name: "pausedTake", formatVersion: formatVersion)
        try await builder.addVideoTrack(
            id: displayTrack, source: displaySource(globalFrame: screenFrame),
            segments: [VideoSegmentSpec(start: base, seconds: 1, endReason: .paused), VideoSegmentSpec(start: resume, seconds: 1)])
        try await builder.addAudioTrack(
            id: "mic", source: microphone,
            segments: [AudioSegmentSpec(start: base, seconds: 1, endReason: .paused), AudioSegmentSpec(start: resume, seconds: 1)])
        try builder.addEvents([
            startGeometry(screenFrame),
            InputEvent(t: base.adding(seconds: 1), kind: .paused(reason: "user")),
            InputEvent(t: resume, kind: .resumed),
        ])
        try builder.addEvents(cursorEvents(from: base, seconds: 3, across: screenFrame).filter {
            $0.t < base.adding(seconds: 1) || $0.t >= resume
        })
        return try builder.write()
    }

    /// The display, the microphone at 0.6 of full scale (440 Hz) and stereo system audio at 0.7 (1000 Hz) over the
    /// same 3 s: where the two add up past full scale, the mix clips. Only mixed.
    private static func twoAudioTracks(in dir: URL, formatVersion: Int) async throws -> LoadedProject {
        let builder = try TakeBuilder(in: dir, name: "twoAudioTracks", formatVersion: formatVersion)
        try await builder.addVideoTrack(
            id: displayTrack, source: displaySource(globalFrame: screenFrame), segments: [VideoSegmentSpec(start: base, seconds: 3)])
        try await builder.addAudioTrack(
            id: "mic", source: microphone, segments: [AudioSegmentSpec(start: base, seconds: 3, amplitude: 0.6)])
        try await builder.addAudioTrack(
            id: "system-audio", kind: .systemAudio, source: TrackSource(name: "System Audio", excludedBundleIDs: []),
            segments: [AudioSegmentSpec(start: base, seconds: 3, channels: 2, frequency: 1000, amplitude: 0.7)])
        try builder.addEvents([startGeometry(screenFrame)])
        return try builder.write()
    }

    // MARK: - Shared values

    /// An arbitrary host time well after boot: where every case's first segment starts.
    private static let base = HostTime(nanoseconds: 5_000_000_000_000)
    private static let displayTrack = "display-1"
    private static let screenFrame = Rect(x: 0, y: 0, width: 640, height: 360)
    private static let microphone = TrackSource(name: "Synthetic Microphone", deviceUniqueID: "synthetic-mic")

    private static func displaySource(globalFrame: Rect) -> TrackSource {
        TrackSource(name: "Synthetic Display", displayID: 1, globalFrame: globalFrame, pixelScale: 1)
    }

    /// The `displayGeometry` of display 1 that the coordinator logs as the take starts, just before its first segment.
    private static func startGeometry(_ frame: Rect) -> InputEvent {
        InputEvent(t: base.adding(seconds: -0.01), kind: .displayGeometry(displayID: 1, frame: frame, scale: 1))
    }

    /// `sample` with the red, green and blue of every pixel inverted (a `VideoSegmentSpec.transform`): the frame of the
    /// same number on another track, which has `SampleFactory`'s colours, never looks like it.
    @Sendable private static func invertingColors(_ frameIndex: Int, _ sample: CMSampleBuffer) -> CMSampleBuffer {
        guard let pixelBuffer = CMSampleBufferGetImageBuffer(sample) else { preconditionFailure("GoldenProjects: no image") }
        CVPixelBufferLockBaseAddress(pixelBuffer, [])
        defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, []) }
        guard let pixels = CVPixelBufferGetBaseAddress(pixelBuffer) else { preconditionFailure("GoldenProjects: no pixels") }
        let width = CVPixelBufferGetWidth(pixelBuffer), bytesPerRow = CVPixelBufferGetBytesPerRow(pixelBuffer)
        for y in 0..<CVPixelBufferGetHeight(pixelBuffer) {
            let row = pixels.advanced(by: y * bytesPerRow).assumingMemoryBound(to: UInt32.self)
            for x in 0..<width { row[x] ^= 0x00FF_FFFF }  // BGRA bytes: B, G and R, not A
        }
        return sample
    }

    /// Cursor samples every 1/120 s for `seconds` from `start`, moving across `frame` (1a's golden take had these).
    private static func cursorEvents(from start: HostTime, seconds: Double, across frame: Rect) -> [InputEvent] {
        (0..<Int(seconds * 120)).map { i in
            let f = Double(i) / (seconds * 120)
            return InputEvent(
                t: start.adding(seconds: Double(i) / 120),
                kind: .cursor(x: frame.x + frame.width * (0.2 + 0.6 * f), y: frame.y + frame.height * (0.3 + 0.4 * f)))
        }
    }
}
