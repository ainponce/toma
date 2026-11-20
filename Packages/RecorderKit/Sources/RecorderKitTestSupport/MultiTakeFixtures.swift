// SPDX-License-Identifier: GPL-3.0-or-later
import CoreMedia
import CoreVideo
import Foundation
import ProjectFormat

/// A package of two takes (phase 3 design §9), for the tests of the sequence that shows more than one, and the documents
/// that show them.
public enum MultiTakeFixtures {
    /// Writes `TwoTakes.toma` into `dir`, of `Manifest.currentFormatVersion` (the second take is appended as
    /// `TakeBuilder(appendingTo:take:)` does, in the version the package has), and returns it as `LoadedProject.load`
    /// reads it without a take: focused on the last one, `take-002`.
    ///
    /// - `take-001`: 4 s of the display `display-1` (16:9, 640 × 360, `SampleFactory`'s pattern), the microphone `mic`
    ///   (the 440 Hz sine at 1/4 of full scale) and the cursor moving over the display the whole time, with a left click
    ///   at 1.0 s and at 3.4 s (seconds from the take's start), as `GoldenDocuments`' take of 4 s without its camera.
    /// - `take-002`, recorded 60 s later: 3 s of `display-1` with the colours of every frame inverted (so no frame of it
    ///   looks like one of `take-001`), `mic` at 660 Hz and the cursor moving over the display, without clicks: the same
    ///   track IDs, so a track's gain holds by its id in both (`AudioPlan.trackGain(take:track:takes:)`).
    public static func twoTakes(in dir: URL) async throws -> LoadedProject {
        try await twoTakes(in: dir, name: "TwoTakes", secondScreen: screen)
    }

    /// `twoTakes(in:)` with the display of `take-002` of `secondScreen` (its global frame, and its pixels at 1×), as
    /// one recorded on another screen: `Rect(x: 0, y: 0, width: 480, height: 360)` for a 4:3 one.
    public static func twoTakes(in dir: URL, name: String, secondScreen: Rect) async throws -> LoadedProject {
        let first = try TakeBuilder(in: dir, name: name)
        try await record(into: first, start: base, seconds: 4, clicks: [1.0, 3.4], frequency: 440, inverted: false, screen: screen)
        _ = try first.write()
        let second = try TakeBuilder(appendingTo: first.package, take: "take-002")
        try await record(
            into: second, start: base.adding(seconds: 60), seconds: 3, clicks: [], frequency: 660, inverted: true,
            screen: secondScreen)
        _ = try second.write()
        return try LoadedProject.load(first.package.url)
    }

    /// The legacy document of `project` (`EditDocument.legacy(for:)`) with `pieces` as its sequence, at 1×, with the IDs
    /// `c-00000001`, `c-00000002`… in order: each piece shows its take from `from` to `to`, seconds from the start of
    /// that take's legacy clip (`TakeTimeline.editableBounds`; of `project`'s take for a take the package does not have).
    /// Every other take the sequence shows has the screen and the camera its own legacy document gives it
    /// (`screens.initial`, `camera.initial`), so each clip draws its take as that take alone; the tracks' gains stay
    /// those of `project`'s take, which the other takes' tracks find by their id.
    public static func sequence(
        of project: LoadedProject, _ pieces: [(take: String, from: Double, to: Double)]
    ) -> EditDocument {
        var document = EditDocument.legacy(for: project)
        let ownStart = document.sequence.first?.start ?? HostTime(nanoseconds: 0)
        var starts: [String: HostTime] = [project.take.id: ownStart]
        for piece in pieces where starts[piece.take] == nil {
            guard let other = project.focused(on: piece.take) else { continue }
            let legacy = EditDocument.legacy(for: other)
            starts[piece.take] = legacy.sequence.first?.start ?? ownStart
            document.screens.initial.merge(legacy.screens.initial) { own, _ in own }
            document.camera.initial.merge(legacy.camera.initial) { own, _ in own }
        }
        document.sequence = pieces.enumerated().map { index, piece in
            let start = starts[piece.take] ?? ownStart
            return Clip(
                id: "c-" + String(format: "%08x", index + 1), take: piece.take, start: start.adding(seconds: piece.from),
                end: start.adding(seconds: piece.to), speed: 1)
        }
        return document
    }

