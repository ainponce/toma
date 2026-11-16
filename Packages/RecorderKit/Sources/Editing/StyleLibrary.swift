// SPDX-License-Identifier: GPL-3.0-or-later
import CryptoKit
import Darwin
import Dispatch
import Foundation
import ProjectFormat

/// Why `StyleLibrary` did not do what it was asked.
public enum StyleLibraryError: Error, Equatable, Sendable {
    /// The package cannot be read as a style: its `style.json` is missing, a link, not a regular file (a FIFO), too large,
    /// unreadable or of a newer version, or the image its background names is not in its `assets/`, is a link or does not
    /// decode as a background's image.
    case damaged
    /// The library has no style of that id.
    case notFound
}

/// The user's named styles (1c design §8): a package `<id>.tomastyle` each in `directory`, holding its `style.json` and,
/// if its background is an image of the user's, that image in its `assets/` as a project holds it, `assets/<sha>.<ext>`
/// (plan decisions 29 and 30). A package can be sent to another Mac and imported there.
///
/// Every call but `list` and `imageDirectory` runs on one serial queue of the process, never on the caller's thread
/// (never the main thread's), one at a time. Files are written with `DurableFile.writeAtomically`; a new package is built
/// whole in a hidden folder of the library and moved in with one `rename`, so the library holds all of it or none; a
/// package is only ever removed by `delete`, which gives it to the macOS Trash. Nothing in a package is followed if it is
/// a link, and only an id of 8 lowercase hex digits names a package, so no path is built from what a file says.
public final class StyleLibrary: Sendable {
    /// `~/Library/Application Support/Toma/Styles/`. Computed: a stored `static var` is not concurrency-safe.
    public static var defaultDirectory: URL {
        URL.applicationSupportDirectory.appending(path: "Toma", directoryHint: .isDirectory)
            .appending(path: "Styles", directoryHint: .isDirectory)
    }

    /// The library's folder: the packages, and `.migrated-1b` once the style of 1b was looked for (plan decision 31).
    public let directory: URL
    private let trash: @Sendable (URL) throws -> Void

    private static let fileName = "style.json"
    private static let assetsFolder = "assets"
    private static let packageExtension = "tomastyle"
    private static let migratedMark = ".migrated-1b"
    /// The end of the name of the hidden folder a new package is built in.
    private static let stagingExtension = "staging"
    /// The largest `style.json` read: a style is a few kilobytes.
    private static let maxFileBytes = 1 << 20
    /// One queue for every library of the process: two libraries of one folder never write one file at once
    /// (`DurableFile` writes through a temporary file of a fixed name), and each call sees what the one before it wrote.
    private static let queue = DispatchQueue(label: "dev.toma.StyleLibrary", qos: .userInitiated)

    /// `trash` gives a package to the macOS Trash; tests pass their own, so nothing reaches the real one.
    public init(
        directory: URL,
        trash: @escaping @Sendable (URL) throws -> Void = { try FileManager.default.trashItem(at: $0, resultingItemURL: nil) }
    ) {
        self.directory = directory
        self.trash = trash
    }

    // MARK: - Reading

