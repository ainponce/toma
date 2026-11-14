// SPDX-License-Identifier: GPL-3.0-or-later
import CoreMedia
import Darwin
import Foundation
import ProjectFormat

public enum RecoveryError: Error, Equatable {
    /// The take is being recorded right now. Nothing was changed.
    case lockHeld
    /// Another take of the same package is being recorded, or the manifest changed while recovering:
    /// a recorder is writing `manifest.json`, which has a single writer. Nothing was changed.
    case anotherTakeRecording
    /// The manifest has no take with this ID.
    case takeNotFound(String)
    /// The manifest was written by a newer version of the format; rewriting it could lose what this
    /// version does not know about. Nothing was changed.
    case unsupportedFormatVersion(Int)
    /// A path of the take could leave the package: an ID or segment file the manifest gives
    /// (`Manifest.validatePaths()`), or a symlink inside the take (`ProjectPackage.checkLayout`).
    /// Nothing was changed, and nothing was created or touched outside the package.
    case invalidPath(PackagePathError)
}

/// Closes a take its recorder left open by dying, from what is on disk, without deleting or rewriting
/// any raw data.
///
/// Recover the takes of a package one at a time, and before recording anything new in it: like a
/// recorder, recovery rewrites `manifest.json`, which has a single writer.
public enum TakeRecovery {
    /// Takes the take's recording lock, keeps it while recovering, and closes the take as `recovered`:
    ///
    /// - every open segment gets the end of what can be read (`recoveredAfterCrash`), or `empty` (no
    ///   sample: 0 bytes, or the file is gone) or `unreadable(bytes:)` (a non-empty file whose contents
    ///   cannot be read, left untouched), with `endHostTime == startHostTime` for those two. Its
    ///   `droppedFrames` is the last `droppedSamples` total the recorder logged for it (0 if none);
    ///   `heartbeatFrames` is 0, since nothing logged them;
    /// - a `seg-NNNN.mov` in a track folder that the manifest does not list is added when
    ///   `events.jsonl` has its `segmentStarted` (its `t` is the start); without one nothing says when
    ///   it starts, so it is left out and untouched;
    /// - the cut-short last line of `events.jsonl` is truncated, as before any append;
    /// - `.reserve` is deleted: it is scratch space, never take data.
    ///
    /// The manifest is written once, with all of it. Idempotent: a take that is no longer `recording`
    /// is returned as it is.
    ///
    /// Throws without changing anything: `RecoveryError.invalidPath` for a take ID that is not
    /// `take-NNN`, a manifest with a path that could leave the package, or a symlink (or an entry of the
    /// wrong kind) where the take's folders, lock, event log or reserve should be, checked before the lock
    /// is taken and again once it is held.
    ///
    /// Throws without changing the manifest: `RecoveryError.lockHeld` if the take's lock is held;
    /// `anotherTakeRecording` if another take of the package is being recorded, checked again right
    /// before the manifest is written, or if the manifest changed meanwhile; and the error of a segment
    /// file that exists but cannot be examined or opened (for example `EACCES`), so the take stays
    /// `recording` and can be recovered once the file is readable.
    public static func recover(package: ProjectPackage, takeID: String) async throws -> TakeRecord {
        try await recover(package: package, takeID: takeID, beforeWriting: {})
    }

