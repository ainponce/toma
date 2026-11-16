// SPDX-License-Identifier: GPL-3.0-or-later
import Dispatch
import Foundation
import ProjectFormat
import Synchronization

/// Free space on a volume, in bytes.
public struct DiskCapacity: Sendable, Equatable {
    /// `volumeAvailableCapacityForImportantUsageKey`: counts purgeable space the system would free.
    public var importantUsage: Int64
    /// `volumeAvailableCapacityKey`: space that is free right now.
    public var available: Int64

    public init(importantUsage: Int64, available: Int64) {
        self.importantUsage = importantUsage
        self.available = available
    }
}

public enum DiskSpaceVerdict: Sendable, Equatable {
    case ok
    case warn(availableBytes: Int64)
    case refuseToStart(availableBytes: Int64)
    case stopNow(availableBytes: Int64)
}

/// When a recording may start, when to warn and when to stop before the disk fills up.
/// Starting and warning look at `importantUsage`; stopping looks at the hard `available` figure, and so
/// does starting: a take never starts where it would be stopped at once.
public struct DiskSpacePolicy: Sendable, Equatable {
    public var minimumToStart: Int64 = 2_000_000_000
    public var warnBelow: Int64 = 5_000_000_000
    public var stopBelow: Int64 = 1_000_000_000

    public init() {}

    public func evaluate(_ capacity: DiskCapacity, isRecording: Bool) -> DiskSpaceVerdict {
        if isRecording, capacity.available < stopBelow {
            return .stopNow(availableBytes: capacity.available)
        }
        if !isRecording, capacity.importantUsage < minimumToStart {
            return .refuseToStart(availableBytes: capacity.importantUsage)
        }
        // Purgeable space or local snapshots can make `importantUsage` look fine while the hard figure
        // is below the stop threshold: starting then would stop the take as `diskFull` right away.
        if !isRecording, capacity.available < stopBelow {
            return .refuseToStart(availableBytes: capacity.available)
        }
        if capacity.importantUsage < warnBelow {
            return .warn(availableBytes: capacity.importantUsage)
        }
        return .ok
    }
}

/// Polls a volume while recording. A query that throws produces no verdict and is retried on the
/// next tick.
public final class DiskSpaceMonitor: Sendable {
    private let volumeURL: URL
    private let policy: DiskSpacePolicy
    /// How often `start(onVerdict:)` checks; the coordinator watches for verdicts that stop coming.
    let interval: Duration
    private let query: @Sendable (URL) throws -> DiskCapacity
    private let queue = DispatchQueue(label: "dev.toma.DiskSpaceMonitor")
    private let timer = Mutex<DispatchSourceTimer?>(nil)

    public init(
        volumeURL: URL,
        policy: DiskSpacePolicy = .init(),
        interval: Duration = .seconds(5),
        query: @escaping @Sendable (URL) throws -> DiskCapacity = DiskSpaceMonitor.capacity
    ) {
        self.volumeURL = volumeURL
        self.policy = policy
        self.interval = interval
        self.query = query
    }

    public func verdict(isRecording: Bool) throws -> DiskSpaceVerdict {
        policy.evaluate(try query(volumeURL), isRecording: isRecording)
    }

    /// Space free right now on the volume (`DiskCapacity.available`), or `nil` if it cannot be read.
    public func availableBytes() -> Int64? {
        try? query(volumeURL).available
    }

    /// Fires once immediately, then every `interval`, evaluating as a recording in progress.
    /// Calling it again replaces the previous timer.
    public func start(onVerdict: @escaping @Sendable (DiskSpaceVerdict) -> Void) {
        let (seconds, attoseconds) = interval.components
        let nanoseconds = max(1, seconds * 1_000_000_000 + attoseconds / 1_000_000_000)
        let source = DispatchSource.makeTimerSource(queue: queue)
        source.schedule(deadline: .now(), repeating: .nanoseconds(Int(nanoseconds)))
        source.setEventHandler { [weak self] in
            guard let self, let verdict = try? verdict(isRecording: true) else { return }
            onVerdict(verdict)
        }
        let previous = timer.withLock { current in
            defer { current = source }
            return current
        }
        previous?.cancel()
        source.resume()
    }

    /// Idempotent. One more `onVerdict` may still arrive after this returns (a tick already in
    /// flight); callers must tolerate it.
    public func stop() {
        timer.withLock { current in
            defer { current = nil }
            return current
        }?.cancel()
    }

    deinit { timer.withLock { $0 }?.cancel() }

    public static func capacity(_ url: URL) throws -> DiskCapacity {
        let values = try existingAncestor(of: url).resourceValues(forKeys: [
            .volumeAvailableCapacityForImportantUsageKey, .volumeAvailableCapacityKey,
        ])
        guard let important = values.volumeAvailableCapacityForImportantUsage,
            let available = values.volumeAvailableCapacity
        else { throw CocoaError(.fileReadUnknown) }
        return DiskCapacity(importantUsage: important, available: Int64(available))
    }
}

public enum VolumeEligibility: Sendable, Equatable {
    case allowed
    case networkVolume
    case syncedFolder

    public static func check(_ url: URL) throws -> VolumeEligibility {
        if SyncedFolders.contains(url) {
            return .syncedFolder
        }
        let values = try existingAncestor(of: url).resourceValues(forKeys: [.volumeIsLocalKey])
        return values.volumeIsLocal == false ? .networkVolume : .allowed
    }
}

private func existingAncestor(of url: URL) throws -> URL {
    var candidate = url.standardizedFileURL
    while !FileManager.default.fileExists(atPath: candidate.path) {
        let parent = candidate.deletingLastPathComponent()
        if parent.path == candidate.path { throw CocoaError(.fileNoSuchFile) }
        candidate = parent
    }
    return candidate
}
