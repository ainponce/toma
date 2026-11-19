// SPDX-License-Identifier: GPL-3.0-or-later
import CryptoKit
import Darwin
import Foundation
import ProjectFormat

/// What `EditSession.importAsset` copies into a package's `assets/`.
public enum AssetKind: Sendable {
    /// An image for a background (design §6.1, `PackageFileKind.asset`): a PNG, a JPEG or a HEIC.
    case image
    /// A 3D LUT for the camera's colors (phase 2 design §6.3, `PackageFileKind.lut`): a `.cube`.
    case lut

    /// The extensions a file of this kind is taken with, lowercased (`jpeg` as `jpg`).
    var extensions: [String] {
        switch self {
        case .image: AssetImport.allowedExtensions
        case .lut: ["cube"]
        }
    }

    /// The rules the copy is named and read by in the package.
    var fileKind: PackageFileKind {
        switch self {
        case .image: .asset
        case .lut: .lut
        }
    }
}

/// Why an image or a `.cube` could not be copied into a package, besides the `POSIXError` of a file and, for a `.cube`,
/// the `CubeLUTError` of its content.
public enum AssetImportError: Error, Equatable, Sendable {
    /// The file's extension, lowercased, is not one of `AssetImport.allowedExtensions` (with `jpeg` as `jpg`), or not
    /// `cube` for `AssetImport.copyLUT`.
    case unsupportedExtension(String)
    /// The file changed while it was copied: what was copied is not what was named.
    case changedWhileCopying
}

/// What `EditSession.importAsset` did.
public enum AssetImportOutcome: Equatable, Sendable {
    /// The image is in the package's `assets/`, on the drive: the path the document names it by, `assets/<sha>.<ext>`.
    case imported(String)
    /// The file is not an image a render draws (by its extension, its content or its size), cannot be read, or changed
    /// while it was copied: "Couldn't open the image." (design §5.9). For a `.cube` (`AssetKind.lut`): it is not named
    /// `.cube`, is not there or not a regular file, cannot be read, or changed while it was copied, so its content was
    /// never judged.
    case notAnImage
    /// The project cannot be edited (read-only or closed), or it was opened again from the disk because another process
    /// changed it before its first edit here (`notices` tells): nothing was imported.
    case notEditable
    /// It could not be saved: an error that never passes (a volume or folder that cannot be written, a link inside the
    /// package), or one that had not passed when the import was given up (the caller's task cancelled, the session
    /// closed). An error that passes (a full disk, `EIO`) is shown as `EditNotice.saveFailed` and tried again meanwhile.
    case saveFailed(POSIXErrorCode)
    /// A `.cube` (`AssetKind.lut`) that was read and is not a 3D LUT Toma reads, with the reason (phase 2 design §6.3): a
    /// 1D one, a broken one, one larger than `CubeLUT.maxBytes`. Nothing was written.
    case notALUT(CubeLUTError)
}

/// Copies an image of the user's into a package's `assets/` for a background (design §6.1): named by its content, so the
/// same image is there once, and never through a link inside the package.
public enum AssetImport {
    /// The images an asset is decoded as (`PackageFileKind.asset.imageTypes`): PNG, JPEG and HEIC. No TIFF: a package's
    /// asset is never decoded as one.
    public static let allowedExtensions = ["png", "jpg", "heic"]

    /// Copies the file at `url` (a PNG, JPEG or HEIC by its extension, at most `PackageFileKind.asset.maxBytes`) to
    /// `assets/<sha>.<ext>` of `package` and gives that path, as the document names it: `<sha>` the first 32 hex digits of
    /// the SHA-256 of its bytes, `<ext>` its extension lowercased, with `jpeg` as `jpg`. A regular file of that name and
    /// size there already is the same image: nothing is copied again.
    ///
    /// Inside the package nothing is followed: `assets/` is made with `mkdirat` and opened with `openat(O_DIRECTORY |
    /// O_NOFOLLOW)` from the package folder's descriptor (a link there throws `ELOOP`); the image goes to
    /// `<sha>.<ext>.tmp` by `fclonefileat` (an APFS clone; with `EXDEV` or `ENOTSUP`, a copy of its bytes), is full-synced
    /// and hashed again, so the name is that of the bytes there, renamed to `<sha>.<ext>` with `renameat` (which replaces a
    /// link there, never follows it) and the folder synced, all before this returns: before the `set` that names it is
    /// logged.
    ///
    /// Throws `AssetImportError.unsupportedExtension` for another extension, `AssetImportError.changedWhileCopying` for a
    /// file that changed meanwhile, `EFTYPE` for a file that is not a regular one, `EFBIG` for one too large, and the
    /// `POSIXError` of a call that fails.
    public static func copy(_ url: URL, into package: ProjectPackage) throws -> String {
        do {
            return try place(url, into: package)
        } catch {
            throw error.thrown
        }
    }

