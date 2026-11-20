// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import Testing
// Not @testable: the Replay uses only the public API.
import ProjectFormat

// Milestone 5c, Task R1 (fases 4 y 5 design §10.3, plan decisions 6 and 8): which segments of the working take a save
// keeps, how they are renumbered, and the manifest of the saved project.

private let origin = HostTime(nanoseconds: 5_000_000_000_000)
private let testApp = AppInfo(name: "Toma", version: "0.5.0")

/// `seconds` after `origin`.
private func at(_ seconds: Double) -> HostTime { origin.adding(seconds: seconds) }

/// Segment `index` of `track` in the working take, closed at `to` unless it is `nil`.
private func segment(
    _ track: String, _ index: Int, _ from: Double, _ to: Double?, _ reason: SegmentEndReason? = .rotated
) -> SegmentRecord {
    SegmentRecord(
        index: index, file: "takes/\(ReplayScratch.takeID)/\(track)/seg-" + String(format: "%04d", index) + ".mov",
        startHostTime: at(from), endHostTime: to.map(at), endReason: to == nil ? nil : reason, droppedFrames: index,
        heartbeatFrames: 2 * index)
}

/// `track` with one segment per pair of consecutive `edges`, numbered from `first`, every one `rotated`.
private func track(_ id: String, _ kind: TrackKind, edges: [Double], first: Int = 1) -> TrackRecord {
    TrackRecord(
        id: id, kind: kind, source: TrackSource(name: id),
        segments: zip(edges, edges.dropFirst()).enumerated().map { offset, span in
            segment(id, first + offset, span.0, span.1)
        })
}

private func take(_ tracks: [TrackRecord]) -> TakeRecord {
    TakeRecord(id: ReplayScratch.takeID, status: .recording, startedAt: Date(timeIntervalSince1970: 1_800_000_000), tracks: tracks)
}

private func savedFile(_ track: String, _ index: Int) -> String {
    "takes/take-001/\(track)/seg-" + String(format: "%04d", index) + ".mov"
}

