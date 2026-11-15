// SPDX-License-Identifier: GPL-3.0-or-later

/// A track's count of the samples it could not write: the run of them in a row, for `samplesDropped`, and
/// the ones no segment could take, which the next segment counts. Those of the open segment are counted by
/// the segment itself.
struct SegmentAccounting: Equatable, Sendable {
    /// Samples dropped in a row after which `samplesDropped` is sent.
    static let warningCount = 30

    /// Dropped while no segment could take them.
    private var pending = 0
    private var inARow = 0

    /// Counts a sample that was not written: by the open segment if it refused it (`withOpenSegment`),
    /// otherwise as pending. Returns `true` exactly when the run in a row reaches `warningCount`.
    mutating func dropped(withOpenSegment: Bool) -> Bool {
        if !withOpenSegment { pending += 1 }
        inARow += 1
        return inARow == Self.warningCount
    }

    /// A sample was written: the run in a row ends.
    mutating func written() {
        inARow = 0
    }

    /// The pending drops, for the segment that takes them; none are left pending.
    mutating func takePending() -> Int {
        defer { pending = 0 }
        return pending
    }

    /// The drops of a segment that never started go back to pending.
    mutating func addPending(_ count: Int) {
        pending += count
    }
}