    /// `copy` for a `.cube` (phase 2 design §6.3): the file at `url`, named `.cube` (in any case) and of at most
    /// `PackageFileKind.lut.maxBytes`, is read whole and parsed (`CubeLUT.parse`) before it is named, to
    /// `assets/<sha>.cube`, `<sha>` the first 32 hex digits of the SHA-256 of the bytes parsed; the copy is hashed again,
    /// so what is placed is what was parsed. The same rules inside the package as `copy`: nothing followed, a clone
    /// full-synced, `renameat`, the folder synced.
    ///
    /// Throws the `CubeLUTError` of a file that is not a 3D LUT (`tooLarge` for one larger than the limit, never read),
    /// with nothing written; `AssetImportError.unsupportedExtension` for another extension,
    /// `AssetImportError.changedWhileCopying` for a file that changed meanwhile, `EFTYPE` for a file that is not a
    /// regular one, and the `POSIXError` of a call that fails.
    public static func copyLUT(_ url: URL, into package: ProjectPackage) throws -> String {
        do {
            return try place(url, into: package, as: .lut)
        } catch {
            throw error.thrown
        }
    }

    /// Whether the file at `url` is an image a render draws: read as `copy` reads it and decoded as the package's asset
    /// reader decodes one (`PackageFileKind.asset.decodedImage`).
    static func decodes(_ url: URL) -> Bool {
        guard let source = try? openSource(url, maxBytes: PackageFileKind.asset.maxBytes) else { return false }
        defer { close(source.fd) }
        guard let data = try? readAll(source.fd, size: Int(source.size)) else { return false }
        return PackageFileKind.asset.decodedImage(data) != nil
    }

    /// What `EditSession.importAsset` says at once for the file at `url` as `kind`, read as `place` reads it, before
    /// anything is written (or a legacy package upgraded) for it: `nil` if it can be copied, `.notAnImage` for an image
    /// that does not decode (`decodes`) or a `.cube` that cannot be read, `.notALUT` for one whose content is not a 3D
    /// LUT.
    static func refusal(of url: URL, as kind: AssetKind) -> AssetImportOutcome? {
        switch kind {
        case .image:
            return decodes(url) ? nil : .notAnImage
        case .lut:
            do {
                let source = try openSource(url, as: .lut)
                defer { close(source.fd) }
                _ = try readLUT(source)
                return nil
            } catch {
                if case let .notALUT(reason) = error { return .notALUT(reason) }
                return .notAnImage
            }
        }
    }

    /// Why `place` failed: what the user's file is (`unsupported`, `source`, `changed`, `notALUT`), or the package
    /// (`destination`).
    enum Failure: Error, Sendable {
        case unsupported(String)
        case source(POSIXError)
        case changed
        case destination(POSIXError)
        /// A `.cube` whose content is not a 3D LUT.
        case notALUT(CubeLUTError)

        /// What `copy` and `copyLUT` throw for it.
        var thrown: any Error {
            switch self {
            case let .unsupported(ext): AssetImportError.unsupportedExtension(ext)
            case .changed: AssetImportError.changedWhileCopying
            case let .source(failure), let .destination(failure): failure
            case let .notALUT(reason): reason
            }
        }
    }

