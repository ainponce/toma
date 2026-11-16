// SPDX-License-Identifier: GPL-3.0-or-later
import Darwin
import Foundation

public enum ProjectTrashError: Error, Equatable {
    /// A take of the project holds its recording lock: it is being recorded.
    case takeStillRecording
}

/// Where a restarted take goes: `<projects folder>/Trash/`, a folder of whole projects that open like
/// any other, kept until the user deletes them. Nothing here ever deletes or replaces anything.
public enum ProjectTrash {
    public static let folderName = "Trash"

    /// `<projectsFolder>/Trash/`.
    public static func folder(in projectsFolder: URL) -> URL {
        projectsFolder.appendingPathComponent(folderName, isDirectory: true)
    }

    /// Moves `package` into the trash of `projectsFolder`, creating the trash if needed, and returns where
    /// it is now: under its own name, with ` 2`, ` 3`, … added while a project of that name is in the
    /// trash (`move(_:into:as:)`). The trash is inside the projects folder, so this is a rename on the same
    /// volume: the project is never copied, nor left half in each place.
    ///
    /// Throws `takeStillRecording`, moving nothing, if any take folder of the package holds its recording
    /// lock. Any other failure is thrown, and leaves the package where it was.
    public static func move(_ package: ProjectPackage, projectsFolder: URL) throws -> URL {
        let takes = try FileManager.default.contentsOfDirectory(atPath: package.takesURL.path)
        guard !takes.contains(where: { RecordingLock.isHeld(at: package.lockURL(take: $0)) }) else {
            throw ProjectTrashError.takeStillRecording
        }
        let trash = folder(in: projectsFolder)
        try FileManager.default.createDirectory(at: trash, withIntermediateDirectories: true)
        return try move(package.url, into: trash)
    }

    /// Renames the package at `url` into the folder `folder` (which must be there, and not a link) under `name`, its
    /// own name without `.toma` by default, with ` 2`, ` 3`, … added while that name is taken there (as the file system
    /// compares names: on APFS, without telling case or normalization apart), and returns where it is now. A rename
    /// with `renameExclusively`: it never replaces anything and never copies (`EXDEV` if `folder` is on another
    /// volume), so the project is whole in one place or the other. Probes no lock. Any failure is thrown, and leaves
    /// the package where it was.
    public static func move(_ url: URL, into folder: URL, as name: String? = nil) throws -> URL {
        var info = stat()
        guard lstat(folder.path, &info) == 0 else { throw POSIXError.current() }
        guard info.st_mode & S_IFMT == S_IFDIR else { throw POSIXError(.ENOTDIR) }
        let base = name ?? url.deletingPathExtension().lastPathComponent
        var attempt = 1
        while true {
            let candidate = attempt == 1 ? base : "\(base) \(attempt)"
            let destination = folder.appendingPathComponent("\(candidate).\(ProjectPackage.fileExtension)", isDirectory: true)
            do {
                try renameExclusively(from: AT_FDCWD, url.path, to: AT_FDCWD, destination.path)
                return destination
            } catch let error as POSIXError where error.code == .EEXIST {
                attempt += 1
            }
        }
    }

    /// Renames the folder `fromName` (relative to the folder open at `fromFolder`, or a path with `AT_FDCWD`) to
    /// `toName` (relative to `toFolder`), never replacing anything: `renameatx_np(2)` with `RENAME_EXCL`. A link is
    /// renamed itself, never followed.
    ///
    /// Throws `POSIXError(.EEXIST)` if something is at `toName`, unless it is the item itself under a name that differs
    /// only in case or normalization on a volume that does not tell those apart (then it is renamed, which changes only
    /// how its name is written). On a volume without `RENAME_EXCL` (exFAT, SMB: `ENOTSUP`), the rename is `renameat(2)`
    /// once nothing is found at `toName`, which can only ever replace a folder that appeared empty in between. Any other
    /// error is thrown as it came.
    public static func renameExclusively(from fromFolder: Int32, _ fromName: String, to toFolder: Int32, _ toName: String) throws {
        if renameatx_np(fromFolder, fromName, toFolder, toName, UInt32(RENAME_EXCL)) == 0 { return }
        let failure = POSIXError.current()
        switch failure.code {
        case .EEXIST:
            guard isSameItem(fromFolder, fromName, toFolder, toName) else { throw failure }
        case .ENOTSUP:
            var info = stat()
            if fstatat(toFolder, toName, &info, AT_SYMLINK_NOFOLLOW) == 0 {
                guard isSameItem(fromFolder, fromName, toFolder, toName) else { throw POSIXError(.EEXIST) }
            } else if errno != ENOENT {
                throw POSIXError.current()
            }
        default:
            throw failure
        }
        guard renameat(fromFolder, fromName, toFolder, toName) == 0 else {
            let error = POSIXError.current()
            // Something came to `toName` in between: a folder that holds anything, or a file, is not replaced.
            if [.ENOTEMPTY, .EEXIST, .ENOTDIR, .EISDIR].contains(error.code) { throw POSIXError(.EEXIST) }
            throw error
        }
    }

    /// Whether the two names are the same item (the same file on the same device), neither followed if it is a link.
    private static func isSameItem(_ fromFolder: Int32, _ fromName: String, _ toFolder: Int32, _ toName: String) -> Bool {
        var from = stat()
        var to = stat()
        guard fstatat(fromFolder, fromName, &from, AT_SYMLINK_NOFOLLOW) == 0,
            fstatat(toFolder, toName, &to, AT_SYMLINK_NOFOLLOW) == 0
        else { return false }
        return from.st_dev == to.st_dev && from.st_ino == to.st_ino
    }
}
