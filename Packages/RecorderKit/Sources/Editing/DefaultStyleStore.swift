// SPDX-License-Identifier: GPL-3.0-or-later
import Darwin
import Foundation
import ProjectFormat

/// The default style the user saved ("Use This Style for New Projects", design §5.4): `default-style.json` in its
/// folder, `~/Library/Application Support/Toma/Style/`, written as the manifest is (`ProjectJSON.encoder()`,
/// `DurableFile.writeAtomically`). Its image background, an `image(file: "assets/<sha>.<ext>")` of the project it was
/// saved from, is copied next to it as `<sha>.<ext>`, so new projects can take it into their own `assets/`
/// (`EditSession.open`) under the same path.
public final class DefaultStyleStore: Sendable {
    /// `~/Library/Application Support/Toma/Style/`. Computed: a stored `static var` is not concurrency-safe.
    public static var defaultDirectory: URL {
        URL.applicationSupportDirectory.appending(path: "Toma", directoryHint: .isDirectory)
            .appending(path: "Style", directoryHint: .isDirectory)
    }

    public let directory: URL

    private static let fileName = "default-style.json"

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
    public func save(_ style: DefaultStyle, from package: ProjectPackage?) throws {
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
        try DurableFile.writeAtomically(try ProjectJSON.encoder().encode(style), to: directory.appending(path: Self.fileName))
        removeImages(except: image)
    }

    /// Back to Toma's style: the saved style and its image go.
    public func reset() throws {
        guard unlink(directory.appending(path: Self.fileName).path) == 0 || errno == ENOENT else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        removeImages(except: nil)
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
    /// from the style folder `directory` into the package's `assets/` (`AssetImport.copy`) and named where it is there;
    /// without the folder, or if it cannot be copied, Toma's background. Anything else, as it is.
    static func background(_ background: Background, from directory: URL?, into package: ProjectPackage) -> Background {
        guard case let .image(file) = background else { return background }
        guard let directory, let name = assetName(file),
            let copied = try? AssetImport.copy(directory.appending(path: name), into: package)
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
        try DurableFile.writeAtomically(data, to: target)
        return true
    }

    /// Removes the images of the folder, but `kept`: an earlier style's are no longer needed. What cannot be removed stays.
    private func removeImages(except kept: String?) {
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: directory.path) else { return }
        for name in names where name != kept && PackageFileKind.asset.isValidName(name) {
            unlink(directory.appending(path: name).path)
        }
    }
}