@Suite struct ReplayCutTests {
    @Test func cutKeepsTheSegmentAcrossTheCut() throws {
        let cut = try ReplayCut.make(
            take: take([track("display-1", .display, edges: [0, 10, 20, 25])]), seconds: 12, takeID: "take-001")

        #expect(cut.cut == at(13))
        #expect(cut.start == at(10))
        #expect(cut.end == at(25))
        let display = try #require(cut.tracks.first)
        #expect(display.segments.map(\.index) == [1, 2])
        #expect(display.segments.map(\.startHostTime) == [at(10), at(20)])
        #expect(display.segments.map(\.endHostTime) == [at(20), at(25)])
        #expect(cut.files == [
            ReplayCut.FileCopy(from: savedFile("display-1", 2), to: savedFile("display-1", 1)),
            ReplayCut.FileCopy(from: savedFile("display-1", 3), to: savedFile("display-1", 2)),
        ])
        #expect(cut.renumbered == ["display-1": [2: 1, 3: 2]])
        // What the segment record says of itself goes with it.
        #expect(display.segments.map(\.droppedFrames) == [2, 3])
        #expect(display.segments.map(\.heartbeatFrames) == [4, 6])
    }

    @Test func audioRotatedElsewhereKeepsItsOwnCover() throws {
        let cut = try ReplayCut.make(
            take: take([
                track("display-1", .display, edges: [0, 10, 20, 25]),
                track("mic", .microphone, edges: [0, 9.98, 19.97, 25.01]),
            ]),
            seconds: 12, takeID: "take-001")

        #expect(cut.cut == at(13))
        // The first segment kept, of any track, is where the events start.
        #expect(cut.start == at(9.98))
        #expect(cut.end == at(25))
        let mic = try #require(cut.tracks.first { $0.id == "mic" })
        #expect(mic.segments.map(\.startHostTime) == [at(9.98), at(19.97)])
        #expect(mic.segments.map(\.endHostTime) == [at(19.97), at(25.01)])
        #expect(cut.renumbered["mic"] == [2: 1, 3: 2])
    }

    @Test func trackThatStartedLateKeepsWhatItHas() throws {
        let cut = try ReplayCut.make(
            take: take([
                track("display-1", .display, edges: [0, 10, 20, 25]),
                track("camera", .camera, edges: [21, 25]),
            ]),
            seconds: 12, takeID: "take-001")

        let camera = try #require(cut.tracks.first { $0.id == "camera" })
        #expect(camera.segments.map(\.startHostTime) == [at(21)])
        #expect(camera.segments.map(\.file) == [savedFile("camera", 1)])
        #expect(cut.renumbered["camera"] == [1: 1])
        #expect(cut.start == at(10))
    }

    @Test func trackWithNothingAfterTheCutIsLeftOut() throws {
        var systemAudio = track("system-audio", .systemAudio, edges: [0, 10, 12])
        systemAudio.segments[1].endReason = .streamError(domain: "SCStreamErrorDomain", code: -3821)
        let cut = try ReplayCut.make(
            take: take([track("display-1", .display, edges: [0, 10, 20, 25]), systemAudio]), seconds: 12, takeID: "take-001")

        #expect(cut.tracks.map(\.id) == ["display-1"])
        #expect(cut.renumbered["system-audio"] == nil)
        #expect(!cut.files.contains { $0.from.contains("system-audio") })
    }

    @Test func lessThanNSavesWhatThereIs() throws {
        let cut = try ReplayCut.make(
            take: take([
                track("display-1", .display, edges: [2, 10, 14]),
                track("mic", .microphone, edges: [1.5, 10, 14.2]),
            ]),
            seconds: 30, takeID: "take-001")

        #expect(cut.cut == at(2))
        #expect(cut.start == at(1.5))
        #expect(cut.end == at(14))
        #expect(cut.tracks.map { $0.segments.count } == [2, 2])
    }

    @Test func theScreenEndsAtTheLatestOfItsTracks() throws {
        let cut = try ReplayCut.make(
            take: take([
                track("display-1", .display, edges: [0, 10, 20, 24]),
                track("display-2", .display, edges: [0, 10, 20, 25]),
            ]),
            seconds: 12, takeID: "take-001")
        #expect(cut.end == at(25))
        #expect(cut.cut == at(13))
    }

    @Test func rotatedBecomesStoppedAndOtherReasonsStay() throws {
        var display = track("display-1", .display, edges: [0, 10, 20, 25, 30])
        display.segments[2].endReason = .formatChanged
        display.segments[3].endReason = .streamError(domain: "SCStreamErrorDomain", code: -3821)
        let cut = try ReplayCut.make(take: take([display]), seconds: 15, takeID: "take-001")

        #expect(cut.tracks[0].segments.map(\.endReason) == [.stopped, .formatChanged, .streamError(domain: "SCStreamErrorDomain", code: -3821)])
    }

    @Test func filesAreRenumberedFromOne() throws {
        // A take whose first segments were pruned already: its tracks start at 7 and 6.
        let cut = try ReplayCut.make(
            take: take([
                track("display-1", .display, edges: [60, 70, 80, 85], first: 7),
                track("mic", .microphone, edges: [59.9, 69.9, 79.9, 85.1], first: 6),
            ]),
            seconds: 12, takeID: "take-001")

        #expect(cut.tracks.map { $0.segments.map(\.index) } == [[1, 2], [1, 2]])
        #expect(cut.tracks.flatMap { $0.segments.map(\.file) } == [
            savedFile("display-1", 1), savedFile("display-1", 2), savedFile("mic", 1), savedFile("mic", 2),
        ])
        #expect(cut.files.map(\.from) == [
            savedFile("display-1", 8), savedFile("display-1", 9), savedFile("mic", 7), savedFile("mic", 8),
        ])
        #expect(cut.renumbered == ["display-1": [8: 1, 9: 2], "mic": [7: 1, 8: 2]])
    }

    @Test func openSegmentsAndOnesAfterTheEndAreLeftOut() throws {
        var display = track("display-1", .display, edges: [0, 10, 20])
        display.segments.append(segment("display-1", 3, 20, nil))
        // The microphone rotated on its own after the screen's last frame, and its new segment closed later still.
        let mic = track("mic", .microphone, edges: [0, 10, 20.5, 21])
        let cut = try ReplayCut.make(take: take([display, mic]), seconds: 8, takeID: "take-001")

        #expect(cut.end == at(20))
        #expect(cut.tracks[0].segments.map(\.startHostTime) == [at(10)])
        #expect(cut.tracks[1].segments.map(\.startHostTime) == [at(10)])
        #expect(cut.files.count == 2)
    }

    @Test func noScreenSegmentIsNoScreen() throws {
        #expect(throws: ReplayError.noScreen) {
            try ReplayCut.make(take: take([track("mic", .microphone, edges: [0, 10])]), seconds: 30, takeID: "take-001")
        }
        var display = track("display-1", .display, edges: [])
        display.segments = [segment("display-1", 1, 0, nil)]
        #expect(throws: ReplayError.noScreen) {
            try ReplayCut.make(take: take([display, track("mic", .microphone, edges: [0, 10])]), seconds: 30, takeID: "take-001")
        }
    }

    @Test func savedTakeValidatesItsPaths() throws {
        let cut = try ReplayCut.make(
            take: take([
                track("display-1", .display, edges: [0, 10, 20, 25]),
                track("camera", .camera, edges: [0, 10, 20, 25]),
                track("system-audio-com-apple-Safari", .systemAudio, edges: [0, 10, 20, 25]),
            ]),
            seconds: 12, takeID: "take-001")
        let manifest = ReplayManifest.make(
            cut: cut, events: [], cameraStyle: nil, takeID: "take-001", app: testApp, now: Date(), projectID: ProjectID.random())
        try manifest.validatePaths()
        #expect(manifest.takes.map(\.tracks.count) == [3])
    }

    // MARK: - ReplayManifest

    @Test func savedManifestHasNoRotated() throws {
        let cut = try ReplayCut.make(
            take: take([
                track("display-1", .display, edges: [0, 10, 20, 25]),
                track("mic", .microphone, edges: [0, 9.98, 19.97, 25.01]),
            ]),
            seconds: 12, takeID: "take-001")
        let manifest = ReplayManifest.make(
            cut: cut, events: [], cameraStyle: nil, takeID: "take-001", app: testApp, now: Date(), projectID: ProjectID.random())
        let json = String(decoding: try ProjectJSON.encoder().encode(manifest), as: UTF8.self)

        #expect(!json.contains("rotated"))
        #expect(manifest.takes.count == 1)
        #expect(manifest.takes[0].status == .complete)
        #expect(manifest.takes[0].id == "take-001")
        #expect(manifest.formatVersion == 3)
        #expect(manifest.upgradedFrom == nil)
    }

    @Test func keysOrAnIPhoneMakeItVersion4() throws {
        let screen = take([track("display-1", .display, edges: [0, 10])])
        let cut = try ReplayCut.make(take: screen, seconds: 30, takeID: "take-001")
        let key = InputEvent(t: at(3), kind: .keyPress(code: 0, chars: "a", mods: 0, isRepeat: false))
        func version(_ cut: ReplayCut, _ events: [InputEvent]) -> Int {
            ReplayManifest.make(
                cut: cut, events: events, cameraStyle: nil, takeID: "take-001", app: testApp, now: Date(),
                projectID: ProjectID.random()
            ).formatVersion
        }

        #expect(version(cut, [InputEvent(t: at(3), kind: .keyActivity)]) == 3)
        #expect(version(cut, [key]) == 4)
        let device = try ReplayCut.make(
            take: take([track("device-1", .device, edges: [0, 10]), track("device-audio-1", .deviceAudio, edges: [0, 10])]),
            seconds: 30, takeID: "take-001")
        #expect(version(device, []) == 4)
    }

    @Test func startedAtIsNowMinusTheSpan() throws {
        let cut = try ReplayCut.make(
            take: take([track("display-1", .display, edges: [0, 10, 20, 25]), track("camera", .camera, edges: [0, 10, 20, 25])]),
            seconds: 12, takeID: "take-001")
        let now = Date(timeIntervalSince1970: 1_800_000_100.7)
        let projectID = ProjectID.random()
        let style = CameraStyle(shape: .landscape, size: CameraStyle.small, anchor: .topLeading)
        let manifest = ReplayManifest.make(
            cut: cut, events: [], cameraStyle: style, takeID: "take-001", app: testApp, now: now, projectID: projectID)

        // 15 s from the first segment kept to the screen's end, in whole seconds.
        #expect(cut.end.seconds(since: cut.start) == 15)
        #expect(manifest.takes[0].startedAt == Date(timeIntervalSince1970: 1_800_000_085))
        #expect(manifest.createdAt == Date(timeIntervalSince1970: 1_800_000_100))
        #expect(manifest.projectID == projectID)
        #expect(manifest.app == testApp)
        #expect(manifest.takes[0].cameraStyle == style)
    }

    @Test func aTakeWithoutACameraHasNoCameraStyle() throws {
        let cut = try ReplayCut.make(
            take: take([track("display-1", .display, edges: [0, 10])]), seconds: 30, takeID: "take-001")
        let manifest = ReplayManifest.make(
            cut: cut, events: [], cameraStyle: .default, takeID: "take-001", app: testApp, now: Date(),
            projectID: ProjectID.random())
        #expect(manifest.takes[0].cameraStyle == nil)
    }
}
