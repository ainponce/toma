// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation

/// How long a take has recorded, in whole seconds: from `began` on, without the time it was paused.
public struct RecordedTime: Equatable, Sendable {
    private var start: Date?
    private var pausedSince: Date?
    private var pausedSeconds: TimeInterval = 0

    public init() {}

    /// The take records from `date`: the time counts from zero.
    public mutating func began(at date: Date) {
        start = date
        pausedSince = nil
        pausedSeconds = 0
    }

    /// Nothing is recorded from `date` until `resumed`. Ignored before `began` and while paused.
    public mutating func paused(at date: Date) {
        guard start != nil, pausedSince == nil else { return }
        pausedSince = date
    }

    /// The take records again from `date`. Ignored unless paused.
    public mutating func resumed(at date: Date) {
        guard let pausedSince else { return }
        pausedSeconds += max(0, date.timeIntervalSince(pausedSince))
        self.pausedSince = nil
    }

    /// The time recorded by `date`, rounded down to whole seconds; zero before `began`.
    public func elapsed(at date: Date) -> Duration {
        guard let start else { return .zero }
        let end = pausedSince.map { min($0, date) } ?? date
        return .seconds(Int(max(0, end.timeIntervalSince(start) - pausedSeconds)))
    }
}
