// SPDX-License-Identifier: GPL-3.0-or-later
import CoreMedia
import Darwin
import Foundation
import ProjectFormat

public enum RecoveryError: Error, Equatable {
    /// The take is being recorded right now, or another take of the same package is (its recorder
    /// is the single writer of `manifest.json`). Nothing was changed.
    case lockHeld
    /// The manifest has no take with this ID.
    case takeNotFound(String)
    /// The manifest was written by a newer version of the format; rewriting it could lose what this
    /// version does not know about. Nothing was changed.
    case unsupportedFormatVersion(Int)
}

/// Closes a take its recorder left open by dying, from what is on disk, without deleting or rewriting
/// any raw data.
public enum TakeRecovery {
    /// Takes the take's recording lock, keeps it while recovering, and closes the take as `recovered`:
    ///
    /// - every open segment gets the end of what can be read (`recoveredAfterCrash`), or `empty` (no
    ///   sample: 0 bytes, or the file is gone) or `unreadable(bytes:)` (a non-empty file that cannot be
    ///   opened, left untouched), with `endHostTime == startHostTime` for those two; `droppedFrames` and
    ///   `heartbeatFrames` are 0, since nothing recorded them;
    /// - a `seg-NNNN.mov` in a track folder that the manifest does not list is added when
    ///   `events.jsonl` has its `segmentStarted` (its `t` is the start); without one nothing says when
    ///   it starts, so it is left out and untouched;
    /// - the cut-short last line of `events.jsonl` is truncated, as before any append;
    /// - `.reserve` is deleted: it is scratch space, never take data.
    ///
    /// The manifest is written once, with all of it. Idempotent: a take that is no longer `recording`
    /// is returned as it is. Throws `RecoveryError.lockHeld` if the lock is held, or if another take of
    /// the package is being recorded, without changing anything.
    public static func recover(package: ProjectPackage, takeID: String) async throws -> TakeRecord {
        let lock = try await acquireLock(at: package.lockURL(take: takeID))
        defer { lock.release() }

        let store = try ManifestStore(package: package)
        let manifest = store.manifest
        guard manifest.formatVersion <= Manifest.currentFormatVersion else {
            throw RecoveryError.unsupportedFormatVersion(manifest.formatVersion)
        }
        guard let take = manifest.takes.first(where: { $0.id == takeID }) else { throw RecoveryError.takeNotFound(takeID) }
        guard take.status == .recording else { return take }
        let otherRecorder = manifest.takes.contains {
            $0.id != takeID && $0.status == .recording && RecordingLock.isHeld(at: package.lockURL(take: $0.id))
        }
        guard !otherRecorder else { throw RecoveryError.lockHeld }

        try removeReserve(package.reserveURL(take: takeID))
        let events = try readEventsEndingAtLineBoundary(package.eventsURL(take: takeID))
        var recovered = take
        recovered.status = .recovered
        for i in recovered.tracks.indices {
            recovered.tracks[i] = try await recover(recovered.tracks[i], of: takeID, in: package, events: events)
        }
        let closed = recovered
        try store.update { manifest in
            guard let i = manifest.takes.firstIndex(where: { $0.id == takeID }) else { return }
            manifest.takes[i] = closed
        }
        return closed
    }

    /// `RecordingLock.isHeld` probes by taking the lock for a moment, so an `acquire` that races it
    /// can fail with `EWOULDBLOCK`: try a few times before concluding it is held.
    private static func acquireLock(at url: URL) async throws -> HeldRecordingLock {
        var attempt = 1
        while true {
            do {
                return try RecordingLock.acquire(at: url, info: .current(now: Date()))
            } catch let error as POSIXError where error.code == .EWOULDBLOCK {
                guard attempt < 5 else { throw RecoveryError.lockHeld }
                attempt += 1
                try await Task.sleep(for: .milliseconds(20))
            }
        }
    }

    private static func removeReserve(_ url: URL) throws {
        guard unlink(url.path) == 0 || errno == ENOENT else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
    }

    /// Makes `events.jsonl` end at a line break, the way the recorder does before appending, and
    /// reads it. A take without one has no events.
    private static func readEventsEndingAtLineBoundary(_ url: URL) throws -> [InputEvent] {
        guard FileManager.default.fileExists(atPath: url.path) else { return [] }
        _ = try EventLogReader.truncateIncompleteTail(url)
        return try EventLogReader.read(url).events
    }

    private static func recover(
        _ track: TrackRecord, of takeID: String, in package: ProjectPackage, events: [InputEvent]
    ) async throws -> TrackRecord {
        var track = track
        let listed = Set(track.segments.map(\.index))
        for index in try segmentIndicesOnDisk(package.trackDirectory(take: takeID, track: track.id)) where !listed.contains(index) {
            let started = events.first { $0.kind == .segmentStarted(track: track.id, index: index) }
            guard let started else { continue }
            let url = package.segmentURL(take: takeID, track: track.id, index: index)
            track.segments.append(SegmentRecord(
                index: index, file: try package.relativePath(of: url), startHostTime: started.t,
                droppedFrames: 0, heartbeatFrames: 0))
        }
        track.segments.sort { $0.index < $1.index }

        for i in track.segments.indices where track.segments[i].endHostTime == nil || track.segments[i].endReason == nil {
            let segment = track.segments[i]
            let (end, reason) = await readableEnd(of: segment, kind: track.kind, in: package)
            track.segments[i].endHostTime = end
            track.segments[i].endReason = reason
            track.segments[i].droppedFrames = 0
            track.segments[i].heartbeatFrames = 0
        }
        return track
    }

    /// Where an open segment ends: its start plus what can be read of the file.
    private static func readableEnd(
        of segment: SegmentRecord, kind: TrackKind, in package: ProjectPackage
    ) async -> (HostTime, SegmentEndReason) {
        let start = segment.startHostTime
        switch await SegmentFile.inspect(package.fileURL(segment.file), kind: kind) {
        case .missing, .empty:
            return (start, .empty)
        case .unreadable(let bytes, _):
            return (start, .unreadable(bytes: bytes))
        case .readable(_, _, let duration):
            return (HostTime(nanoseconds: start.nanoseconds + HostTime(duration).nanoseconds), .recoveredAfterCrash)
        }
    }

    /// The indices of the files in a track folder named exactly as `ProjectPackage.segmentURL` names a
    /// segment. A track whose folder does not exist has none.
    private static func segmentIndicesOnDisk(_ directory: URL) throws -> [Int] {
        let names: [String]
        do {
            names = try FileManager.default.contentsOfDirectory(atPath: directory.path)
        } catch let error as CocoaError where error.code == .fileReadNoSuchFile {
            return []
        }
        return names.compactMap { name -> Int? in
            guard name.hasPrefix("seg-"), name.hasSuffix(".mov"),
                  let index = Int(name.dropFirst("seg-".count).dropLast(".mov".count)),
                  index > 0, String(format: "seg-%04d.mov", index) == name
            else { return nil }
            return index
        }
    }
}
