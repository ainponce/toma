// SPDX-License-Identifier: GPL-3.0-or-later
import Darwin
import Foundation
import ProjectFormat

/// What `PackageUpgrade.upgrade` did. It goes back from the session's queue of files to the main actor.
public enum UpgradeResult: Sendable {
    /// The package is at version 3 with its log: `edit.lock` is held, and this is the manifest written.
    case upgraded(HeldRecordingLock, Manifest)
    /// Another process holds `edit.lock`: nothing was written.
    case lockTaken
    /// The manifest is not the one opened any more (another process upgraded, edited and let go of the package, or
    /// changed it otherwise): nothing was written, and `edit.lock` was let go again.
    case changedMeanwhile
}

/// The calls through which `PackageUpgrade` writes and waits, so tests can make a write fail or see a wait (like
/// `EditJournalIO`).
public struct PackageUpgradeIO: Sendable {
    /// Writes `data` as the file `name` of the folder `directory` is open on; throws a `POSIXError`.
    public var write: @Sendable (_ data: Data, _ name: String, _ directory: Int32) throws -> Void
    /// Waits `delay` before `edit.lock` is tried again, while another open file holds it.
    public var pause: @Sendable (_ delay: Duration) -> Void

    public init(
        write: @escaping @Sendable (_ data: Data, _ name: String, _ directory: Int32) throws -> Void,
        pause: @escaping @Sendable (_ delay: Duration) -> Void
    ) {
        self.write = write
        self.pause = pause
    }

    /// `DurableFile.writeAtomically(_:named:inDirectory:)`, and a sleep of the calling thread.
    public static let system = PackageUpgradeIO(
        write: { try DurableFile.writeAtomically($0, named: $1, inDirectory: $2) },
        pause: { Thread.sleep(forTimeInterval: $0 / .seconds(1)) })
}

/// The first edit of a version 1 or 2 package moves it to version 3, in the order of design §6.1, so that a crash at
/// any point leaves a package that opens with the look it had:
///
/// 1. `edit.lock` is taken (another process holds it → `lockTaken`) and the manifest read again, never through a
///    symlink nor blocked on a FIFO (`SafeRead.regularFile(at:)`): one that is not the manifest opened, or that no
///    longer decodes, is `changedMeanwhile`, and the lock is let go.
/// 2. The manifest is rewritten with `formatVersion: 3`, `upgradedFrom` and the derived `projectID` (plan decision 9),
///    nothing else: the takes keep their version 1 or 2 content, which version 3 reads.
/// 3. `edit-log.jsonl` is written with the `create` of the legacy document (`seq` 1) and, with `first`, its `do`
///    (`seq` and group 2, at `context.now()` in whole seconds), the way the session numbers them.
///
/// A crash between 2 and 3 leaves a version 3 package with `upgradedFrom` and no log, which opens with the legacy
/// document; no older reader can show an edit, since edits only exist after the version changed. Both files are written
/// through `context.upgradeIO` (`DurableFile.writeAtomically(_:named:inDirectory:)`), relative to the package folder's
/// descriptor.
///
/// Synchronous: it waits for the lock's file and for `F_FULLFSYNC`, so it runs on the session's queue of files, never
/// on the main actor (plan decision 28).
public enum PackageUpgrade {
    /// Moves the package at `package` (its current place), whose folder `folder` is open on, from the version 1 or 2
    /// manifest `opened` (as the session read it) to version 3, with the `create` of `legacy` and the `do` of `first`.
    ///
    /// Throws, having released the lock, if a step cannot be done: `EINVAL` for a manifest `opened` that is not of
    /// version 1 or 2, the error of `legacy.applying(first.changes)` (nothing is touched then), and the `POSIXError` of
    /// a file that cannot be written or read. After a failure in step 3 the package is the one a crash there leaves.
    /// The session does not let go: it takes the upgrade up again from the step it reached (`advance`).
    public static func upgrade(
        _ package: ProjectPackage, folder: Int32, opened: Manifest, legacy: EditDocument, first: EditStep?,
        context: EditContext
    ) throws -> UpgradeResult {
        var progress = Progress(encoded: try Encoded(opened: opened, legacy: legacy, first: first, context: context))
        do {
            return try advance(&progress, package, folder: folder, opened: opened, io: context.upgradeIO)
        } catch {
            progress.lock?.release(inDirectory: folder)
            throw error
        }
    }

