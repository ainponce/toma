// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import RecorderKitTestSupport
import Synchronization
import Testing
// Not @testable: the app uses only the public API.
import Editing
import ProjectFormat

// How a take of an iPhone or iPad starts in the editor (phase 2 design §6.7 and §7.6, plan 2c decision 19): with its device
// around the screen, an iPhone for upright content of an aspect of 0.6 or less and an iPad for any other, and without the
// cursor, which it never records; the automatic zoom plans nothing without clicks. Every other take starts as before.

private let base = HostTime(nanoseconds: 5_000_000_000_000)

/// `c-00000001`, `c-00000002`… from 1 for each new instance.
private final class IDs: Sendable {
    private let count = Mutex(0)

    func make(_ prefix: String) -> String {
        count.withLock { count in
            count += 1
            return prefix + String(format: "%08x", count)
        }
    }
}

/// A take of 1 s of a device whose first segment is `width` × `height` pixels (its frames a tenth of that), with its sound
/// and the Mac's microphone, as the iPhone mode records it: no cursor, no clicks, no keys.
private func deviceTake(in dir: URL, name: String = "Fixture", width: Int, height: Int) async throws -> LoadedProject {
    let builder = try TakeBuilder(in: dir, name: name, formatVersion: 4)
    let source = TrackSource(
        name: "Synthetic iPhone", deviceUniqueID: "synthetic-device",
        globalFrame: Rect(x: 0, y: 0, width: Double(width), height: Double(height)), pixelScale: 1)
    try await builder.addVideoTrack(id: "device", kind: .device, source: source, segments: [
        VideoSegmentSpec(start: base, seconds: 1, framesPerSecond: 10, width: width / 10, height: height / 10),
    ])
    try await builder.addAudioTrack(
        id: "deviceAudio", kind: .deviceAudio, source: TrackSource(name: "Synthetic iPhone", deviceUniqueID: "synthetic-device"),
        segments: [AudioSegmentSpec(start: base, seconds: 1, channels: 2)])
    try await builder.addAudioTrack(
        id: "mic", source: TrackSource(name: "Synthetic Microphone", deviceUniqueID: "synthetic-mic"),
        segments: [AudioSegmentSpec(start: base, seconds: 1)])
    return try builder.write()
}

@Suite struct DeviceTakeDefaultsTests {
    @Test func deviceTakeStartsWithItsFrameAndNoCursor() async throws {
        try await withTemporaryDirectory { dir in
            let project = try await deviceTake(in: dir, width: 1080, height: 1920)
            let document = NewDocument.make(project: project, defaultStyle: .toma, makeID: IDs().make)
            #expect(document.style.frame == .device(DeviceFrame(model: .iPhone, finish: .dark)))
            #expect(!document.cursor.show)
            // Without clicks, the automatic zoom plans nothing; it stays on, for zooms added by hand.
            #expect(document.zoom.regions.isEmpty)
            #expect(document.zoom.auto == DefaultStyle.toma.zoomAuto)
            // The rest is the style's.
            var unframed = document
            unframed.style.frame = DefaultStyle.toma.style.frame
            #expect(unframed.style == DefaultStyle.toma.style)
            #expect(document.cursor.scale == DefaultStyle.toma.cursor.scale)
            // Its sound is in the mix, at gain 1, like the microphone's.
            #expect(document.audio.tracks[AudioPlan.key(take: project.take.id, track: "deviceAudio")] == TrackGain(gain: 1, muted: false))
            #expect(document.audio.tracks.count == 2)
            // Applied again, nothing changes.
            #expect(DeviceTakeDefaults.applied(to: document, take: project.take) == document)

            let iPad = try await deviceTake(in: dir, name: "iPad", width: 1640, height: 2360)
            #expect(NewDocument.make(project: iPad, defaultStyle: .toma, makeID: IDs().make).style.frame
                == .device(DeviceFrame(model: .iPad, finish: .dark)))
            // Turned before the take started, an iPhone records wide content: the iPad's frame fits it.
            let wide = try await deviceTake(in: dir, name: "Wide", width: 1920, height: 1080)
            #expect(DeviceTakeDefaults.model(of: wide.take) == .iPad)
        }
    }

    @Test func widerContentGetsTheIPad() {
        #expect(DeviceTakeDefaults.iPhoneMaximumAspect == 0.6)
        #expect(DeviceTakeDefaults.frame(contentAspect: 0.75) == DeviceFrame(model: .iPad, finish: .dark))
        #expect(DeviceTakeDefaults.frame(contentAspect: 0.46) == DeviceFrame(model: .iPhone, finish: .dark))
        #expect(DeviceTakeDefaults.frame(contentAspect: 0.6) == DeviceFrame(model: .iPhone, finish: .dark))
        #expect(DeviceTakeDefaults.frame(contentAspect: 16.0 / 9).model == .iPad)
    }

    @Test func aDeviceThatToldNoSizeKeepsTheStylesFrame() {
        let untold = TakeRecord(
            id: "take-001", status: .complete, startedAt: Date(timeIntervalSince1970: 1_800_000_000), tracks: [
                TrackRecord(id: "device", kind: .device, source: TrackSource(name: "iPhone", deviceUniqueID: "x"), segments: []),
            ])
        let document = EditDocument.legacy(take: untold, events: [])
        #expect(DeviceTakeDefaults.model(of: untold) == nil)
        let applied = DeviceTakeDefaults.applied(to: document, take: untold)
        #expect(applied.style.frame == document.style.frame)
        #expect(!applied.cursor.show)
    }

    @Test func otherTakesAreUnchanged() async throws {
        try await withTemporaryDirectory { dir in
            let project = try await GoldenProjects.make("pausedTake", in: dir, formatVersion: 3)
            let document = NewDocument.make(project: project, defaultStyle: .toma, makeID: IDs().make)
            #expect(DeviceTakeDefaults.model(of: project.take) == nil)
            #expect(DeviceTakeDefaults.applied(to: document, take: project.take) == document)
            #expect(document.style.frame == DefaultStyle.toma.style.frame)
            #expect(document.cursor.show == DefaultStyle.toma.cursor.show)
        }
    }
}