    /// `recover`, running `beforeWriting` just before the last check for another recorder: tests use it
    /// to start one while a recovery is in progress.
    static func recover(
        package: ProjectPackage, takeID: String, beforeWriting: () async throws -> Void
    ) async throws -> TakeRecord {
        // Before the lock, which creates a file: its path must stay inside the package.
        do throws(PackagePathError) {
            try package.checkLayout(of: TakeRecord(id: takeID, status: .recording, startedAt: Date(), tracks: []))
        } catch {
            throw RecoveryError.invalidPath(error)
        }
        // `RecordingLock.isHeld` probes by taking the lock for a moment: try a few times before concluding
        // that the take is being recorded.
        let lock: HeldRecordingLock
        do {
            lock = try await RecordingLock.acquire(at: package.lockURL(take: takeID), info: .current(now: Date()), retries: 4)
        } catch let error as POSIXError where error.code == .EWOULDBLOCK {
            throw RecoveryError.lockHeld
        }
        defer { lock.release() }

        let version = try Manifest.formatVersion(of: Data(contentsOf: package.manifestURL))
        guard version <= Manifest.currentFormatVersion else { throw RecoveryError.unsupportedFormatVersion(version) }
        let store = try ManifestStore(package: package)
        let snapshot = store.manifest
        guard let take = snapshot.takes.first(where: { $0.id == takeID }) else { throw RecoveryError.takeNotFound(takeID) }
        do throws(PackagePathError) {
            try snapshot.validatePaths()
            try package.checkLayout(of: take)
        } catch {
            throw RecoveryError.invalidPath(error)
        }
        guard take.status == .recording else { return take }
        guard try !anotherTakeIsRecording(in: package, besides: takeID) else { throw RecoveryError.anotherTakeRecording }

        try removeReserve(package.reserveURL(take: takeID))
        let events = try readEventsEndingAtLineBoundary(package.eventsURL(take: takeID))
        var recovered = take
        recovered.status = .recovered
        for i in recovered.tracks.indices {
            recovered.tracks[i] = try await recover(recovered.tracks[i], of: takeID, in: package, events: events)
        }

        try await beforeWriting()
        guard try !anotherTakeIsRecording(in: package, besides: takeID),
              try ProjectJSON.decoder().decode(Manifest.self, from: Data(contentsOf: package.manifestURL)) == snapshot
        else { throw RecoveryError.anotherTakeRecording }
        let closed = recovered
        try store.update { manifest in
            guard let i = manifest.takes.firstIndex(where: { $0.id == takeID }) else { return }
            manifest.takes[i] = closed
        }
        return closed
    }

    /// Whether the lock of any other take folder of the package is held, including a take whose
    /// recorder has taken its lock but not yet written it to the manifest.
    private static func anotherTakeIsRecording(in package: ProjectPackage, besides takeID: String) throws -> Bool {
        let takes = package.takeDirectory(takeID).deletingLastPathComponent()
        return try FileManager.default.contentsOfDirectory(atPath: takes.path).contains { other in
            other != takeID && RecordingLock.isHeld(at: package.lockURL(take: other))
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
            let (end, reason) = try await readableEnd(of: segment, kind: track.kind, in: package)
            track.segments[i].endHostTime = end
            track.segments[i].endReason = reason
            track.segments[i].droppedFrames = loggedDrops(track: track.id, segment: segment.index, in: events)
            track.segments[i].heartbeatFrames = 0
        }
        return track
    }

    /// Where an open segment ends: its start plus what can be read of the file.
    private static func readableEnd(
        of segment: SegmentRecord, kind: TrackKind, in package: ProjectPackage
    ) async throws -> (HostTime, SegmentEndReason) {
        let start = segment.startHostTime
        switch try await SegmentMedia.inspect(package.fileURL(segment.file), kind: kind) {
        case .missing, .empty:
            return (start, .empty)
        case .unreadable(let bytes, _):
            return (start, .unreadable(bytes: bytes))
        case .readable(_, _, let duration):
            return (HostTime(nanoseconds: start.nanoseconds + HostTime(duration).nanoseconds), .recoveredAfterCrash)
        }
    }

    /// The last `droppedSamples` total of `track` logged after the `segmentStarted` of segment
    /// `index` and before the track's next `segmentStarted`, in file order; 0 if there is none.
    private static func loggedDrops(track: String, segment index: Int, in events: [InputEvent]) -> Int {
        guard let start = events.firstIndex(where: { $0.kind == .segmentStarted(track: track, index: index) }) else {
            return 0
        }
        var count = 0
        for event in events[events.index(after: start)...] {
            switch event.kind {
            case .segmentStarted(let other, _) where other == track:
                return count
            case .droppedSamples(let other, let total) where other == track:
                count = total
            default:
                continue
            }
        }
        return count
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
