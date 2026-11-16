// SPDX-License-Identifier: GPL-3.0-or-later
import AppSupport
import Foundation
import ProjectFormat
import Testing

@Suite struct TimelineLayoutTests {
    /// A track of `kind` with one segment of 10 s from host 1 s, or none.
    private static func track(_ id: String, _ kind: TrackKind, recorded: Bool = true) -> TrackRecord {
        let segment = SegmentRecord(
            index: 1, file: "takes/take-001/\(id)/seg-0001.mov", startHostTime: HostTime(nanoseconds: 1_000_000_000),
            endHostTime: HostTime(nanoseconds: 11_000_000_000), endReason: .stopped, droppedFrames: 0, heartbeatFrames: 0)
        return TrackRecord(id: id, kind: kind, source: TrackSource(name: id), segments: recorded ? [segment] : [])
    }

    private static func layout(_ tracks: [TrackRecord]) -> TimelineLayout {
        let take = TakeRecord(id: "take-001", status: .complete, startedAt: Date(timeIntervalSince1970: 0), tracks: tracks)
        return TimelineLayout(take: take, document: .legacy(take: take, events: []))
    }

    @Test func tracksShownForTheTake() {
        let one = Self.layout([
            Self.track("display-1", .display), Self.track("camera", .camera), Self.track("mic", .microphone),
            Self.track("system-audio", .systemAudio),
        ])
        #expect(one.tracks == [
            TimelineRow(track: .ruler, height: 24), TimelineRow(track: .video, height: 56), TimelineRow(track: .zoom, height: 28),
            TimelineRow(track: .camera, height: 24), TimelineRow(track: .audio(id: "mic"), height: 36),
            TimelineRow(track: .audio(id: "system-audio"), height: 36),
        ])

        let two = Self.layout([Self.track("display-1", .display), Self.track("window-1", .window)])
        #expect(two.tracks == [
            TimelineRow(track: .ruler, height: 24), TimelineRow(track: .video, height: 56), TimelineRow(track: .screen, height: 24),
            TimelineRow(track: .zoom, height: 28),
        ])
    }

    @Test func tracksWithoutSegmentsAreLeftOut() {
        // A second screen, a camera and a microphone that recorded nothing; the system audio listed before the microphone.
        let layout = Self.layout([
            Self.track("display-1", .display), Self.track("display-2", .display, recorded: false),
            Self.track("camera", .camera, recorded: false), Self.track("system-audio", .systemAudio),
            Self.track("mic-2", .microphone, recorded: false), Self.track("mic", .microphone),
        ])
        #expect(layout.tracks.map(\.track) == [.ruler, .video, .zoom, .audio(id: "mic"), .audio(id: "system-audio")])
        // Without any screen, the video and zoom tracks are still there.
        #expect(Self.layout([]).tracks.map(\.track) == [.ruler, .video, .zoom])
    }

    @Test func scaleRangeIsFitTo600PointsPerSecond() {
        #expect(TimelineLayout.fitScale(duration: 120, width: 1200) == 10)
        #expect(TimelineLayout.clampScale(1000, duration: 120, width: 1200) == 600)
        #expect(TimelineLayout.clampScale(1, duration: 120, width: 1200) == 10)
        #expect(TimelineLayout.clampScale(42, duration: 120, width: 1200) == 42)
        // A sequence shorter than the width at 600 pt/s is shown at 600 pt/s at most.
        #expect(TimelineLayout.fitScale(duration: 1, width: 1200) == 600)
        #expect(TimelineLayout.clampScale(10, duration: 1, width: 1200) == 600)
        // Nothing to fit, and a scale that is not a number.
        #expect(TimelineLayout.fitScale(duration: 0, width: 1200) == 600)
        #expect(TimelineLayout.clampScale(.nan, duration: 120, width: 1200) == 10)
    }

    @Test func xAndOutputRoundTrip() {
        let layout = Self.layout([Self.track("display-1", .display)])
        let x = layout.x(ofOutput: 1_234_000_000, scale: 100, offset: 250)
        #expect(x == 88 + 123.4 - 250)
        #expect(layout.output(atX: x, scale: 100, offset: 250) == 1_234_000_000)

        // To the nanosecond: an edge 1 ns from the playhead (a split below 1×) is told apart from it.
        var generator = SplitMix64(seed: 40)
        for (scale, offset) in [(100.0, 250.0), (600.0, 1_000_000.0), (0.05, 3.5), (10.0, 0.0)] {
            for _ in 0..<1000 {
                // Up to 24 h of output.
                let τ = Int64(generator.next() % 86_400_000_000_000)
                let back = layout.output(atX: layout.x(ofOutput: τ, scale: scale, offset: offset), scale: scale, offset: offset)
                #expect(back == τ, "τ \(τ) at \(scale) pt/s, offset \(offset)")
            }
        }
        // Left of the start, a negative time; never a crash for a point that is not a number.
        #expect(layout.output(atX: 88 - 100, scale: 100, offset: 0) == -1_000_000_000)
        #expect(layout.output(atX: .nan, scale: 100, offset: 0) == 0)
    }

    @Test func autoscrollTurnsThePage() {
        // The tracks' area is 1000 pt wide, from x = 88.
        #expect(TimelineLayout.autoscrollOffset(playheadX: 88 + 1000, offset: 500, width: 1000) == 1500)
        #expect(TimelineLayout.autoscrollOffset(playheadX: 88 + 1003.5, offset: 500, width: 1000) == 1500)
        #expect(TimelineLayout.autoscrollOffset(playheadX: 88 + 999.9, offset: 500, width: 1000) == nil)
        #expect(TimelineLayout.autoscrollOffset(playheadX: 88, offset: 500, width: 1000) == nil)
        // A jump past the next page turns as many pages as it went past.
        #expect(TimelineLayout.autoscrollOffset(playheadX: 88 + 2500, offset: 500, width: 1000) == 2500)
        // Out by the left (playing again from the start): the page it is on, never before 0.
        #expect(TimelineLayout.autoscrollOffset(playheadX: 88 - 300, offset: 1500, width: 1000) == 500)
        #expect(TimelineLayout.autoscrollOffset(playheadX: 88 - 300, offset: 500, width: 1000) == 0)
        #expect(TimelineLayout.autoscrollOffset(playheadX: 88 + 5000, offset: 0, width: 0) == nil)
    }
}

/// SplitMix64: random numbers that depend only on the seed.
private struct SplitMix64 {
    var state: UInt64
    init(seed: UInt64) { state = seed }
    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}
