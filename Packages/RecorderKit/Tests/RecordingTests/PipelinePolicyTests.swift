// SPDX-License-Identifier: GPL-3.0-or-later
import ProjectFormat
import Testing

@testable import Recording

/// The rules a track's pipeline follows, without a pipeline, a source or time passing.
@Suite struct PipelinePolicyTests {
    @Test func restartPolicyWalksTheBackoffThenGivesUp() {
        var p = RestartPolicy(backoff: [.milliseconds(500), .seconds(1)], keepsRetrying: false)
        #expect([p.next(), p.next(), p.next()] == [.wait(.milliseconds(500)), .wait(.seconds(1)), .giveUp])
        #expect(p.next() == .giveUp)
    }

    @Test func restartPolicyKeepsRetryingAtTheLastInterval() {
        var p = RestartPolicy(backoff: [.milliseconds(500), .seconds(1)], keepsRetrying: true)
        #expect([p.next(), p.next(), p.next(), p.next()] == [
            .wait(.milliseconds(500)), .wait(.seconds(1)), .warnPausedThenWait(.seconds(1)), .wait(.seconds(1)),
        ])
    }

    @Test func restartPolicyWithoutBackoffWaitsOneSecond() {
        var keeps = RestartPolicy(backoff: [], keepsRetrying: true)
        #expect([keeps.next(), keeps.next()] == [.warnPausedThenWait(.seconds(1)), .wait(.seconds(1))])
        var gives = RestartPolicy(backoff: [], keepsRetrying: false)
        #expect(gives.next() == .giveUp)
    }

    @Test(arguments: [(TrackKind.display, true, true), (.display, false, false), (.microphone, false, true)])
    func keepsRetryingByKind(kind: TrackKind, sole: Bool, expected: Bool) {
        #expect(RestartPolicy.keepsRetrying(kind: kind, isSoleScreen: sole) == expected)
    }

    @Test func writerBackoffWaitsOnlyAfterRepeatedEarlyFailures() {
        var b = WriterFailureBackoff(backoff: [.milliseconds(500), .seconds(1)])
        #expect(b.writerFailed(segmentSeconds: 0.2) == nil)
        #expect(b.writerFailed(segmentSeconds: nil) == .milliseconds(500))
        #expect(b.writerFailed(segmentSeconds: 0.9) == .seconds(1))
        #expect(b.writerFailed(segmentSeconds: 0) == .seconds(1))
        // A writer that ran for a while counts as the first failure again.
        #expect(b.writerFailed(segmentSeconds: 2) == nil)
        #expect(b.writerFailed(segmentSeconds: WriterFailureBackoff.healthySegmentSeconds) == nil)
        #expect(b.writerFailed(segmentSeconds: nil) == .milliseconds(500))
    }

    @Test func writerBackoffStartsOverAfterASegmentClosedNormally() {
        var b = WriterFailureBackoff(backoff: [.milliseconds(500)])
        _ = b.writerFailed(segmentSeconds: nil)
        #expect(b.writerFailed(segmentSeconds: nil) == .milliseconds(500))
        b.segmentClosedNormally()
        #expect(b.writerFailed(segmentSeconds: nil) == nil)
        var empty = WriterFailureBackoff(backoff: [])
        #expect([empty.writerFailed(segmentSeconds: nil), empty.writerFailed(segmentSeconds: nil)] == [nil, nil])
    }

    @Test func segmentAccountingWarnsAtThirtyInARow() {
        var a = SegmentAccounting()
        let first = (1...SegmentAccounting.warningCount + 1).filter { n in a.dropped(withOpenSegment: n.isMultiple(of: 2)) }
        #expect(first == [SegmentAccounting.warningCount])
        a.written()
        let again = (1...SegmentAccounting.warningCount).filter { _ in a.dropped(withOpenSegment: true) }
        #expect(again == [SegmentAccounting.warningCount])
    }

    @Test func segmentAccountingKeepsDropsWithoutASegmentForTheNextOne() {
        var a = SegmentAccounting()
        _ = a.dropped(withOpenSegment: true)  // counted by the open segment itself
        _ = a.dropped(withOpenSegment: false)
        _ = a.dropped(withOpenSegment: false)
        a.addPending(4)  // a segment that never started gave its drops back
        #expect(a.takePending() == 6)
        #expect(a.takePending() == 0)
    }

    @Test func audioClockAnchorsEveryFiveSeconds() {
        let start = HostTime(nanoseconds: 1_000_000_000_000)
        var anchors = AudioClockAnchors(segmentStart: start)
        let positions = [0, 4.9, 5.0, 9.9, 10.1].map { seconds in
            AudioFilePosition(frame: Int(seconds * 48_000), hostTime: start.adding(seconds: seconds))
        }
        let logged = positions.compactMap { anchors.anchor(for: $0) }
        #expect(logged == [positions[2], positions[4]])
        #expect(AudioClockAnchors.interval == 5)
    }

    @Test func audioClockAnchorsNeverNameFrameZero() {
        let start = HostTime(nanoseconds: 1_000_000_000_000)
        var anchors = AudioClockAnchors(segmentStart: start)
        #expect(anchors.anchor(for: AudioFilePosition(frame: 0, hostTime: start.adding(seconds: 6))) == nil)
        let next = AudioFilePosition(frame: 1, hostTime: start.adding(seconds: 6))
        #expect(anchors.anchor(for: next) == next)
    }
}