    // MARK: - The takes

    /// `GoldenDocuments`' time of the takes' start, well after boot.
    private static let base = HostTime(nanoseconds: 5_000_000_000_000)
    private static let screen = Rect(x: 0, y: 0, width: 640, height: 360)

    /// Adds to `builder` `seconds` of `display-1` of `screen` (its colours `inverted` or not), of `mic` (the sine at
    /// `frequency`) and of the cursor from `start`, with a left click at each of `clicks`, where the cursor is then.
    private static func record(
        into builder: TakeBuilder, start: HostTime, seconds: Double, clicks: [Double], frequency: Double, inverted: Bool,
        screen: Rect
    ) async throws {
        try await builder.addVideoTrack(
            id: "display-1",
            source: TrackSource(name: "Synthetic Display 1", displayID: 1, globalFrame: screen, pixelScale: 1),
            segments: [VideoSegmentSpec(
                start: start, seconds: seconds, width: Int(screen.width), height: Int(screen.height),
                transform: inverted ? invertingColors : nil)])
        try await builder.addAudioTrack(
            id: "mic", source: TrackSource(name: "Synthetic Microphone", deviceUniqueID: "synthetic-mic"),
            segments: [AudioSegmentSpec(start: start, seconds: seconds, frequency: frequency)])
        // The display's geometry as the coordinator logs it, just before the first segment.
        try builder.addEvents([
            InputEvent(t: start.adding(seconds: -0.01), kind: .displayGeometry(displayID: 1, frame: screen, scale: 1))
        ])
        try builder.addEvents((0..<Int(seconds * 120)).map { i in
            let at = cursorPosition(at: Double(i) / 120, seconds: seconds, screen: screen)
            return InputEvent(t: start.adding(seconds: Double(i) / 120), kind: .cursor(x: at.x, y: at.y))
        })
        try builder.addEvents(clicks.flatMap { t -> [InputEvent] in
            let at = cursorPosition(at: t, seconds: seconds, screen: screen)
            return [
                InputEvent(t: start.adding(seconds: t), kind: .mouseDown(.left, x: at.x, y: at.y)),
                InputEvent(t: start.adding(seconds: t + 0.08), kind: .mouseUp(.left, x: at.x, y: at.y)),
            ]
        })
    }

    /// Where the cursor is `t` seconds after the start of a take of `seconds`: across `screen`, as in `GoldenDocuments`.
    private static func cursorPosition(at t: Double, seconds: Double, screen: Rect) -> SIMD2<Double> {
        let f = t / seconds
        return SIMD2(screen.x + screen.width * (0.2 + 0.6 * f), screen.y + screen.height * (0.3 + 0.4 * f))
    }

    /// `sample` with the red, green and blue of every pixel inverted (a `VideoSegmentSpec.transform`).
    @Sendable private static func invertingColors(_ frameIndex: Int, _ sample: CMSampleBuffer) -> CMSampleBuffer {
        guard let pixelBuffer = CMSampleBufferGetImageBuffer(sample) else { preconditionFailure("MultiTakeFixtures: no image") }
        CVPixelBufferLockBaseAddress(pixelBuffer, [])
        defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, []) }
        guard let pixels = CVPixelBufferGetBaseAddress(pixelBuffer) else { preconditionFailure("MultiTakeFixtures: no pixels") }
        let width = CVPixelBufferGetWidth(pixelBuffer), bytesPerRow = CVPixelBufferGetBytesPerRow(pixelBuffer)
        for y in 0..<CVPixelBufferGetHeight(pixelBuffer) {
            let row = pixels.advanced(by: y * bytesPerRow).assumingMemoryBound(to: UInt32.self)
            for x in 0..<width { row[x] ^= 0x00FF_FFFF }  // BGRA bytes: B, G and R, not A
        }
        return sample
    }
}
