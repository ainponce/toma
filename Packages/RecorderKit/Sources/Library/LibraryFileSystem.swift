// SPDX-License-Identifier: GPL-3.0-or-later
import Darwin
import Foundation
import ProjectFormat
import Synchronization

/// The volume an item is on, as the library needs it to decide what it may look at by itself (design §6.5, §6.8): only
/// what the system answers at once. Its free space, which takes a few milliseconds to work out, is `freeSpace(of:)`.
public struct VolumeInfo: Equatable, Sendable {
    /// `volumeUUIDStringKey`; the volume's mount point for one that has no UUID.
    public var uuid: String
    /// The name the Finder shows.
    public var name: String
    /// A disk inside the Mac.
    public var isInternal: Bool
    /// A disk that can be ejected or pulled out: removable media and external disks.
    public var isRemovable: Bool
    /// Not a local volume: a share on the network.
    public var isNetwork: Bool
    /// The item is synced: iCloud Drive or a file provider (`~/Library/CloudStorage`).
    public var isSynced: Bool
    /// The volume cannot be written to (`volumeIsReadOnlyKey`): its projects open only to be looked at.
    public var isReadOnly: Bool
    /// The folder the volume is mounted at (`volumeURLKey`): `/`, `/System/Volumes/Data`, `/Volumes/Trabajo`; empty if
    /// the system does not say.
    public var mountPath: String

    public init(
        uuid: String, name: String, isInternal: Bool, isRemovable: Bool, isNetwork: Bool, isSynced: Bool,
        isReadOnly: Bool = false, mountPath: String
    ) {
        self.uuid = uuid
        self.name = name
        self.isInternal = isInternal
        self.isRemovable = isRemovable
        self.isNetwork = isNetwork
        self.isSynced = isSynced
        self.isReadOnly = isReadOnly
        self.mountPath = mountPath
    }
}

/// What an item is, itself: a link is a `symlink`, never what it points to.
public enum FileKind: Sendable {
    case directory, regular, symlink, other
}

/// An item as `lstat` describes it, with the date it arrived in its folder.
public struct FileStat: Equatable, Sendable {
    /// In bytes.
    public var size: Int64
    /// The modification date, in nanoseconds since 1970.
    public var modified: Int64
    public var kind: FileKind
    /// The item's identifier on its volume (`fileIdentifierKey`, the inode number).
    public var fileID: UInt64
    /// When the item was created in its folder or renamed into it (`addedToDirectoryDateKey`), if the volume keeps it.
    public var addedToDirectory: Date?

    public init(size: Int64, modified: Int64, kind: FileKind, fileID: UInt64, addedToDirectory: Date? = nil) {
        self.size = size
        self.modified = modified
        self.kind = kind
        self.fileID = fileID
        self.addedToDirectory = addedToDirectory
    }
}

/// Everything the library asks of the disk, so the tests can count the accesses, delay them and make up volumes. Every
/// call may take as long as its disk does: none is made on the main thread. None follows a link, and none writes.
public protocol LibraryFileSystem: Sendable {
    /// The items in `directory`, hidden ones included, in no particular order.
    func list(_ directory: URL) throws -> [URL]
    /// The item at `url` itself; its `addedToDirectory` only `withAddedDate`, which asks the disk once more.
    func stat(_ url: URL, withAddedDate: Bool) throws -> FileStat
    /// The volume `url` is on, at once: asked for every project the library looks at.
    func volume(of url: URL) throws -> VolumeInfo
    /// The free space of the volume `url` is on, in bytes. It takes the system a few milliseconds (it counts what it
    /// could purge), so it is asked only where it is shown or needed (the sidebar's footer, a copy, the alert of the
    /// trash), never for each project.
    func freeSpace(of url: URL) throws -> Int64
    /// The bytes of the regular file at `url`, which must not be larger than `maxBytes`.
    func read(_ url: URL, maxBytes: Int) throws -> Data
    /// The space everything inside the folder `package` takes on its disk, in bytes.
    func allocatedSize(of package: URL) throws -> Int64
}

extension LibraryFileSystem {
    /// The item at `url` itself, with the date it arrived in its folder.
    public func stat(_ url: URL) throws -> FileStat {
        try stat(url, withAddedDate: true)
    }
}

/// The disk itself. Failures are thrown as `POSIXError`s, except `volume(of:)`'s, which are Foundation's.
public struct SystemFileSystem: LibraryFileSystem {
    public init() {}

