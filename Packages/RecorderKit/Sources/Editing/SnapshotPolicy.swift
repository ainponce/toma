// SPDX-License-Identifier: GPL-3.0-or-later

/// When the session rewrites `edit.json` (design §6.5): `idleDelay` after the last change, every `everyEntries`
/// entries, and at closing, which the session does whatever this says. The snapshot only saves replaying: the log is
/// the truth, so one that comes late loses nothing. Whatever is due, an `edit.json` with `logSequence` N is written
/// only once the journal confirmed the line N on disk (plan decision 20).
public struct SnapshotPolicy: Equatable, Sendable {
    public static let idleDelay: Duration = .seconds(2)
    public static let everyEntries = 200

    /// The entries of the log after the one the last snapshot includes.
    public var entriesSinceSnapshot: Int
    /// When the last of them was made; `nil` if none was.
    public var lastChange: ContinuousClock.Instant?

    public init(entriesSinceSnapshot: Int, lastChange: ContinuousClock.Instant? = nil) {
        self.entriesSinceSnapshot = entriesSinceSnapshot
        self.lastChange = lastChange
    }

    /// Whether a snapshot is due at `now`: there are entries since the last one, and either `everyEntries` of them or
    /// `idleDelay` since the last.
    public func isDue(now: ContinuousClock.Instant) -> Bool {
        guard entriesSinceSnapshot > 0 else { return false }
        if entriesSinceSnapshot >= Self.everyEntries { return true }
        guard let lastChange else { return false }
        return lastChange.duration(to: now) >= Self.idleDelay
    }
}
