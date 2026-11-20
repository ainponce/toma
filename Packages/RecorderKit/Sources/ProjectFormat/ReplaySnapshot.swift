// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation

/// Why the Replay could not do what it was asked.
public enum ReplayError: Error, Equatable, Sendable {
    /// It is recording already.
    case alreadyStarted
    /// The working package's `recording.lock` is held: another Replay records into it.
    case scratchInUse
    /// It is not recording.
    case notRunning
    /// There is nothing to save yet: no segment of the screen closed.
    case nothingToSave
    /// The take has no closed segment of a screen (`TrackKind.isScreen`), which a saved Replay needs.
    case noScreen
}

/// The working take as a save sees it, frozen (fases 4 y 5 design §10.3): every track rotated, nothing pruned until
/// `ReplaySource.thaw()`.
public struct ReplaySnapshot: Equatable, Sendable {
    /// The working package (`ReplayScratch`).
    public var package: ProjectPackage
    /// Only the segments closed by the rotation that froze it, and before; the ones it opened are left out.
    public var take: TakeRecord
    /// The working manifest's version: 3, or 4 with key presses.
    public var formatVersion: Int
    /// The event files left (`ReplayScratch.shardURL(of:index:)`), in order.
    public var shards: [URL]
    /// The state of the event files pruned already (`ReplayEventState.events`).
    public var carried: [InputEvent]

    public init(package: ProjectPackage, take: TakeRecord, formatVersion: Int, shards: [URL], carried: [InputEvent]) {
        self.package = package
        self.take = take
        self.formatVersion = formatVersion
        self.shards = shards
        self.carried = carried
    }
}

/// What records the Replay, as a save asks it.
public protocol ReplaySource: Sendable {
    /// Rotates every track and the event log, stops pruning and returns what is on disk. Throws
    /// `ReplayError.nothingToSave` when no segment of the screen closed yet, and `notRunning` when it is not recording.
    func freeze() async throws -> ReplaySnapshot
    /// Prunes again, after a save.
    func thaw() async
}