    /// What an upgrade writes, encoded before anything is touched.
    struct Encoded: Sendable {
        var manifest: Manifest
        var manifestData: Data
        /// The log: the `create` and the `do`, each with its line break.
        var log: Data
        /// When the step was made: the `do`'s `at` and the lock's `startedAt`.
        var at: Date

        init(opened: Manifest, legacy: EditDocument, first: EditStep?, context: EditContext) throws {
            guard (1...2).contains(opened.formatVersion) else { throw POSIXError(.EINVAL) }
            at = context.now()
            manifest = PackageUpgrade.upgraded(opened)
            manifestData = try ProjectJSON.encoder().encode(manifest)
            let lines = try PackageUpgrade.entries(legacy: legacy, first: first, at: at, app: context.app)
            log = Data(try lines.map { try $0.jsonLine() + "\n" }.joined().utf8)
        }
    }

    /// How far an upgrade got. A step counts as done once its write returned; one that threw may have reached the disk
    /// all the same, and is written again, with the same bytes, under the same lock: no other process can have touched
    /// the package meanwhile.
    struct Progress: Sendable {
        var encoded: Encoded
        /// Held from step 1 on.
        var lock: HeldRecordingLock?
        var manifestWritten = false
        var logWritten = false
    }

    /// Takes the upgrade up from where `progress` says, each step not done yet in order. Throws the error of the step
    /// that failed, `progress` saying how far it got and the lock kept, except when step 1's read of the manifest fails:
    /// the lock is let go, so the next attempt asks again whether another process came.
    static func advance(
        _ progress: inout Progress, _ package: ProjectPackage, folder: Int32, opened: Manifest, io: PackageUpgradeIO
    ) throws -> UpgradeResult {
        if progress.lock == nil {
            // (1)
            let lock: HeldRecordingLock
            do {
                lock = try RecordingLock.acquire(
                    at: package.editLockURL, info: .current(now: progress.encoded.at), retries: RecordingLock.probeRetries,
                    pause: { io.pause(RecordingLock.probeRetryDelay) })
            } catch let error as POSIXError where error.code == .EWOULDBLOCK {
                return .lockTaken
            }
            do {
                let current = try SafeRead.regularFile(at: package.manifestURL)
                guard (try? ProjectJSON.decoder().decode(Manifest.self, from: current)) == opened else {
                    lock.release(inDirectory: folder)
                    return .changedMeanwhile
                }
            } catch {
                lock.release(inDirectory: folder)
                throw error
            }
            progress.lock = lock
        }
        if !progress.manifestWritten {
            // (2)
            try io.write(progress.encoded.manifestData, package.manifestURL.lastPathComponent, folder)
            progress.manifestWritten = true
        }
        if !progress.logWritten {
            // (3)
            try io.write(progress.encoded.log, package.editLogURL.lastPathComponent, folder)
            progress.logWritten = true
        }
        guard let lock = progress.lock else { throw POSIXError(.EBADF) }
        return .upgraded(lock, progress.encoded.manifest)
    }

    /// `opened` at version 3: `upgradedFrom` its version and the id it already had, the derived one.
    static func upgraded(_ opened: Manifest) -> Manifest {
        var manifest = opened
        manifest.formatVersion = 3
        manifest.upgradedFrom = opened.formatVersion
        manifest.projectID = ProjectID.derived(from: opened)
        return manifest
    }

    /// The lines the upgrade writes: the `create` of `legacy` at `seq` 1 and the `do` of `first` at `seq` 2, in group 2
    /// (the group a first step opens, numbered with its `seq`), as `EditSession.perform` records them. A line is
    /// written only once the document took its change.
    static func entries(legacy: EditDocument, first: EditStep?, at: Date, app: AppInfo) throws -> [EditLogEntry] {
        var created = legacy
        created.logSequence = 1
        var entries = [EditLogEntry.create(seq: 1, document: created, app: app)]
        if let first {
            _ = try legacy.applying(first.changes)
            entries.append(
                .do(seq: 2, group: 2, label: first.label.rawValue, changes: first.changes, at: at.roundedToWholeSeconds))
        }
        return entries
    }
}