    /// The styles of the library, by name as Finder sorts names, then by id: each folder `<id>.tomastyle` (never a link)
    /// whose `style.json` reads (`SafeRead`) and decodes in version 1, with the id of its folder's name, the one every call
    /// finds it by. An image background named anywhere but in `assets/`, by its exact rule (`PackageFileKind.asset`), is
    /// Toma's background, as `DefaultStyleStore.load()` reads one. Reads the disk: call it off the main thread.
    public func list() -> [NamedStyle] {
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: directory.path) else { return [] }
        let styles = names.compactMap { name -> NamedStyle? in
            guard let id = Self.id(ofPackageNamed: name), Self.isFolder(packageURL(id)),
                var style = try? Self.readStyle(packageAt: packageURL(id))
            else { return nil }
            style.id = id
            if case let .image(file) = style.look.style.background, DefaultStyleStore.assetName(file) == nil {
                style.look.style.background = DefaultStyle.toma.style.background
            }
            return style
        }
        return styles.sorted { first, second in
            switch first.name.localizedStandardCompare(second.name) {
            case .orderedAscending: true
            case .orderedDescending: false
            case .orderedSame: first.id < second.id
            }
        }
    }

    /// The folder of `style`'s image, its package's `assets/`, where a new project or "Apply" finds `<sha>.<ext>` (plan
    /// decision 30). For Toma's style, a folder that is never there.
    public func imageDirectory(of style: NamedStyle) -> URL {
        packageURL(style.id).appending(path: Self.assetsFolder, directoryHint: .isDirectory)
    }

    // MARK: - Writing

    /// Saves `style` measured against the short side, whatever it says (1c design §8): over the package of its id, or as a
    /// new one. An image background `assets/<sha>.<ext>` goes to the package's `assets/` under that name: the package's
    /// own if it holds it already (the name is its content's), otherwise read from `package` (`SafePackageFile`, decoding
    /// as a background's image does); without it, Toma's background is saved in its place, as `DefaultStyleStore` does.
    /// Over a package, the image is written first and `style.json` then, so a crash leaves the old style or the new one,
    /// each with its image; the images it no longer names go after.
    ///
    /// Throws `EINVAL` for an id that is not 8 lowercase hex digits (Toma's style's), and what writing throws.
    public func save(_ style: NamedStyle, imageFrom package: ProjectPackage?) async throws {
        try await onQueue { try self.write(style, imageFrom: package) }
    }

    /// Gives the style of `id` the name `name`; nothing else of it changes. `notFound` if there is no such style, `damaged`
    /// if its `style.json` cannot be read.
    public func rename(id: String, to name: String) async throws {
        try await onQueue {
            let folder = try self.openPackage(id)
            defer { close(folder) }
            var style = try Self.readStyle(packageAt: self.packageURL(id))
            style.id = id
            style.name = name
            try DurableFile.writeAtomically(
                try ProjectJSON.encoder().encode(StyleFile(style)), named: Self.fileName, inDirectory: folder)
        }
    }

    /// A copy of the style of `id` named `name`, with its image, under a new id; the copy. `notFound` if there is no such
    /// style, `damaged` if it cannot be read as `importPackage` reads one.
    public func duplicate(id: String, name: String) async throws -> NamedStyle {
        try await onQueue {
            close(try self.openPackage(id))
            var contents = try Self.readPackage(at: self.packageURL(id))
            contents.style.name = name
            return try self.add(contents, keepingID: false)
        }
    }

    /// Gives the package of `id` to `trash` (the macOS Trash, where Finder can put it back). `notFound` if there is no such
    /// style; what `trash` throws, and the style stays.
    public func delete(id: String) async throws {
        try await onQueue {
            close(try self.openPackage(id))
            try self.trash(self.packageURL(id))
        }
    }

    /// Copies the `.tomastyle` package at `url` into the library, as it is: under its own id if that is free, otherwise
    /// under a new one; the style added. Read with the safe readers (`readPackage`): a link, a FIFO, a `style.json` that
    /// does not read or decode, or an image that `BoundedImage` does not decode throws `damaged`, and nothing is copied.
    /// The package at `url` is left as it is.
    public func importPackage(_ url: URL) async throws -> NamedStyle {
        try await onQueue { try self.add(try Self.readPackage(at: url), keepingID: true) }
    }

    /// The default style of 1b in `legacyDirectory` (`DefaultStyleStore`, read with its `load()`) as a style of the
    /// library named `name`, with the camera of a new project (`CameraLook.newProjects`, measured against the short side,
    /// 1c design §8) and its image; the style, which the app marks for new projects. Once: after the first call
    /// `.migrated-1b` is in the library and every later call gives `nil`. `nil` also if there is no style of 1b (none
    /// saved or one that cannot be read, which 1b took as Toma's, or Toma's own). The style of 1b is left where it is.
    ///
    /// Its image, `<sha>.<ext>` beside it, is read with `SafeRead`; if it is not there or does not decode, the style has
    /// Toma's background, as 1b gave its new projects. The id is the same for the same style, so a call that a crash cut
    /// short before `.migrated-1b` was written finds the style it wrote, and never makes a second one.
    public func migrateLegacyDefault(from legacyDirectory: URL, named name: String) async throws -> NamedStyle? {
        try await onQueue { try self.migrate(from: legacyDirectory, named: name) }
    }

    // MARK: - Private

    /// A style and its image, as a package holds them.
    private struct Contents {
        var style: NamedStyle
        var image: Image?
    }

    /// An image of a style: its name in `assets/`, and its bytes unless the package holds it already.
    private struct Image {
        var name: String
        var data: Data?
    }

    /// `save`, on the queue.
    private func write(_ style: NamedStyle, imageFrom package: ProjectPackage?) throws {
        guard Self.isID(style.id) else { throw POSIXError(.EINVAL) }
        var style = style
        style.camera.sizeReference = .shortSide
        let library = try openLibrary()
        defer { close(library) }
        let folder = openat(library, Self.packageName(style.id), O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard folder >= 0 else {
            guard errno == ENOENT else { throw posixError() }
            let image = Self.image(of: &style, from: package, in: nil)
            try create(Contents(style: style, image: image), in: library)
            return
        }
        defer { close(folder) }
        let image = Self.image(of: &style, from: package, in: folder)
        try Self.fill(folder, with: Contents(style: style, image: image))
    }

    /// `migrateLegacyDefault`, on the queue.
    private func migrate(from legacyDirectory: URL, named name: String) throws -> NamedStyle? {
        let library = try openLibrary()
        defer { close(library) }
        var info = stat()
        if fstatat(library, Self.migratedMark, &info, AT_SYMLINK_NOFOLLOW) == 0 { return nil }
        guard errno == ENOENT else { throw posixError() }
        var migrated: NamedStyle?
        let look = DefaultStyleStore(directory: legacyDirectory).load()
        if look != .toma {
            var style = NamedStyle(id: "", name: name, look: look, camera: .newProjects)
            let image = Self.legacyImage(of: &style, in: legacyDirectory)
            style.id = try Self.migratedID(of: style.look)
            migrated = try addMigrated(Contents(style: style, image: image), in: library)
        }
        try DurableFile.writeAtomically(Data(), named: Self.migratedMark, inDirectory: library)
        return migrated
    }

    /// Adds `contents` as a new package: under its own id if `keepingID` and it is one that is free, otherwise under a new
    /// one. The style as added.
    private func add(_ contents: Contents, keepingID: Bool) throws -> NamedStyle {
        let library = try openLibrary()
        defer { close(library) }
        var contents = contents
        if !keepingID || !Self.isID(contents.style.id) { contents.style.id = Self.newID() }
        // A new id is taken once in 2³² times per style; a few tries are always enough.
        for _ in 0..<16 {
            do {
                try create(contents, in: library)
                return contents.style
            } catch let error as POSIXError where error.code == .EEXIST {
                contents.style.id = Self.newID()
            }
        }
        throw POSIXError(.EEXIST)
    }

    /// Adds the migrated `contents` under its id. If a package has that id already and holds the same look and camera, a
    /// migration a crash cut short wrote it, and that is the style; otherwise it goes under a new id.
    private func addMigrated(_ contents: Contents, in library: Int32) throws -> NamedStyle {
        do {
            try create(contents, in: library)
            return contents.style
        } catch let error as POSIXError where error.code == .EEXIST {
            if var written = try? Self.readStyle(packageAt: packageURL(contents.style.id)),
                written.look == contents.style.look, written.camera == contents.style.camera
            {
                written.id = contents.style.id
                return written
            }
            return try add(contents, keepingID: false)
        }
    }

    /// Writes `contents` as the new package `<id>.tomastyle` of the library `library` is open on: built whole in a hidden
    /// folder of the library, full-synced, and moved in with `renameatx_np` and `RENAME_EXCL`, so the library holds all of
    /// the package or none of it. `EEXIST` if anything has its name. The hidden folder goes either way, and so do those a
    /// crash left: none holds the only copy of a style, which is in its source until the move.
    private func create(_ contents: Contents, in library: Int32) throws {
        let suffix = "." + Self.stagingExtension
        for name in (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
        where name.hasPrefix(".") && name.hasSuffix(suffix) {
            try? FileManager.default.removeItem(at: directory.appending(path: name))
        }
        let staging = ".\(contents.style.id)-\(UUID().uuidString)" + suffix
        guard mkdirat(library, staging, 0o755) == 0 else { throw posixError() }
        do {
            let folder = openat(library, staging, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            guard folder >= 0 else { throw posixError() }
            defer { close(folder) }
            try Self.fill(folder, with: contents)
            guard renameatx_np(library, staging, library, Self.packageName(contents.style.id), UInt32(RENAME_EXCL)) == 0 else {
                throw posixError()
            }
        } catch {
            try? FileManager.default.removeItem(at: directory.appending(path: staging))
            throw error
        }
        try DurableFile.fullSync(library)
    }

    /// Writes `contents` into the package folder `folder` is open on: its image's bytes to `assets/<name>` (`assets/` made
    /// and synced if it is not there, never followed if it is a link), then `style.json`, each with
    /// `DurableFile.writeAtomically`; then the images of `assets/` it does not name go, and `assets/` with them if it
    /// names none.
    private static func fill(_ folder: Int32, with contents: Contents) throws {
        if let image = contents.image, let data = image.data {
            let made = mkdirat(folder, assetsFolder, 0o755) == 0
            guard made || errno == EEXIST else { throw posixError() }
            let assets = openat(folder, assetsFolder, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            guard assets >= 0 else { throw posixError() }
            defer { close(assets) }
            if made { try DurableFile.fullSync(folder) }
            try DurableFile.writeAtomically(data, named: image.name, inDirectory: assets)
        }
        try DurableFile.writeAtomically(try ProjectJSON.encoder().encode(StyleFile(contents.style)), named: fileName, inDirectory: folder)
        removeImages(in: folder, except: contents.image?.name)
    }

    /// The image `style`'s background names, as `save` takes it: in the package `folder` is open on already, or read from
    /// `package`; otherwise `nil`, and Toma's background in `style` in its place.
    private static func image(of style: inout NamedStyle, from package: ProjectPackage?, in folder: Int32?) -> Image? {
        guard case let .image(file) = style.look.style.background else { return nil }
        if let name = DefaultStyleStore.assetName(file) {
            if let folder, holdsImage(name, in: folder) { return Image(name: name, data: nil) }
            if let package, let data = SafePackageFile.read(file, in: package, as: .asset), PackageFileKind.asset.decodedImage(data) != nil {
                return Image(name: name, data: data)
            }
        }
        style.look.style.background = DefaultStyle.toma.style.background
        return nil
    }

    /// The image of the style of 1b, `<sha>.<ext>` in its folder, if it reads (`SafeRead`, at most an asset's size) and
    /// decodes as a background's image; otherwise `nil`, and Toma's background in `style` in its place.
    private static func legacyImage(of style: inout NamedStyle, in legacyDirectory: URL) -> Image? {
        guard case let .image(file) = style.look.style.background else { return nil }
        if let name = DefaultStyleStore.assetName(file),
            let data = try? SafeRead.regularFile(at: legacyDirectory.appending(path: name), maxBytes: PackageFileKind.asset.maxBytes),
            PackageFileKind.asset.decodedImage(data) != nil
        {
            return Image(name: name, data: data)
        }
        style.look.style.background = DefaultStyle.toma.style.background
        return nil
    }

    /// The style of the package at `url` and its image, read with the safe readers: `readStyle`, and an image background
    /// only as `assets/<sha>.<ext>` (`PackageFileKind.asset`), read inside the package as a project's asset is, never
    /// through a link (`SafePackageFile`), and decoding as a background's image does (`BoundedImage`). `damaged`
    /// otherwise.
    private static func readPackage(at url: URL) throws(StyleLibraryError) -> Contents {
        let style = try readStyle(packageAt: url)
        guard case let .image(file) = style.look.style.background else { return Contents(style: style, image: nil) }
        guard let name = DefaultStyleStore.assetName(file),
            let data = SafePackageFile.read(file, in: ProjectPackage(url: url), as: .asset),
            PackageFileKind.asset.decodedImage(data) != nil
        else { throw .damaged }
        return Contents(style: style, image: Image(name: name, data: data))
    }

    /// The style in the `style.json` of the package at `url`: a regular file of at most `maxFileBytes`, never read through
    /// a link nor blocked on a FIFO (`SafeRead`), in version 1. `damaged` otherwise.
    private static func readStyle(packageAt url: URL) throws(StyleLibraryError) -> NamedStyle {
        guard let data = try? SafeRead.regularFile(at: url.appending(path: fileName), maxBytes: maxFileBytes),
            let file = try? ProjectJSON.decoder().decode(StyleFile.self, from: data), file.version == StyleFile.currentVersion
        else { throw .damaged }
        return file.namedStyle
    }

    /// The package of `id`, open. `notFound` if `id` is not an id or there is no folder of that name (a link is none).
    private func openPackage(_ id: String) throws -> Int32 {
        guard Self.isID(id) else { throw StyleLibraryError.notFound }
        let folder = open(packageURL(id).path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard folder >= 0 else {
            if errno == ENOENT || errno == ENOTDIR || errno == ELOOP { throw StyleLibraryError.notFound }
            throw posixError()
        }
        return folder
    }

    /// The library's folder, open; made first, with the folders above it, if it is not there.
    private func openLibrary() throws -> Int32 {
        if !FileManager.default.fileExists(atPath: directory.path) {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try DurableFile.syncDirectory(directory.deletingLastPathComponent())
        }
        let library = open(directory.path, O_RDONLY | O_DIRECTORY | O_CLOEXEC)
        guard library >= 0 else { throw posixError() }
        return library
    }

    /// Runs `body` on the queue, and waits for it without blocking the caller's thread.
    private func onQueue<T: Sendable>(_ body: @escaping @Sendable () throws -> T) async throws -> T {
        try await withCheckedThrowingContinuation { continuation in
            Self.queue.async { continuation.resume(with: Result { try body() }) }
        }
    }

    private func packageURL(_ id: String) -> URL {
        directory.appending(path: Self.packageName(id), directoryHint: .isDirectory)
    }

    private static func packageName(_ id: String) -> String { id + "." + packageExtension }

    /// The id of the package named `name`, if that is `<id>.tomastyle`.
    private static func id(ofPackageNamed name: String) -> String? {
        let suffix = "." + packageExtension
        guard name.hasSuffix(suffix) else { return nil }
        let id = String(name.dropLast(suffix.count))
        return isID(id) ? id : nil
    }

    /// Whether `id` is 8 lowercase hex digits, in ASCII: the only names of packages.
    private static func isID(_ id: String) -> Bool {
        let bytes = Array(id.utf8)
        return bytes.count == 8
            && bytes.allSatisfy { (UInt8(ascii: "0")...UInt8(ascii: "9")).contains($0) || (UInt8(ascii: "a")...UInt8(ascii: "f")).contains($0) }
    }

    /// 8 random lowercase hex digits, as `makeID` gives them.
    private static func newID() -> String {
        String(format: "%08x", UInt32.random(in: .min ... .max))
    }

    /// The id of the style migrated from `look`: the first 8 hex digits of the SHA-256 of its JSON, the same each time.
    private static func migratedID(of look: DefaultStyle) throws -> String {
        SHA256.hash(data: try ProjectJSON.encoder().encode(look)).prefix(4).map { String(format: "%02x", $0) }.joined()
    }

    /// Whether `url` is a folder, not a link to one.
    private static func isFolder(_ url: URL) -> Bool {
        var info = stat()
        return lstat(url.path, &info) == 0 && info.st_mode & S_IFMT == S_IFDIR
    }

    /// Whether the package `folder` is open on holds the regular file `assets/<name>`, never looked for through a link.
    private static func holdsImage(_ name: String, in folder: Int32) -> Bool {
        let assets = openat(folder, assetsFolder, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard assets >= 0 else { return false }
        defer { close(assets) }
        var info = stat()
        return fstatat(assets, name, &info, AT_SYMLINK_NOFOLLOW) == 0 && info.st_mode & S_IFMT == S_IFREG
    }

    /// Removes the images of the package's `assets/` but `kept`, and `assets/` if `kept` is `nil` and nothing else is in
    /// it. What cannot be removed stays: an image too many is never a style lost.
    private static func removeImages(in folder: Int32, except kept: String?) {
        let assets = openat(folder, assetsFolder, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard assets >= 0 else { return }
        guard let listing = fdopendir(assets) else {
            close(assets)
            return
        }
        var names: [String] = []
        while let entry = readdir(listing) {
            var raw = entry.pointee.d_name
            let length = Int(entry.pointee.d_namlen)
            names.append(withUnsafeBytes(of: &raw) { String(decoding: $0.prefix(length), as: UTF8.self) })
        }
        for name in names where name != kept && PackageFileKind.asset.isValidName(name) {
            unlinkat(dirfd(listing), name, 0)
        }
        closedir(listing)
        if kept == nil { unlinkat(folder, assetsFolder, AT_REMOVEDIR) }
    }
}

/// `style.json` (plan decision 29): the style, as `NamedStyle` encodes it, and the version of the file.
private struct StyleFile: Codable {
    static let currentVersion = 1

    var camera: CameraLook
    var id: String
    var name: String
    var style: DefaultStyle
    var version: Int

    init(_ style: NamedStyle) {
        camera = style.camera
        id = style.id
        name = style.name
        self.style = style.look
        version = Self.currentVersion
    }

    var namedStyle: NamedStyle { NamedStyle(id: id, name: name, look: style, camera: camera) }
}

private func posixError() -> POSIXError {
    POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
}
