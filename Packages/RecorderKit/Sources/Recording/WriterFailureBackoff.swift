// SPDX-License-Identifier: GPL-3.0-or-later

/// How long a track waits before opening a new segment after its writer failed. The next sample opens one
/// at once after a writer that ran fine for a while; writers that keep failing early, or cannot be created,
/// wait `backoff[n]` between attempts (its last entry from then on), so a broken writer does not spin out a
/// file per sample.
struct WriterFailureBackoff: Equatable, Sendable {
    /// A segment that lasted at least this long before its writer failed does not count towards the backoff.
    static let healthySegmentSeconds = 1.0

    private let backoff: [Duration]
    /// Writers in a row that failed early or could not be created.
    private var failures = 0

    init(backoff: [Duration]) {
        self.backoff = backoff
    }

    /// A writer failed after its segment held `segmentSeconds` of media (`nil`: it never started, or could
    /// not be created). Returns how long to wait before opening the next segment, `nil` for the next sample.
    mutating func writerFailed(segmentSeconds: Double?) -> Duration? {
        let healthy = (segmentSeconds ?? 0) >= Self.healthySegmentSeconds
        failures = healthy ? 1 : failures + 1
        guard failures > 1, !backoff.isEmpty else { return nil }
        return backoff[min(failures - 2, backoff.count - 1)]
    }

    /// A segment that started was closed without its writer failing: the next failure is a first one.
    mutating func segmentClosedNormally() {
        failures = 0
    }
}