    /// `ENOTDIR` if `directory` is not a folder, a link to one included: it is opened with `O_DIRECTORY | O_NOFOLLOW`
    /// and read with `readdir`, so nothing is followed even if the item changes in between. A folder's URL says it is
    /// one (`hasDirectoryPath`), as the URLs 1b builds for packages do, so the two are equal.
    public func list(_ directory: URL) throws -> [URL] {
        let fd = try retryingInterrupts { open(directory.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC) }
        guard let stream = fdopendir(fd) else {
            let error = POSIXError.current
            close(fd)
            throw error
        }
        defer { closedir(stream) }
        var urls: [URL] = []
        while true {
            errno = 0
            guard let entry = readdir(stream) else {
                if errno != 0 { throw POSIXError.current }
                return urls
            }
            let length = Int(entry.pointee.d_namlen)
            let type = entry.pointee.d_type
            let (name, hint) = withUnsafeBytes(of: entry.pointee.d_name) { bytes in
                let cName = bytes.baseAddress!.assumingMemoryBound(to: CChar.self)
                return (
                    FileManager.default.string(withFileSystemRepresentation: cName, length: length),
                    Self.directoryHint(type: type, name: cName, in: dirfd(stream))
                )
            }
            if name == "." || name == ".." { continue }
            urls.append(directory.appending(path: name, directoryHint: hint))
        }
    }

    /// With `lstat`, and, only `withAddedDate`, `getattrlist` with `FSOPT_NOFOLLOW` for the date the item arrived in
    /// its folder.
    public func stat(_ url: URL, withAddedDate: Bool) throws -> FileStat {
        let info = try lstatInfo(url)
        let kind: FileKind =
            switch info.st_mode & S_IFMT {
            case S_IFDIR: .directory
            case S_IFREG: .regular
            case S_IFLNK: .symlink
            default: .other
            }
        let modified = Int64(info.st_mtimespec.tv_sec) * 1_000_000_000 + Int64(info.st_mtimespec.tv_nsec)
        return FileStat(
            size: Int64(info.st_size), modified: modified, kind: kind, fileID: UInt64(info.st_ino),
            addedToDirectory: withAddedDate ? Self.addedToDirectory(url) : nil)
    }

    /// With `URLResourceValues`, read again on every call, without the free space (`freeSpace(of:)`). Synced: an item
    /// iCloud or a file provider syncs (`isUbiquitousItemKey`) or one in `SyncedFolders`, the folders 1b refuses to
    /// record into for the same reason.
    public func volume(of url: URL) throws -> VolumeInfo {
        var url = url
        url.removeAllCachedResourceValues()
        let values = try url.resourceValues(forKeys: [
            .volumeUUIDStringKey, .volumeURLKey, .volumeLocalizedNameKey, .volumeNameKey, .volumeIsInternalKey,
            .volumeIsRemovableKey, .volumeIsEjectableKey, .volumeIsLocalKey, .isUbiquitousItemKey, .volumeIsReadOnlyKey,
        ])
        guard let uuid = values.volumeUUIDString ?? values.volume?.path else { throw CocoaError(.fileReadUnknown) }
        return VolumeInfo(
            uuid: uuid,
            name: values.volumeLocalizedName ?? values.volumeName ?? "",
            isInternal: values.volumeIsInternal == true,
            isRemovable: values.volumeIsRemovable == true || values.volumeIsEjectable == true,
            isNetwork: values.volumeIsLocal != true,
            isSynced: values.isUbiquitousItem == true || SyncedFolders.contains(url),
            isReadOnly: values.volumeIsReadOnly == true,
            mountPath: values.volume?.path ?? "")
    }

    /// The larger of the space for important usage, which counts what the system would purge, and the space free right
    /// now (a disk image gives 0 for the first), with `URLResourceValues` read again.
    public func freeSpace(of url: URL) throws -> Int64 {
        var url = url
        url.removeAllCachedResourceValues()
        let values = try url.resourceValues(forKeys: [
            .volumeAvailableCapacityForImportantUsageKey, .volumeAvailableCapacityKey,
        ])
        return max(values.volumeAvailableCapacityForImportantUsage ?? 0, Int64(values.volumeAvailableCapacity ?? 0))
    }

    /// With `SafeRead.regularFile(at:maxBytes:)`: `ELOOP` for a link (`O_NOFOLLOW`), `EFTYPE` at once for a FIFO or
    /// anything else that is not a regular file (`O_NONBLOCK` and `fstat`), and `EFBIG` for a file larger than
    /// `maxBytes`, before it is read, or one that grows past it while it is read, never reading more than one byte past.
    public func read(_ url: URL, maxBytes: Int) throws -> Data {
        try SafeRead.regularFile(at: url, maxBytes: maxBytes)
    }

