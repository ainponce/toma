// SPDX-License-Identifier: GPL-3.0-or-later
import Darwin
import Dispatch
import Foundation
import ProjectFormat

/// The default style the user saved ("Use This Style for New Projects", design §5.4): `default-style.json` in its
/// folder, `~/Library/Application Support/Toma/Style/`, written as the manifest is (`ProjectJSON.encoder()`,
/// `DurableFile.writeAtomically`). Its image background, an `image(file: "assets/<sha>.<ext>")` of the project it was
/// saved from, is copied next to it as `<sha>.<ext>`, so new projects can take it into their own `assets/`
/// (`EditSession.open`) under the same path.
///
/// `save` and `reset` write and full-sync, so they run on the store's own serial queue, one at a time and never on the
/// caller's thread (never the main thread's), each file through a temporary file of a name of its own.
public final class DefaultStyleStore: Sendable {
    /// `~/Library/Application Support/Toma/Style/`. Computed: a stored `static var` is not concurrency-safe.
    public static var defaultDirectory: URL {
        URL.applicationSupportDirectory.appending(path: "Toma", directoryHint: .isDirectory)
            .appending(path: "Style", directoryHint: .isDirectory)
    }

    public let directory: URL

    private static let fileName = "default-style.json"
    /// Where `save` and `reset` run, one at a time.
    private let queue = DispatchQueue(label: "dev.toma.DefaultStyleStore", qos: .userInitiated)

    public init(directory: URL) {
        self.directory = directory
    }

    /// The saved style; Toma's (`DefaultStyle.toma`) if none is saved or it cannot be read (never through a symlink nor
    /// blocked on a FIFO: `SafeRead.regularFile(at:)`) or decoded. An image background named anywhere but in `assets/`,
    /// by its exact rule (`PackageFileKind.asset`), is Toma's background: no path is built from it.
    public func load() -> DefaultStyle {
        guard let data = try? SafeRead.regularFile(at: directory.appending(path: Self.fileName)),
            var style = try? ProjectJSON.decoder().decode(DefaultStyle.self, from: data)
        else { return .toma }
        if case let .image(file) = style.style.background, Self.assetName(file) == nil {
            style.style.background = DefaultStyle.toma.style.background
        }
        return style
    }

    /// Saves `style` as the default. An image background `assets/<sha>.<ext>` is copied from `package` to `<sha>.<ext>` in
    /// the folder (once: the name is its content's) and saved with the same path; without `package`, or if the file cannot
    /// be read there (`SafePackageFile`, by the rules of `PackageFileKind.asset`), Toma's background is saved in its
    /// place. Then the folder keeps no other image. Throws what creating the folder or writing a file throws.
    public func save(_ style: DefaultStyle, from package: ProjectPackage?) async throws {
        try await onQueue { try self.write(style, from: package) }
    }

    /// Back to Toma's style: the saved style and its image go.
    public func reset() async throws {
        try await onQueue {
            guard unlink(self.directory.appending(path: Self.fileName).path) == 0 || errno == ENOENT else {
                throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
            }
            self.removeImages(except: nil)
        }
    }

    /// `save`, on the queue.
    private func write(_ style: DefaultStyle, from package: ProjectPackage?) throws {
        var style = style
        var image: String?
        if case let .image(file) = style.style.background {
            if let name = Self.assetName(file), let package, try copyImage(file, named: name, from: package) {
                image = name
            } else {
                style.style.background = DefaultStyle.toma.style.background
            }
        }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Self.writeAtomically(try ProjectJSON.encoder().encode(style), to: directory.appending(path: Self.fileName))
        removeImages(except: image)
    }

    // MARK: - What a new project takes

    /// The name `<sha>.<ext>` of an asset's path `assets/<sha>.<ext>`, if it is exactly one (`PackageFileKind.asset`).
    static func assetName(_ file: String) -> String? {
        let prefix = "assets/"
        guard file.hasPrefix(prefix) else { return nil }
        let name = String(file.dropFirst(prefix.count))
        return PackageFileKind.asset.isValidName(name) ? name : nil
    }

    /// The background a new document of `package` starts with for the default style's `background`: an image is copied
    /// from the style folder `directory` into the package's `assets/` (`AssetImport.copy`) and named where it is there, if
    /// it decodes as the package's asset reader decodes one; without the folder, or if it does not decode or cannot be
    /// copied, Toma's background. Anything else, as it is.
    static func background(_ background: Background, from directory: URL?, into package: ProjectPackage) -> Background {
        guard case let .image(file) = background else { return background }
        guard let directory, let name = assetName(file), case let url = directory.appending(path: name), AssetImport.decodes(url),
            let copied = try? AssetImport.copy(url, into: package)
        else { return DefaultStyle.toma.style.background }
        return .image(file: copied)
    }

    /// The background a new document that is not saved is shown with: never an image, which its package may not hold.
    static func unsavedBackground(_ background: Background) -> Background {
        if case .image = background { return DefaultStyle.toma.style.background }
        return background
    }

    // MARK: - Private

    /// Copies `file` of `package` to `name` in the folder, unless a regular file is there already; `false` if it cannot
    /// be read there.
    private func copyImage(_ file: String, named name: String, from package: ProjectPackage) throws -> Bool {
        let target = directory.appending(path: name)
        var info = stat()
        if lstat(target.path, &info) == 0, info.st_mode & S_IFMT == S_IFREG { return true }
        guard let data = SafePackageFile.read(file, in: package, as: .asset) else { return false }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Self.writeAtomically(data, to: target)
        return true
    }

    /// Runs `body` on the queue, and waits for it without blocking the caller's thread.
    private func onQueue(_ body: @escaping @Sendable () throws -> Void) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
            queue.async { continuation.resume(with: Result { try body() }) }
        }
    }

    /// Replaces `url` with `data` as `DurableFile.writeAtomically(_:to:)` does, through a temporary file of a name of its
    /// own (`.<name>.<UUID>.tmp`), so two writers never write one temporary file.
    private static func writeAtomically(_ data: Data, to url: URL) throws {
        let folder = url.deletingLastPathComponent()
        let temporary = folder.appending(path: ".\(url.lastPathComponent).\(UUID().uuidString).tmp")
        let fd = open(temporary.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o644)
        guard fd >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        do {
            try data.withUnsafeBytes { (bytes: UnsafeRawBufferPointer) in
                var written = 0
                while written < bytes.count {
                    let count = Darwin.write(fd, bytes.baseAddress! + written, bytes.count - written)
                    if count < 0 {
                        if errno == EINTR { continue }
                        throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
                    }
                    written += count
                }
            }
            try DurableFile.fullSync(fd)
        } catch {
            close(fd)
            unlink(temporary.path)
            throw error
        }
        close(fd)
        guard rename(temporary.path, url.path) == 0 else {
            let error = POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
            unlink(temporary.path)
            throw error
        }
        try DurableFile.syncDirectory(folder)
    }

    /// Removes the images of the folder, but `kept`: an earlier style's are no longer needed. What cannot be removed stays.
    private func removeImages(except kept: String?) {
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: directory.path) else { return }
        for name in names where name != kept && PackageFileKind.asset.isValidName(name) {
            unlink(directory.appending(path: name).path)
        }
    }
}
