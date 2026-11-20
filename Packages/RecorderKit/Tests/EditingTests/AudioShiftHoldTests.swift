// SPDX-License-Identifier: GPL-3.0-or-later
@testable import Editing
import Foundation
import ProjectFormat
import Testing

/// The commands that move a clip in its take hold the cuts of the sound to what each take has, as the mix does (phase 3
/// design §7.3, `SequenceRules.audioShift(of:at:takeBounds:)`): the document they write, `TimeMap.audioStarts` and what
/// the mix hears are the same cut.
@Suite struct AudioShiftHoldTests {
    /// A = [0, 1) s and B = [1, 5) s at 1×, B heard 0.5 s sooner: at 4×, B heard 0.5 s sooner would read 2 s before its
    /// start, 1 s before its take's: the speed holds the J cut to 0.25 s, and the map puts its sound there.
    @Test func aFasterClipHoldsItsJCutToItsTake() throws {
        var document = Self.document([("take-001", 0, 1), ("take-001", 1, 5)])
        document.sequence[1].audioShift = -500_000_000
        let step = try #require(SequenceCommands.setSpeed(document, clipIDs: ["c-00000002"], speed: 4, takeBounds: Self.bounds))
        let faster = try document.applying(step.changes)
        #expect(faster.sequence[1].speed == 4 && faster.sequence[1].audioShift == -250_000_000)
        #expect(TimeMap(sequence: faster.sequence).audioStarts[1] == 750_000_000)
        #expect(SequenceRules.audioShift(of: faster.sequence, at: 1, takeBounds: Self.bounds) == -250_000_000, "as the mix holds it")
        // Held to the clips alone, as before, it would keep 0.5 s, which the mix never hears.
        let unheld = try document.applying(
            try #require(SequenceCommands.setSpeed(document, clipIDs: ["c-00000002"], speed: 4, takeBounds: [:])).changes)
        #expect(unheld.sequence[1].audioShift == -500_000_000)
    }

    /// A trim of a clip's start back towards its take's start holds its J cut to what is left before it.
    @Test func aTrimHoldsTheJCutToItsTake() throws {
        var document = Self.document([("take-002", 0, 1), ("take-001", 2, 3)])
        document.sequence[1].audioShift = -400_000_000
        let step = try #require(SequenceCommands.trim(
            document, clipID: "c-00000002", edge: .start, toSource: Self.at(0.2), limits: Self.at(0)...Self.at(2.9),
            takeBounds: Self.bounds))
        let trimmed = try document.applying(step.changes)
        #expect(trimmed.sequence[1].start == Self.at(0.2) && trimmed.sequence[1].audioShift == -200_000_000)
        #expect(TimeMap(sequence: trimmed.sequence).audioStarts[1] == 1_000_000_000 - 200_000_000)
    }

    /// A clip deleted gives the one after it another clip before: an L cut that clip cannot be heard on with, as it ends
    /// at its take's end, is held to none.
    @Test func aDeletionHoldsTheLCutToTheClipBefore() throws {
        var document = Self.document([("take-002", 3, 4), ("take-001", 0, 1), ("take-001", 2, 3)])
        document.sequence[2].audioShift = 400_000_000
        let step = try SequenceCommands.delete(document, clipIDs: ["c-00000002"], takeBounds: Self.bounds).get()
        let deleted = try document.applying(step.changes)
        #expect(deleted.sequence.map(\.id) == ["c-00000001", "c-00000003"] && deleted.sequence[1].audioShift == 0)
        #expect(TimeMap(sequence: deleted.sequence).audioStarts == TimeMap(sequence: deleted.sequence).clipOutputStarts)
    }

    // MARK: - Fixtures

    /// Both takes start at `start`; `take-001` lasts 5 s and `take-002` 4 s.
    private static let start = HostTime(nanoseconds: 5_000_000_000_000)
    private static let bounds: [String: ClosedRange<HostTime>] = [
        "take-001": start...start.adding(seconds: 5), "take-002": start...start.adding(seconds: 4),
    ]

    private static func at(_ seconds: Double) -> HostTime { start.adding(seconds: seconds) }

    /// A document whose sequence is `pieces` (take, from, to in seconds of its take) at 1×, with the ids `c-00000001`…
    private static func document(_ pieces: [(String, Double, Double)]) -> EditDocument {
        var document = EditDocument.legacy(
            take: TakeRecord(id: "take-001", status: .complete, startedAt: Date(timeIntervalSince1970: 0), tracks: []), events: [])
        document.sequence = pieces.enumerated().map { k, piece in
            Clip(id: String(format: "c-%08x", k + 1), take: piece.0, start: at(piece.1), end: at(piece.2), speed: 1)
        }
        return document
    }
}