    /// The sum of `totalFileAllocatedSizeKey` over everything inside `package`; a link counts as itself and is never
    /// followed, and an item that goes away meanwhile counts as nothing. `ELOOP` if `package` is a link and `ENOTDIR` if
    /// it is not a folder. Anything else that cannot be read (a folder without permission, a disk that fails) stops
    /// the sum and is thrown, as a `POSIXError` when Foundation's error carries one: never a size that leaves it out.
    public func allocatedSize(of package: URL) throws -> Int64 {
        switch try lstatInfo(package).st_mode & S_IFMT {
        case S_IFDIR: break
        case S_IFLNK: throw POSIXError(.ELOOP)
        default: throw POSIXError(.ENOTDIR)
        }
        let keys: Set<URLResourceKey> = [.totalFileAllocatedSizeKey]
        let failure = Mutex<(any Error)?>(nil)
        guard
            let items = FileManager.default.enumerator(
                at: package, includingPropertiesForKeys: Array(keys), options: [],
                errorHandler: { _, error in
                    if Self.isGone(error) { return true }
                    failure.withLock { $0 = error }
                    return false
                })
        else { throw POSIXError(.EIO) }
        var total: Int64 = 0
        for case let item as URL in items {
            do {
                total += Int64(try item.resourceValues(forKeys: keys).totalFileAllocatedSize ?? 0)
            } catch where Self.isGone(error) {
                continue
            } catch {
                throw Self.posix(error)
            }
        }
        if let error = failure.withLock({ $0 }) { throw Self.posix(error) }
        return total
    }

    /// Whether `error` says the item is no longer there.
    private static func isGone(_ error: any Error) -> Bool {
        let error = error as NSError
        if error.domain == NSCocoaErrorDomain,
            [CocoaError.fileNoSuchFile.rawValue, CocoaError.fileReadNoSuchFile.rawValue].contains(error.code)
        {
            return true
        }
        return posixCode(of: error) == .ENOENT
    }

    /// `error` as the `POSIXError` it carries, itself or as Foundation's underlying error; as it is if none.
    private static func posix(_ error: any Error) -> any Error {
        posixCode(of: error).map { POSIXError($0) } ?? error
    }

    private static func posixCode(of error: any Error) -> POSIXErrorCode? {
        let error = error as NSError
        if error.domain == NSPOSIXErrorDomain { return POSIXErrorCode(rawValue: Int32(error.code)) }
        return (error.userInfo[NSUnderlyingErrorKey] as? NSError).flatMap { posixCode(of: $0) }
    }

    private func lstatInfo(_ url: URL) throws -> Darwin.stat {
        var info = Darwin.stat()
        guard lstat(url.path, &info) == 0 else { throw POSIXError.current }
        return info
    }

    /// `ATTR_CMN_ADDEDTIME` of the item itself, or `nil` if its volume does not keep it.
    private static func addedToDirectory(_ url: URL) -> Date? {
        var request = attrlist()
        request.bitmapcount = u_short(ATTR_BIT_MAP_COUNT)
        request.commonattr = attrgroup_t(ATTR_CMN_RETURNED_ATTRS) | attrgroup_t(ATTR_CMN_ADDEDTIME)
        // The length of what was returned, which attributes were (`ATTR_CMN_RETURNED_ATTRS` always comes first), and the
        // date.
        let returnedOffset = MemoryLayout<UInt32>.size
        let timeOffset = returnedOffset + MemoryLayout<attribute_set_t>.size
        var buffer = [UInt8](repeating: 0, count: timeOffset + MemoryLayout<timespec>.size)
        let status = buffer.withUnsafeMutableBytes { bytes in
            getattrlist(url.path, &request, bytes.baseAddress, bytes.count, UInt32(FSOPT_NOFOLLOW))
        }
        guard status == 0 else { return nil }
        return buffer.withUnsafeBytes { bytes in
            let returned = bytes.loadUnaligned(fromByteOffset: returnedOffset, as: attribute_set_t.self)
            guard returned.commonattr & attrgroup_t(ATTR_CMN_ADDEDTIME) != 0 else { return nil }
            let time = bytes.loadUnaligned(fromByteOffset: timeOffset, as: timespec.self)
            return Date(timeIntervalSince1970: TimeInterval(time.tv_sec) + TimeInterval(time.tv_nsec) / 1e9)
        }
    }

    /// Whether an entry `readdir` gave is a folder: from its `d_type`, or, where the volume does not say, from
    /// `fstatat` on the item itself (`AT_SYMLINK_NOFOLLOW`).
    private static func directoryHint(type: UInt8, name: UnsafePointer<CChar>, in folder: Int32) -> URL.DirectoryHint {
        switch Int32(type) {
        case DT_DIR:
            return .isDirectory
        case DT_UNKNOWN:
            var info = Darwin.stat()
            guard fstatat(folder, name, &info, AT_SYMLINK_NOFOLLOW) == 0 else { return .inferFromPath }
            return info.st_mode & S_IFMT == S_IFDIR ? .isDirectory : .notDirectory
        default:
            return .notDirectory
        }
    }

    private func retryingInterrupts(_ call: () -> Int32) throws -> Int32 {
        while true {
            let fd = call()
            if fd >= 0 { return fd }
            if errno != EINTR { throw POSIXError.current }
        }
    }
}

extension POSIXError {
    /// The error `errno` names.
    fileprivate static var current: POSIXError { POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
}
