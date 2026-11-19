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
            TimelineRow(track: .camera, height: 32), TimelineRow(track: .audio(id: "mic"), height: 36),
            TimelineRow(track: .audio(id: "system-audio"), height: 36),
        ])

        let two = Self.layout([Self.track("display-1", .display), Self.track("window-1", .window)])
        #expect(two.tracks == [
            TimelineRow(track: .ruler, height: 24), TimelineRow(track: .video, height: 56), TimelineRow(track: .screen, height: 24),
            TimelineRow(track: .zoom, height: 28),
        ])
    }

    /// An iPhone's take: its screen is the Video row, its sound a row of its own after the Mac's microphone.
    @Test func aDeviceTakeHasARowForItsSound() {
        let layout = Self.layout([
            Self.track("device", .device), Self.track("deviceAudio", .deviceAudio), Self.track("mic", .microphone),
        ])
        #expect(layout.tracks == [
            TimelineRow(track: .ruler, height: 24), TimelineRow(track: .video, height: 56), TimelineRow(track: .zoom, height: 28),
            TimelineRow(track: .audio(id: "mic"), height: 36), TimelineRow(track: .audio(id: "deviceAudio"), height: 36),
        ])
    }

    private static func documentWith(transcript: Transcript? = nil, privacy: PrivacyPlan = .legacy, take: TakeRecord) -> EditDocument {
        var document = EditDocument.legacy(take: take, events: [])
        document.transcript = transcript
        document.privacy = privacy
        return document
    }

    private static func fullTake() -> TakeRecord {
        TakeRecord(
            id: "take-001", status: .complete, startedAt: Date(timeIntervalSince1970: 0),
            tracks: [track("display-1", .display), track("camera", .camera), track("mic", .microphone)])
    }

    @Test func captionsRowOnlyWithATranscript() {
        let take = Self.fullTake()
        #expect(!TimelineLayout(take: take, document: .legacy(take: take, events: [])).tracks.map(\.track).contains(.captions))
        let transcript = Transcript(language: "es-AR", engine: "speechTranscriber-1", takes: [])
        let layout = TimelineLayout(take: take, document: Self.documentWith(transcript: transcript, take: take))
        #expect(layout.tracks.map(\.track) == [.ruler, .video, .captions, .zoom, .camera, .audio(id: "mic")])
        #expect(layout.tracks[2] == TimelineRow(track: .captions, height: 28))
    }

    @Test func privacyRowOnlyWithBlocks() {
        let take = Self.fullTake()
        let block = PrivacyBlock(
            id: "p-00000001", take: "take-001", start: HostTime(nanoseconds: 1_000_000_000),
            end: HostTime(nanoseconds: 2_000_000_000), effect: .blur, rect: NormalizedRect(x: 0.1, y: 0.1, width: 0.2, height: 0.2))
        let layout = TimelineLayout(take: take, document: Self.documentWith(privacy: PrivacyPlan(blocks: [block]), take: take))
        #expect(layout.tracks.map(\.track) == [.ruler, .video, .zoom, .privacy, .camera, .audio(id: "mic")])
        #expect(layout.tracks[3] == TimelineRow(track: .privacy, height: 28))
        #expect(!TimelineLayout(take: take, document: .legacy(take: take, events: [])).tracks.map(\.track).contains(.privacy))
    }

    @Test func phase1RowsAreUnchanged() {
        let take = Self.fullTake()
        let layout = TimelineLayout(take: take, document: .legacy(take: take, events: []))
        #expect(layout.tracks.map(\.track) == [.ruler, .video, .zoom, .camera, .audio(id: "mic")])
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

extension TimelineLayoutTests {
    /// The bench's hour: 500 clips of 7 s of source with 0.2 s cut between them, one in ten at 2×, from host 1 s.
    private static func hour() -> [Clip] {
        (0..<500).map { i in
            let start = UInt64(1_000_000_000) + UInt64(i) * 7_200_000_000
            return Clip(
                id: "c-" + String(format: "%08x", i), take: "take-001", start: HostTime(nanoseconds: start),
                end: HostTime(nanoseconds: start + 7_000_000_000), speed: i % 10 == 3 ? 2 : 1)
        }
    }

    /// The tiles in sight of `sequence` at `scale` with the middle of the output at the middle of a 1352 pt area, as the
    /// pairs (clip, source) they show.
    private static func shown(_ sequence: [Clip], scale: Double, middle: Double) -> Set<String> {
        let map = TimeMap(sequence: sequence)
        let offset = middle * scale - 676
        let lower = Int64(offset / scale * 1e9), upper = Int64((offset + 1352) / scale * 1e9)
        let tiles = TimelineLayout.thumbnailTiles(
            sequence: sequence, map: map, visible: lower..<upper, scale: scale, tileWidth: 80, minimumWidth: 16)
        return Set(tiles.map { "\(sequence[$0.clip].id) \($0.source.nanoseconds)" })
    }

    @Test func fitAnchorKeepsBothEnds() {
        let layout = Self.layout([Self.track("display-1", .display)])
        let (duration, width) = (3465.0, 1352.0)
        let fit = TimelineLayout.fitScale(duration: duration, width: width)
        for (scale, offset) in [(60.0, 70_000.0), (600.0, 2_077_000.0), (fit * 1.5, 100.0), (4.0, 0.0)] {
            let τ = TimelineLayout.fitAnchor(scale: scale, offset: offset, duration: duration, width: width)
            // The instant is where it is now and where it is fitted: scaling around it starts at this view and ends fitted.
            let now = layout.x(ofOutput: τ, scale: scale, offset: offset), fitted = layout.x(ofOutput: τ, scale: fit, offset: 0)
            #expect(abs(now - fitted) < 1e-6, "scale \(scale), offset \(offset)")
            let start = Double(τ) * scale / 1e9 - (fitted - TimelineLayout.headerWidth)
            let end = Double(τ) * fit / 1e9 - (fitted - TimelineLayout.headerWidth)
            #expect(abs(start - offset) < 1e-6 && abs(end) < 1e-9)
            #expect(τ >= 0 && Double(τ) <= duration * 1e9)
        }
        // Already fitted, or closer than it can be: the start.
        #expect(TimelineLayout.fitAnchor(scale: fit, offset: 0, duration: duration, width: width) == 0)
        #expect(TimelineLayout.fitAnchor(scale: 600, offset: 0, duration: 1, width: width) == 0)
    }

    @Test func thumbnailTilesFollowTheirClip() {
        let sequence = Self.hour()
        let map = TimeMap(sequence: sequence)
        let tiles = TimelineLayout.thumbnailTiles(
            sequence: sequence, map: map, visible: 0..<map.duration, scale: 10, tileWidth: 80, minimumWidth: 16)
        // Each clip's tiles start at the clip, a power of two of nanoseconds apart (40 to 80 pt), never past its end, and
        // show its own source.
        let step = Int64(1) << 32
        #expect(Double(step) * 10 / 1e9 > 40 && Double(step) * 10 / 1e9 <= 80)
        for tile in tiles {
            let start = map.clipOutputStarts[tile.clip], clip = sequence[tile.clip]
            let end = start + TimeMap.outputDuration(of: clip)
            #expect(tile.output == start + Int64(tile.index) * step)
            #expect(tile.end == min(tile.output + step, end))
            #expect(tile.source >= clip.start && tile.source < clip.end)
            #expect(Double(tile.end - tile.output) * 10 / 1e9 >= 16)
        }
        // The 2× clip: two tiles' worth of source per tile.
        let fast = tiles.filter { $0.clip == 3 }
        #expect(fast.map { $0.source.nanoseconds - sequence[3].start.nanoseconds } == fast.map { UInt64($0.index) * 2 * UInt64(step) })
    }

    @Test func aSmallScaleStepKeepsTheThumbnails() {
        let sequence = Self.hour()
        for scale in [3.9, 10.0, 60.0, 300.0] {
            let before = Self.shown(sequence, scale: scale, middle: 1700), after = Self.shown(sequence, scale: scale * 1.02, middle: 1700)
            #expect(!after.isEmpty)
            // Within the octave the grid stays: only the tiles at the edges come and go.
            #expect(Double(after.intersection(before).count) >= 0.8 * Double(after.count), "\(scale) pt/s")
        }
    }

    @Test func aCutBeforeTheViewKeepsTheThumbnailsAfterIt() {
        let sequence = Self.hour()
        var cut = sequence
        cut.remove(at: 10)
        for scale in [10.0, 60.0] {
            let map = TimeMap(sequence: sequence), cutMap = TimeMap(sequence: cut)
            let all = TimelineLayout.thumbnailTiles(
                sequence: sequence, map: map, visible: 0..<map.duration, scale: scale, tileWidth: 80, minimumWidth: 16)
            let after = TimelineLayout.thumbnailTiles(
                sequence: cut, map: cutMap, visible: 0..<cutMap.duration, scale: scale, tileWidth: 80, minimumWidth: 16)
            // Every clip after the cut has the same tiles, moved with it.
            func tiles(_ list: [TimelineLayout.ThumbnailTile], _ clips: [Clip], from first: Int) -> [String] {
                list.filter { $0.clip >= first }.map { "\(clips[$0.clip].id) \($0.index) \($0.source.nanoseconds)" }
            }
            #expect(tiles(all, sequence, from: 11) == tiles(after, cut, from: 10))
            #expect(!tiles(after, cut, from: 10).isEmpty)
        }
    }

    @Test func clipsNarrowerThanATileOfMinimumWidthShowNone() {
        let sequence = Self.hour()
        let map = TimeMap(sequence: sequence)
        let fit = TimelineLayout.fitScale(duration: map.durationSeconds, width: 1352)
        // Fitted, the clips are under 3 pt wide: no thumbnail.
        #expect(TimelineLayout.thumbnailTiles(
            sequence: sequence, map: map, visible: 0..<map.duration, scale: fit, tileWidth: 80, minimumWidth: 16).isEmpty)
        // Out of sight, none either.
        #expect(TimelineLayout.thumbnailTiles(
            sequence: sequence, map: map, visible: map.duration..<(map.duration + 1), scale: 60, tileWidth: 80, minimumWidth: 16).isEmpty)
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
