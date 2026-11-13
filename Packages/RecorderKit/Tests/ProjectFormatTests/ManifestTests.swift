// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import Testing
@testable import ProjectFormat

extension Manifest {
    /// One take with a display track (a closed segment and an open one) and a microphone track.
    static let fixture = Manifest(
        formatVersion: Manifest.currentFormatVersion,
        app: AppInfo(name: "Toma", version: "0.1.0"),
        createdAt: Date(timeIntervalSince1970: 1_700_000_000),
        takes: [
            TakeRecord(
                id: "take-001",
                status: .recording,
                startedAt: Date(timeIntervalSince1970: 1_700_000_005),
                tracks: [
                    TrackRecord(
                        id: "display-1",
                        kind: .display,
                        source: TrackSource(
                            name: "Built-in Retina Display",
                            displayID: 1,
                            globalFrame: Rect(x: 0, y: 0, width: 1512, height: 982),
                            pixelScale: 2
                        ),
                        segments: [
                            SegmentRecord(
                                index: 1,
                                file: "takes/take-001/display-1/seg-0001.mov",
                                startHostTime: HostTime(nanoseconds: 5_000_000_000),
                                endHostTime: HostTime(nanoseconds: 9_500_000_000),
                                endReason: .streamError(domain: "SCStreamErrorDomain", code: -3821),
                                droppedFrames: 2,
                                heartbeatFrames: 7
                            ),
                            SegmentRecord(
                                index: 2,
                                file: "takes/take-001/display-1/seg-0002.mov",
                                startHostTime: HostTime(nanoseconds: 9_700_000_000),
                                droppedFrames: 0,
                                heartbeatFrames: 0
                            ),
                        ]
                    ),
                    TrackRecord(
                        id: "mic",
                        kind: .microphone,
                        source: TrackSource(name: "MacBook Pro Microphone", deviceUniqueID: "BuiltInMicrophoneDevice"),
                        segments: [
                            SegmentRecord(
                                index: 1,
                                file: "takes/take-001/mic/seg-0001.mov",
                                startHostTime: HostTime(nanoseconds: 5_000_000_000),
                                droppedFrames: 0,
                                heartbeatFrames: 0
                            ),
                        ]
                    ),
                ]
            ),
        ]
    )
}

@Test func manifestRoundTrips() throws {
    let manifest = Manifest.fixture
    let data = try ProjectJSON.encoder().encode(manifest)
    let decoded = try ProjectJSON.decoder().decode(Manifest.self, from: data)
    #expect(decoded == manifest)
    #expect(decoded.takes[0].tracks[0].segments[1].endHostTime == nil)
    #expect(decoded.takes[0].tracks[0].segments[0].endReason == .streamError(domain: "SCStreamErrorDomain", code: -3821))
}

@Test func endReasonUsesFlatTypeField() throws {
    let json = String(decoding: try ProjectJSON.encoder().encode(SegmentEndReason.unreadable(bytes: 10)), as: UTF8.self)
    #expect(json.contains("\"type\" : \"unreadable\"") && json.contains("\"bytes\" : 10"))
}

@Test func streamErrorEncodesDomainAndCodeNextToType() throws {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    let json = String(decoding: try encoder.encode(SegmentEndReason.streamError(domain: "SCStreamErrorDomain", code: -3821)), as: UTF8.self)
    #expect(json == #"{"code":-3821,"domain":"SCStreamErrorDomain","type":"streamError"}"#)
}

@Test(arguments: [
    SegmentEndReason.stopped, .paused, .streamError(domain: "SCStreamErrorDomain", code: -3821),
    .writerError(domain: "AVFoundationErrorDomain", code: -11800), .formatChanged, .diskFull,
    .recoveredAfterCrash, .empty, .unreadable(bytes: 2_097_152),
])
func everyEndReasonRoundTrips(reason: SegmentEndReason) throws {
    let data = try ProjectJSON.encoder().encode(reason)
    #expect(try ProjectJSON.decoder().decode(SegmentEndReason.self, from: data) == reason)
}

@Test func unknownEndReasonTypeFailsToDecode() {
    #expect(throws: DecodingError.self) {
        try ProjectJSON.decoder().decode(SegmentEndReason.self, from: Data(#"{"type":"exploded"}"#.utf8))
    }
}

@Test func datesAreISO8601AndPathsKeepTheirSlashes() throws {
    let json = String(decoding: try ProjectJSON.encoder().encode(Manifest.fixture), as: UTF8.self)
    #expect(json.contains("\"createdAt\" : \"2023-11-14T22:13:20Z\""))
    #expect(json.contains("\"file\" : \"takes/take-001/display-1/seg-0001.mov\""))
}

@Test func takeFindsTrackByID() {
    let take = Manifest.fixture.takes[0]
    #expect(take.track("mic")?.kind == .microphone)
    #expect(take.track("camera") == nil)
}
