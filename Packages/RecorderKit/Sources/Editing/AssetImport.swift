// SPDX-License-Identifier: GPL-3.0-or-later
import CryptoKit
import Darwin
import Foundation
import ProjectFormat

/// Why an image could not be copied into a package, besides the `POSIXError` of a file.
public enum AssetImportError: Error, Equatable, Sendable {
    /// The file's extension, lowercased, is not one of `AssetImport.allowedExtensions` (with `jpeg` as `jpg`).
    case unsupportedExtension(String)
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
    /// `<sha>.<ext>.tmp` by `fclonefileat` (an APFS clone; with `EXDEV` or `ENOTSUP`, a copy of its bytes), is full-synced,
    /// renamed to `<sha>.<ext>` with `renameat` (which replaces a link there, never follows it) and the folder synced, all
    /// before this returns: before the `set` that names it is logged.
    ///
    /// Throws `AssetImportError.unsupportedExtension` for another extension, `EFTYPE` for a file that is not a regular
    /// one, `EFBIG` for one too large, and the `POSIXError` of a call that fails.
    public static func copy(_ url: URL, into package: ProjectPackage) throws -> String {
        let ext = Self.extension(of: url)
        guard allowedExtensions.contains(ext) else { throw AssetImportError.unsupportedExtension(ext) }
        let source = try openSource(url)
        defer { close(source.fd) }
        let name = try hash(source.fd) + "." + ext
        guard PackageFileKind.asset.isValidName(name) else { throw POSIXError(.EINVAL) }

        let folder = open(package.url.path, O_RDONLY | O_DIRECTORY | O_CLOEXEC)
        guard folder >= 0 else { throw posixError() }
        defer { close(folder) }
        let made = mkdirat(folder, "assets", 0o755) == 0
        guard made || errno == EEXIST else { throw posixError() }
        let assets = openat(folder, "assets", O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard assets >= 0 else {
            // With `O_DIRECTORY`, a link says `ENOTDIR`: it is told as the link it is.
            let error = posixError()
            var info = stat()
            if error.code == .ENOTDIR, fstatat(folder, "assets", &info, AT_SYMLINK_NOFOLLOW) == 0, info.st_mode & S_IFMT == S_IFLNK {
                throw POSIXError(.ELOOP)
            }
            throw error
        }
        defer { close(assets) }
        if made { try DurableFile.fullSync(folder) }

        var info = stat()
        if fstatat(assets, name, &info, AT_SYMLINK_NOFOLLOW) == 0, info.st_mode & S_IFMT == S_IFREG, info.st_size == source.size {
            return "assets/" + name
        }
        let temporary = name + ".tmp"
        guard unlinkat(assets, temporary, 0) == 0 || errno == ENOENT else { throw posixError() }
        do {
            try place(source.fd, in: assets, as: temporary)
            guard renameat(assets, temporary, assets, name) == 0 else { throw posixError() }
        } catch {
            unlinkat(assets, temporary, 0)
            throw error
        }
        try DurableFile.fullSync(assets)
        return "assets/" + name
    }

    /// Whether the file at `url` is an image a render draws: read as `copy` reads it and decoded by `BoundedImage` as the
    /// package's asset reader decodes one (its formats, its size, reduced to 7 680 pixels).
    static func decodes(_ url: URL) -> Bool {
        guard let source = try? openSource(url) else { return false }
        defer { close(source.fd) }
        guard let data = try? readAll(source.fd, size: Int(source.size)) else { return false }
        let asset = PackageFileKind.asset
        return BoundedImage.decode(data, maxPixelSide: asset.maxPixelSide, reducedTo: 7_680, allowedTypes: asset.imageTypes) != nil
    }

    // MARK: - Private

    private static func `extension`(of url: URL) -> String {
        let ext = url.pathExtension.lowercased()
        return ext == "jpeg" ? "jpg" : ext
    }

    /// The user's file at `url`, opened for reading (never blocked on a FIFO), and its size: a regular file of at most
    /// `PackageFileKind.asset.maxBytes`.
    private static func openSource(_ url: URL) throws -> (fd: Int32, size: off_t) {
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
        guard info.st_size <= PackageFileKind.asset.maxBytes else {
            close(fd)
            throw POSIXError(.EFBIG)
        }
        return (fd, info.st_size)
    }

    /// The first 16 bytes of the SHA-256 of the whole file, in lowercase hex.
    private static func hash(_ fd: Int32) throws -> String {
        var hasher = SHA256()
        try forEachChunk(of: fd) { hasher.update(bufferPointer: $0) }
        return hasher.finalize().prefix(16).map { String(format: "%02x", $0) }.joined()
    }

    /// The file `source` as `name` in the folder `assets`, full-synced: a clone, or its bytes where a clone cannot be made.
    private static func place(_ source: Int32, in assets: Int32, as name: String) throws {
        if fclonefileat(source, assets, name, 0) == 0 {
            let clone = openat(assets, name, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
            guard clone >= 0 else { throw posixError() }
            defer { close(clone) }
            return try DurableFile.fullSync(clone)
        }
        guard errno == EXDEV || errno == ENOTSUP else { throw posixError() }
        let copy = openat(assets, name, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o644)
        guard copy >= 0 else { throw posixError() }
        defer { close(copy) }
        try forEachChunk(of: source) { chunk in
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
        try DurableFile.fullSync(copy)
    }

    /// Reads the whole file `fd` from its start in chunks (`pread`, so where it was read to before does not matter).
    private static func forEachChunk(of fd: Int32, _ body: (UnsafeRawBufferPointer) throws -> Void) throws {
        var buffer = [UInt8](repeating: 0, count: 1 << 20)
        var offset: off_t = 0
        while true {
            let count = buffer.withUnsafeMutableBytes { pread(fd, $0.baseAddress, $0.count, offset) }
            if count < 0 {
                if errno == EINTR { continue }
                throw posixError()
            }
            if count == 0 { return }
            try buffer.withUnsafeBytes { try body(UnsafeRawBufferPointer(rebasing: $0[..<count])) }
            offset += off_t(count)
        }
    }

    /// The whole file `fd`, which `fstat` said is `size` bytes.
    private static func readAll(_ fd: Int32, size: Int) throws -> Data {
        var data = Data(capacity: size)
        try forEachChunk(of: fd) { data.append(contentsOf: $0) }
        return data
    }
}

private func posixError() -> POSIXError {
    POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
}
