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
/// with `DurableFile.writeAtomically(_:named:inDirectory:)`, relative to the package folder's descriptor.
///
/// Synchronous: it waits for the lock's file and for `F_FULLFSYNC`, so it runs on the session's queue of files, never
/// on the main actor (plan decision 28).
public enum PackageUpgrade {
    /// Another opener's probe of `RecordingLock.isHeld` takes `edit.lock` for a moment: an attempt that meets one is
    /// tried again this many times, `lockRetryDelay` apart, before the lock counts as taken, here and when a version 3
    /// package opens (as the recorder does with `recording.lock`).
    static let lockRetries = 4
    static let lockRetryDelay: Duration = .milliseconds(20)

    /// Moves the package at `package` (its current place), whose folder `folder` is open on, from the version 1 or 2
    /// manifest `opened` (as the session read it) to version 3, with the `create` of `legacy` and the `do` of `first`.
    ///
    /// Throws, having released the lock, if a step cannot be done: `EINVAL` for a manifest `opened` that is not of
    /// version 1 or 2, the error of `legacy.applying(first.changes)` (nothing is touched then), and the `POSIXError` of
    /// a file that cannot be written or read. After a failure in step 3 the package is the one a crash there leaves.
    public static func upgrade(
        _ package: ProjectPackage, folder: Int32, opened: Manifest, legacy: EditDocument, first: EditStep?,
        context: EditContext
    ) throws -> UpgradeResult {
        guard (1...2).contains(opened.formatVersion) else { throw POSIXError(.EINVAL) }
        let at = context.now()
        // Everything is encoded before anything is touched.
        let manifest = upgraded(opened)
        let manifestData = try ProjectJSON.encoder().encode(manifest)
        let lines = try entries(legacy: legacy, first: first, at: at, app: context.app).map { try $0.jsonLine() + "\n" }
        let log = Data(lines.joined().utf8)

        // (1)
        guard let lock = try acquireLock(at: package.editLockURL, info: .current(now: at)) else { return .lockTaken }
        do {
            let current = try SafeRead.regularFile(at: package.manifestURL)
            guard (try? ProjectJSON.decoder().decode(Manifest.self, from: current)) == opened else {
                lock.release(inDirectory: folder)
                return .changedMeanwhile
            }
            // (2)
            try DurableFile.writeAtomically(manifestData, named: package.manifestURL.lastPathComponent, inDirectory: folder)
            // (3)
            try DurableFile.writeAtomically(log, named: package.editLogURL.lastPathComponent, inDirectory: folder)
        } catch {
            lock.release(inDirectory: folder)
            throw error
        }
        return .upgraded(lock, manifest)
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

    /// `RecordingLock.acquire`, with `lockRetries` more attempts while another open file holds it; `nil` if it still
    /// does. Any other error is thrown.
    private static func acquireLock(at url: URL, info: RecordingLockInfo) throws -> HeldRecordingLock? {
        for attempt in 0...lockRetries {
            do {
                return try RecordingLock.acquire(at: url, info: info)
            } catch let error as POSIXError where error.code == .EWOULDBLOCK {
                if attempt < lockRetries { usleep(useconds_t(lockRetryDelay / .microseconds(1))) }
            }
        }
        return nil
    }
}