    /// `copy` (an image) or `copyLUT` (a `.cube`, by `kind`), its failures told apart: the user's file or the package.
    /// `syncFolder` makes a folder's entries durable (`DurableFile.fullSync`; the tests count it, and change the file
    /// while `assets/` is made: after it is named, before it is cloned).
    static func place(
        _ url: URL, into package: ProjectPackage, as kind: AssetKind = .image,
        syncFolder: (Int32) throws -> Void = DurableFile.fullSync
    ) throws(Failure) -> String {
        let source = try openSource(url, as: kind)
        defer { close(source.fd) }
        let name: String
        switch kind {
        case .image:
            do {
                name = try hash(source.fd) + "." + source.ext
            } catch {
                throw .source(error)
            }
        case .lut:
            // Named by the bytes parsed: the clone is hashed again below, so what is placed is what was parsed.
            let data = try readLUT(source)
            name = hash(data) + "." + source.ext
        }
        guard kind.fileKind.isValidName(name) else { throw .source(POSIXError(.EINVAL)) }
        let ext = source.ext

        let folder = open(package.url.path, O_RDONLY | O_DIRECTORY | O_CLOEXEC)
        guard folder >= 0 else { throw .destination(posixError()) }
        defer { close(folder) }
        let made = mkdirat(folder, "assets", 0o755) == 0
        guard made || errno == EEXIST else { throw .destination(posixError()) }
        let assets = openat(folder, "assets", O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard assets >= 0 else {
            // With `O_DIRECTORY`, a link says `ENOTDIR`: it is told as the link it is.
            let error = posixError()
            var info = stat()
            if error.code == .ENOTDIR, fstatat(folder, "assets", &info, AT_SYMLINK_NOFOLLOW) == 0, info.st_mode & S_IFMT == S_IFLNK {
                throw .destination(POSIXError(.ELOOP))
            }
            throw .destination(error)
        }
        defer { close(assets) }
        do {
            if made { try syncFolder(folder) }
        } catch {
            throw .destination((error as? POSIXError) ?? POSIXError(.EIO))
        }

        var info = stat()
        if fstatat(assets, name, &info, AT_SYMLINK_NOFOLLOW) == 0, info.st_mode & S_IFMT == S_IFREG, info.st_size == source.size {
            // An earlier try may have moved it in and failed to sync the folder: its entry is made durable now.
            do {
                try syncFolder(assets)
            } catch {
                throw .destination((error as? POSIXError) ?? POSIXError(.EIO))
            }
            return "assets/" + name
        }
        let temporary = name + ".tmp"
        guard unlinkat(assets, temporary, 0) == 0 || errno == ENOENT else { throw .destination(posixError()) }
        do {
            let placed = try clone(source.fd, in: assets, as: temporary)
            defer { close(placed) }
            // The bytes there are the ones named, or the file changed between its hash and its copy.
            guard try hash(placed) + "." + ext == name else { throw Failure.changed }
            guard renameat(assets, temporary, assets, name) == 0 else { throw Failure.destination(posixError()) }
            try syncFolder(assets)
        } catch {
            unlinkat(assets, temporary, 0)
            switch error {
            case let failure as Failure: throw failure
            case let failure as POSIXError: throw .destination(failure)
            default: throw .destination(POSIXError(.EIO))
            }
        }
        return "assets/" + name
    }

    // MARK: - Private

    private static func `extension`(of url: URL) -> String {
        let ext = url.pathExtension.lowercased()
        return ext == "jpeg" ? "jpg" : ext
    }

    /// The user's file at `url` as `kind`, opened for reading as `openSource` opens it, with its size and its extension
    /// as it is named in the package: one of `kind.extensions`, or `unsupported`. A `.cube` larger than its limit is
    /// `notALUT(.tooLarge)`, never read.
    private static func openSource(_ url: URL, as kind: AssetKind) throws(Failure) -> (fd: Int32, size: off_t, ext: String) {
        let ext = Self.extension(of: url)
        guard kind.extensions.contains(ext) else { throw .unsupported(ext) }
        do {
            let source = try openSource(url, maxBytes: kind.fileKind.maxBytes)
            return (source.fd, source.size, ext)
        } catch {
            if kind == .lut, error.code == .EFBIG { throw .notALUT(.tooLarge) }
            throw .source(error)
        }
    }

    /// The whole `.cube` `source`, parsed: its bytes, or `notALUT` with the reason it is not a 3D LUT. At most one byte
    /// more than its size is read: a file that grew since it was measured is `changed`.
    private static func readLUT(_ source: (fd: Int32, size: off_t, ext: String)) throws(Failure) -> Data {
        let data: Data
        do {
            data = try readAll(source.fd, size: Int(source.size), atMost: Int(source.size) + 1)
        } catch {
            throw .source(error)
        }
        guard data.count == Int(source.size) else { throw .changed }
        do {
            _ = try CubeLUT.parse(data)
        } catch {
            throw .notALUT(error)
        }
        return data
    }

    /// The user's file at `url`, opened for reading (never blocked on a FIFO), and its size: a regular file of at most
    /// `maxBytes`.
    private static func openSource(_ url: URL, maxBytes: Int) throws(POSIXError) -> (fd: Int32, size: off_t) {
        let fd = open(url.path, O_RDONLY | O_NONBLOCK | O_CLOEXEC)
        guard fd >= 0 else { throw posixError() }
        var info = stat()
        guard fstat(fd, &info) == 0 else {
            let error = posixError()
            close(fd)
            throw error
        }
        guard info.st_mode & S_IFMT == S_IFREG else {
            close(fd)
            throw POSIXError(.EFTYPE)
        }
        guard info.st_size <= maxBytes else {
            close(fd)
            throw POSIXError(.EFBIG)
        }
        return (fd, info.st_size)
    }

    /// The first 16 bytes of the SHA-256 of the whole file, in lowercase hex.
    private static func hash(_ fd: Int32) throws(POSIXError) -> String {
        var hasher = SHA256()
        try forEachChunk(of: fd) { hasher.update(bufferPointer: $0) }
        return hasher.finalize().prefix(16).map { String(format: "%02x", $0) }.joined()
    }

    /// The first 16 bytes of the SHA-256 of `data`, in lowercase hex: `hash(_:)` of a file of those bytes.
    private static func hash(_ data: Data) -> String {
        SHA256.hash(data: data).prefix(16).map { String(format: "%02x", $0) }.joined()
    }

    /// The file `source` as `name` in the folder `assets`, full-synced and open for reading: a clone, or its bytes where
    /// a clone cannot be made.
    private static func clone(_ source: Int32, in assets: Int32, as name: String) throws(POSIXError) -> Int32 {
        if fclonefileat(source, assets, name, 0) != 0 {
            guard errno == EXDEV || errno == ENOTSUP else { throw posixError() }
            let copy = openat(assets, name, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o644)
            guard copy >= 0 else { throw posixError() }
            defer { close(copy) }
            try forEachChunk(of: source) { (chunk) throws(POSIXError) in
                var written = 0
                while written < chunk.count {
                    let count = write(copy, chunk.baseAddress! + written, chunk.count - written)
                    if count < 0 {
                        if errno == EINTR { continue }
                        throw posixError()
                    }
                    written += count
                }
            }
        }
        let placed = openat(assets, name, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        guard placed >= 0 else { throw posixError() }
        do {
            try DurableFile.fullSync(placed)
        } catch {
            close(placed)
            throw (error as? POSIXError) ?? POSIXError(.EIO)
        }
        return placed
    }

    /// Reads the whole file `fd` from its start in chunks (`pread`, so where it was read to before does not matter), or
    /// its first `limit` bytes.
    private static func forEachChunk(
        of fd: Int32, upTo limit: Int = .max, _ body: (UnsafeRawBufferPointer) throws(POSIXError) -> Void
    ) throws(POSIXError) {
        let buffer = UnsafeMutableRawBufferPointer.allocate(byteCount: 1 << 20, alignment: 16)
        defer { buffer.deallocate() }
        var offset: off_t = 0
        while Int(offset) < limit {
            let count = pread(fd, buffer.baseAddress, min(buffer.count, limit - Int(offset)), offset)
            if count < 0 {
                if errno == EINTR { continue }
                throw posixError()
            }
            if count == 0 { return }
            try body(UnsafeRawBufferPointer(rebasing: buffer[..<count]))
            offset += off_t(count)
        }
    }

    /// The whole file `fd`, which `fstat` said is `size` bytes, or its first `limit` bytes.
    private static func readAll(_ fd: Int32, size: Int, atMost limit: Int = .max) throws(POSIXError) -> Data {
        var data = Data(capacity: size)
        try forEachChunk(of: fd, upTo: limit) { data.append(contentsOf: $0) }
        return data
    }
}

private func posixError() -> POSIXError {
    POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
}
