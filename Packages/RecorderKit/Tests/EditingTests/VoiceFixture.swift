// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import Testing
// Not @testable: the app uses only the public API.
import Analysis
import Editing
import ProjectFormat

/// The fixture of the voice commands' tests: a take of one display recorded for 20 s from `base`, and a document of one
/// clip over all of it at 1×, so an output second is a source second after `base`.
enum VoiceFixture {
    static let takeID = "take-001"
    static let base = HostTime(nanoseconds: 5_000_000_000_000)

    static func at(_ seconds: Double) -> HostTime { base.adding(seconds: seconds) }
    static func output(_ seconds: Double) -> Int64 { TimeMap.outputNanoseconds(seconds: seconds) }
    static func range(_ from: Double, _ to: Double) -> Range<Int64> { output(from)..<output(to) }

    static let take = TakeRecord(
        id: takeID, status: .complete, startedAt: Date(timeIntervalSince1970: 1_800_000_000),
        tracks: [
            TrackRecord(
                id: "display-1", kind: .display,
                source: TrackSource(name: "Display", displayID: 1, globalFrame: Rect(x: 0, y: 0, width: 1440, height: 900), pixelScale: 2),
                segments: [
                    SegmentRecord(
                        index: 1, file: "takes/take-001/display-1/seg-0001.mov", startHostTime: base, endHostTime: at(20),
                        endReason: .stopped, droppedFrames: 0, heartbeatFrames: 0)
                ])
        ])

    static let fullClip = [Clip(id: "c-00000001", take: takeID, start: base, end: at(20), speed: 1)]

    static func document(
        words: [(Double, Double)]? = nil, blocks: [LayoutBlock] = [], sequence: [Clip] = fullClip
    ) -> EditDocument {
        var document = EditDocument.legacy(take: take, events: [])
        document.sequence = sequence
        document.camera = CameraPlan(
            show: true, initial: [takeID: CameraStyle(shape: .circle, size: CameraStyle.medium, anchor: .bottomTrailing)],
            changes: [], layouts: blocks)
        if let words {
            document.transcript = Transcript(
                language: "es-MX", engine: "speechTranscriber-1",
                takes: [
                    TranscriptTake(
                        take: takeID, track: "mic-1",
                        words: words.enumerated().map {
                            TranscriptWord(start: at($1.0), end: at($1.1), text: "w\($0)")
                        })
                ])
        }
        return document
    }

    static func block(_ id: String, from: Double, to: Double, kind: LayoutKind = .cameraFull) -> LayoutBlock {
        LayoutBlock(id: id, take: takeID, start: at(from), end: at(to), kind: kind, instant: false)
    }

    static func timeMap(_ document: EditDocument) -> TimeMap { TimeMap(sequence: document.sequence) }

    static func applying(_ step: EditStep, to document: EditDocument) throws -> EditDocument {
        let edited = try document.applying(step.changes)
        #expect(try edited.applying(step.changes.reversed().map(\.inverse)) == document)
        return edited
    }

    /// `l-00000010`, `l-00000011`… as it is asked.
    final class IDs {
        private var next = 0x10

        func make(_ prefix: String) -> String {
            defer { next += 1 }
            return prefix + String(format: "%08x", next)
        }
    }
}
