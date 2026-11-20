// SPDX-License-Identifier: GPL-3.0-or-later
import CoreGraphics
import CryptoKit
import Darwin
import Foundation
import ImageIO
import RecorderKitTestSupport
import Synchronization
import Testing
import UniformTypeIdentifiers
// Not @testable: the app uses only the public API.
import Editing
import ProjectFormat

/// What the tests of this file share.
private enum ImportFixture {
    static let app = AppInfo(name: "Toma", version: "0.2.0")
    static let base = HostTime(nanoseconds: 5_000_000_000_000)

    static func context(caches: URL) -> EditContext {
        let clock = Mutex(Date(timeIntervalSince1970: 1_794_773_523))
        let count = Mutex(0)
        return EditContext(
            app: app, cachesRoot: caches, defaultStyle: .toma,
            now: {
                clock.withLock { date in
                    defer { date += 2 }
                    return date
                }
            },
            makeID: { prefix in
                count.withLock { count in
                    count += 1
                    return prefix + String(format: "%08x", count)
                }
            })
    }

    /// A take of 1 s of one display with the cursor moving over it, in a new package `<name>.toma` of `formatVersion`.
    /// Written off the main actor, where the tests' sessions live.
    @concurrent static func package(in dir: URL, name: String = "Fixture", formatVersion: Int = 3) async throws -> LoadedProject {
        let builder = try TakeBuilder(in: dir, name: name, formatVersion: formatVersion)
        let frame = Rect(x: 0, y: 0, width: 640, height: 360)
        try await builder.addVideoTrack(
            id: "display-1", source: TrackSource(name: "Synthetic Display", displayID: 1, globalFrame: frame, pixelScale: 1),
            segments: [VideoSegmentSpec(start: base, seconds: 1, framesPerSecond: 10)])
        try builder.addEvents([InputEvent(t: base.adding(seconds: -0.01), kind: .displayGeometry(displayID: 1, frame: frame, scale: 1))])
        try builder.addEvents((0..<20).map { i in
            InputEvent(t: base.adding(seconds: Double(i) / 20), kind: .cursor(x: 100 + Double(i) * 10, y: 100))
        })
        return try builder.write()
    }

    /// A 32 × 32 image of `type`, filled with `red`.
    static func image(_ type: UTType = .png, red: Double = 0.8) throws -> Data {
        guard let context = CGContext(
            data: nil, width: 32, height: 32, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { throw TestSupportError.failed("no context") }
        context.setFillColor(CGColor(red: red, green: 0.3, blue: 0.5, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 32, height: 32))
        guard let image = context.makeImage() else { throw TestSupportError.failed("no image") }
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data as CFMutableData, type.identifier as CFString, 1, nil)
        else { throw TestSupportError.failed("no destination") }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else { throw TestSupportError.failed("no image file") }
        return data as Data
    }

    /// The name of an asset of `data`: 32 hex digits of its SHA-256.
    static func hash(_ data: Data) -> String {
        SHA256.hash(data: data).prefix(16).map { String(format: "%02x", $0) }.joined()
    }

    static func names(in folder: URL) throws -> [String] {
        try FileManager.default.contentsOfDirectory(atPath: folder.path).sorted()
    }

    static func manifest(_ package: ProjectPackage) throws -> Manifest {
        try ProjectJSON.decoder().decode(Manifest.self, from: Data(contentsOf: package.manifestURL))
    }

    @concurrent static func hash(_ package: ProjectPackage) async throws -> String {
        try treeHash(package.url)
    }

    /// The path of `.imported`, or a recorded issue.
    static func path(_ outcome: AssetImportOutcome, sourceLocation: SourceLocation = #_sourceLocation) -> String? {
        guard case let .imported(path) = outcome else {
            Issue.record("not imported: \(outcome)", sourceLocation: sourceLocation)
            return nil
        }
        return path
    }

    /// A switch the tests turn while a session reads it.
    final class Flag: Sendable {
        private let value: Mutex<Bool>

        init(_ value: Bool) {
            self.value = Mutex(value)
        }

        var isOn: Bool { value.withLock { $0 } }

        func set(_ on: Bool) { value.withLock { $0 = on } }
    }

    /// The system's upgrade calls, with every write failing with `ENOSPC` while `fails` is on.
    static func failingUpgrade(while fails: Flag) -> PackageUpgradeIO {
        PackageUpgradeIO(
            write: { data, name, directory in
                if fails.isOn { throw POSIXError(.ENOSPC) }
                try PackageUpgradeIO.system.write(data, name, directory)
            },
            pause: PackageUpgradeIO.system.pause)
    }

    /// Another process upgrades the version 1 or 2 package of `project`, as it was opened, with an edit of its own, and
    /// lets it go.
    @concurrent static func upgradeElsewhere(_ project: LoadedProject, caches: URL) async throws {
        let fd = open(project.package.url.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        defer { close(fd) }
        let legacy = EditDocument.legacy(for: project)
        let step = try #require(StyleCommands.set(legacy, "/style/padding", 0.3, label: .padding))
        let result = try PackageUpgrade.upgrade(
            project.package, folder: fd, opened: project.manifest, legacy: legacy, first: step, context: context(caches: caches))
        guard case let .upgraded(lock, _) = result else { throw TestSupportError.failed("not upgraded: \(result)") }
        lock.release()
    }

    /// Fills the volume `folder` is on with a file `filler` in it, until a write says it is full.
    @concurrent static func fill(_ folder: URL) async throws {
        let fd = open(folder.appending(path: "filler").path, O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC, 0o644)
        guard fd >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        defer { close(fd) }
        for size in [1 << 20, 1 << 12, 1 << 9] {
            let chunk = [UInt8](repeating: 0x2A, count: size)
            while chunk.withUnsafeBytes({ write(fd, $0.baseAddress, $0.count) }) == size {}
        }
        fsync(fd)
    }
}

@Test func importedImageIsCopiedOnceByContent() async throws {
    try await withTemporaryDirectory { dir in
        let project = try await ImportFixture.package(in: dir)
        let png = try ImportFixture.image()
        let first = dir.appending(path: "Background.png"), second = dir.appending(path: "Copy of Background.PNG")
        try png.write(to: first)
        try png.write(to: second)

        let path = try AssetImport.copy(first, into: project.package)
        #expect(path == "assets/\(ImportFixture.hash(png)).png")
        let name = String(path.dropFirst("assets/".count))
        #expect(PackageFileKind.asset.isValidName(name))
        // The same content again, under another name: the file that is there.
        #expect(try AssetImport.copy(second, into: project.package) == path)
        #expect(try ImportFixture.names(in: project.package.assetsURL) == [name])
        #expect(try Data(contentsOf: project.package.fileURL(path)) == png)
        #expect(project.package.asset(path) != nil)

        // A JPEG is a `.jpg`, however it is named.
        let jpeg = try ImportFixture.image(.jpeg)
        let photo = dir.appending(path: "Photo.JPEG")
        try jpeg.write(to: photo)
        #expect(try AssetImport.copy(photo, into: project.package) == "assets/\(ImportFixture.hash(jpeg)).jpg")

        // Copied as they are, only PNG, JPEG and HEIC, the images a package's asset decodes as; a TIFF, a GIF or a PDF
        // is converted (`ImageImportFormatsTests`), and only if it is one: a PNG named `.gif` is not.
        #expect(AssetImport.allowedExtensions == ["png", "jpg", "heic"])
        for (file, type) in [("Clip.mov", "mov"), ("Notes", "")] {
            let url = dir.appending(path: file)
            try png.write(to: url)
            #expect(throws: AssetImportError.unsupportedExtension(type)) { try AssetImport.copy(url, into: project.package) }
        }
        for file in ["Animation.gif", "Scan.tiff", "Scan.tif", "Slides.pdf"] {
            let url = dir.appending(path: file)
            try png.write(to: url)
            #expect(throws: POSIXError(.EFTYPE)) { try AssetImport.copy(url, into: project.package) }
        }
        // Larger than an asset is read: never copied.
        let huge = dir.appending(path: "Huge.png")
        let fd = open(huge.path, O_WRONLY | O_CREAT | O_EXCL, 0o644)
        #expect(fd >= 0)
        #expect(ftruncate(fd, off_t(PackageFileKind.asset.maxBytes + 1)) == 0)
        close(fd)
        #expect(throws: POSIXError(.EFBIG)) { try AssetImport.copy(huge, into: project.package) }
        #expect(try ImportFixture.names(in: project.package.assetsURL).count == 2)
    }
}

@Test func importNeverFollowsALinkedAssetsFolder() async throws {
    try await withTemporaryDirectory { dir in
        let project = try await ImportFixture.package(in: dir)
        let outside = dir.appending(path: "Outside", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: false)
        try FileManager.default.createSymbolicLink(at: project.package.assetsURL, withDestinationURL: outside)
        let png = try ImportFixture.image()
        let image = dir.appending(path: "Background.png")
        try png.write(to: image)

        #expect(throws: POSIXError(.ELOOP)) { try AssetImport.copy(image, into: project.package) }
        #expect(try ImportFixture.names(in: outside).isEmpty)

        // Links at the image's name and at its temporary name are replaced, never written through.
        try FileManager.default.removeItem(at: project.package.assetsURL)
        try FileManager.default.createDirectory(at: project.package.assetsURL, withIntermediateDirectories: false)
        let target = outside.appending(path: "target.png"), spare = outside.appending(path: "spare.png")
        try Data("not this".utf8).write(to: target)
        try Data("nor this".utf8).write(to: spare)
        let name = "\(ImportFixture.hash(png)).png"
        try FileManager.default.createSymbolicLink(at: project.package.assetsURL.appending(path: name), withDestinationURL: target)
        try FileManager.default.createSymbolicLink(at: project.package.assetsURL.appending(path: name + ".tmp"), withDestinationURL: spare)
        #expect(try AssetImport.copy(image, into: project.package) == "assets/\(name)")
        #expect(try ImportFixture.names(in: project.package.assetsURL) == [name])
        var info = stat()
        #expect(lstat(project.package.assetsURL.appending(path: name).path, &info) == 0)
        #expect(info.st_mode & S_IFMT == S_IFREG)
        #expect(try Data(contentsOf: project.package.assetsURL.appending(path: name)) == png)
        #expect(try Data(contentsOf: target) == Data("not this".utf8))
        #expect(try Data(contentsOf: spare) == Data("nor this".utf8))
    }
}

@Test func importIntoAnotherVolumeCopiesByHand() throws {
    try withTemporaryDirectory { dir in
        // HFS+ cannot clone, and a clone never crosses volumes: the bytes are copied.
        let disk = try DiskImage.attach(sizeMegabytes: 20, fileSystem: .hfsPlus, in: dir)
        defer { try? disk.detach(force: true) }
        let package = ProjectPackage(url: disk.mountPoint.appending(path: "Elsewhere.toma", directoryHint: .isDirectory))
        try FileManager.default.createDirectory(at: package.url, withIntermediateDirectories: false)
        let png = try ImportFixture.image(red: 0.2)
        let image = dir.appending(path: "Background.png")
        try png.write(to: image)
        let path = try AssetImport.copy(image, into: package)
        #expect(path == "assets/\(ImportFixture.hash(png)).png")
        #expect(try Data(contentsOf: package.fileURL(path)) == png)
        #expect(try ImportFixture.names(in: package.assetsURL) == [String(path.dropFirst("assets/".count))])
    }
}

@MainActor @Test func importAssetCopiesOnlyWhatARenderDraws() async throws {
    try await withTemporaryDirectory { dir in
        let project = try await ImportFixture.package(in: dir)
        let caches = dir.appending(path: "Caches")
        let session = try await EditSession.open(project.package.url, take: nil, context: ImportFixture.context(caches: caches))
        #expect(session.access == .editable)
        // Not an image, or not there: nothing is written.
        let garbage = dir.appending(path: "Garbage.png")
        try Data((0..<4_096).map { UInt8(truncatingIfNeeded: $0 &* 31) }).write(to: garbage)
        #expect(await session.importAsset(garbage) == .notAnImage)
        #expect(await session.importAsset(dir.appending(path: "Missing.png")) == .notAnImage)
        #expect(!FileManager.default.fileExists(atPath: project.package.assetsURL.path))
        // An image: its path, and the file there before the step that names it.
        let png = try ImportFixture.image()
        let image = dir.appending(path: "Background.png")
        try png.write(to: image)
        #expect(await session.importAsset(image) == .imported("assets/\(ImportFixture.hash(png)).png"))
        let path = "assets/\(ImportFixture.hash(png)).png"
        #expect(try Data(contentsOf: project.package.fileURL(path)) == png)
        let step = try #require(StyleCommands.set(session.document, "/style/background", Background.image(file: path), label: .background))
        #expect(session.perform(step) == .applied)
        #expect(session.notices.isEmpty)

        // Read-only, or closed: nothing.
        let other = try await EditSession.open(project.package.url, take: nil, context: ImportFixture.context(caches: caches))
        #expect(other.access == .readOnly(.openElsewhere))
        let another = dir.appending(path: "Another.png")
        try ImportFixture.image(red: 0.1).write(to: another)
        #expect(await other.importAsset(another) == .notEditable)
        await other.close()
        await session.close()
        #expect(await session.importAsset(another) == .notEditable)
        #expect(try ImportFixture.names(in: project.package.assetsURL) == [String(path.dropFirst("assets/".count))])
    }
}

@MainActor @Test func importOnAFullDiskWaitsAndIsTriedAgain() async throws {
    try await withTemporaryDirectory { dir in
        // A version 3 package on a small HFS+ volume, full once the session is open.
        let disk = try DiskImage.attach(sizeMegabytes: 20, fileSystem: .hfsPlus, in: dir)
        defer { try? disk.detach(force: true) }
        let project = try await ImportFixture.package(in: disk.mountPoint)
        let session = try await EditSession.open(
            project.package.url, take: nil, context: ImportFixture.context(caches: dir.appending(path: "Caches")))
        #expect(await session.flushed() == 1)
        try await ImportFixture.fill(disk.mountPoint)
        let png = try ImportFixture.image()
        let image = dir.appending(path: "Background.png")
        try png.write(to: image)

        // A full disk is not "not an image": it is shown, and the import waits.
        let importing = Task { await session.importAsset(image) }
        #expect(await eventually(timeout: .seconds(20)) { session.notices.contains(.saveFailed(.ENOSPC)) })
        try FileManager.default.removeItem(at: disk.mountPoint.appending(path: "filler"))
        let path = "assets/\(ImportFixture.hash(png)).png"
        #expect(await importing.value == .imported(path))
        #expect(try Data(contentsOf: project.package.fileURL(path)) == png)
        #expect(!session.notices.contains { if case .saveFailed = $0 { true } else { false } })

        // Given up by its caller, it says why.
        try await ImportFixture.fill(disk.mountPoint)
        let another = dir.appending(path: "Another.png")
        try ImportFixture.image(red: 0.1).write(to: another)
        let cancelled = Task { await session.importAsset(another) }
        #expect(await eventually(timeout: .seconds(20)) { session.notices.contains(.saveFailed(.ENOSPC)) })
        cancelled.cancel()
        #expect(await cancelled.value == .saveFailed(.ENOSPC))
        #expect(!session.notices.contains { if case .saveFailed = $0 { true } else { false } })
        try FileManager.default.removeItem(at: disk.mountPoint.appending(path: "filler"))
        await session.close()
    }
}

@MainActor @Test func importIntoALegacyPackageUpgradesFirst() async throws {
    try await withTemporaryDirectory { dir in
        let project = try await ImportFixture.package(in: dir, formatVersion: 2)
        let session = try await EditSession.open(
            project.package.url, take: nil, context: ImportFixture.context(caches: dir.appending(path: "Caches")))
        let png = try ImportFixture.image()
        let image = dir.appending(path: "Background.png")
        try png.write(to: image)

        let path = try #require(ImportFixture.path(await session.importAsset(image)))
        #expect(await session.flushed() == 1)
        // Version 3, with a log of one line: the legacy document's `create`, without a `do`.
        let manifest = try ImportFixture.manifest(project.package)
        #expect(manifest.formatVersion == 3)
        #expect(manifest.upgradedFrom == 2)
        #expect(manifest.takes == project.manifest.takes)
        var created = EditDocument.legacy(for: project)
        created.logSequence = 1
        #expect(try EditLogReader.read(project.package.editLogURL).entries == [.create(seq: 1, document: created, app: ImportFixture.app)])
        #expect(try Data(contentsOf: project.package.fileURL(path)) == png)
        #expect(session.access == .editable)
        #expect(session.document == created)
        // At version 3 with a log, as after a first edit, it is not shown as a project without edits.
        #expect(session.notices.isEmpty)
        #expect(session.undoLabel == nil)

        // The step that names it goes on as in any version 3 project.
        let step = try #require(StyleCommands.set(session.document, "/style/background", Background.image(file: path), label: .background))
        #expect(session.perform(step) == .applied)
        #expect(await session.flushed() == 2)
        #expect(session.undoLabel == .background)
        await session.close()
        let reopened = try await EditSession.open(
            project.package.url, take: nil, context: ImportFixture.context(caches: dir.appending(path: "Caches")))
        #expect(reopened.document.style.background == .image(file: path))
        await reopened.close()
    }

    // Another process took `edit.lock` after this one opened: nothing is written, and the project is read-only.
    try await withTemporaryDirectory { dir in
        let project = try await ImportFixture.package(in: dir, formatVersion: 2)
        let session = try await EditSession.open(
            project.package.url, take: nil, context: ImportFixture.context(caches: dir.appending(path: "Caches")))
        let other = try RecordingLock.acquire(at: project.package.editLockURL, info: .current(now: Date()))
        defer { other.release() }
        let before = try await ImportFixture.hash(project.package)
        let image = dir.appending(path: "Background.png")
        try ImportFixture.image().write(to: image)

        #expect(await session.importAsset(image) == .notEditable)
        #expect(session.access == .readOnly(.otherAppStartedEditing))
        #expect(session.document == .legacy(for: project))
        #expect(try await ImportFixture.hash(project.package) == before)
        await session.close()
        #expect(try await ImportFixture.hash(project.package) == before)
    }
}

@MainActor @Test func aFailedUpgradeOfAnImportIsTriedAgain() async throws {
    try await withTemporaryDirectory { dir in
        let project = try await ImportFixture.package(in: dir, formatVersion: 2)
        let fails = ImportFixture.Flag(true)
        var context = ImportFixture.context(caches: dir.appending(path: "Caches"))
        context.upgradeIO = ImportFixture.failingUpgrade(while: fails)
        let session = try await EditSession.open(project.package.url, take: nil, context: context)
        let png = try ImportFixture.image()
        let image = dir.appending(path: "Background.png")
        try png.write(to: image)

        // The disk is full: the upgrade waits and is tried again, and the import with it; nothing is copied into the
        // version 2 package meanwhile.
        let importing = Task { await session.importAsset(image) }
        #expect(await eventually(timeout: .seconds(20)) { session.notices.contains(.saveFailed(.ENOSPC)) })
        #expect(session.access == .editable)
        #expect(!FileManager.default.fileExists(atPath: project.package.assetsURL.path))
        #expect(try ImportFixture.manifest(project.package).formatVersion == 2)
        fails.set(false)
        let path = "assets/\(ImportFixture.hash(png)).png"
        #expect(await importing.value == .imported(path))
        #expect(try ImportFixture.manifest(project.package).formatVersion == 3)
        #expect(try EditLogReader.read(project.package.editLogURL).entries.count == 1)
        #expect(try Data(contentsOf: project.package.fileURL(path)) == png)
        #expect(session.notices.isEmpty)
        await session.close()
    }

    // Given up by its caller while the upgrade still fails: it says why, and the upgrade goes on being tried.
    try await withTemporaryDirectory { dir in
        let project = try await ImportFixture.package(in: dir, formatVersion: 2)
        let fails = ImportFixture.Flag(true)
        var context = ImportFixture.context(caches: dir.appending(path: "Caches"))
        context.upgradeIO = ImportFixture.failingUpgrade(while: fails)
        let session = try await EditSession.open(project.package.url, take: nil, context: context)
        let image = dir.appending(path: "Background.png")
        try ImportFixture.image().write(to: image)
        let importing = Task { await session.importAsset(image) }
        #expect(await eventually(timeout: .seconds(20)) { session.notices.contains(.saveFailed(.ENOSPC)) })
        importing.cancel()
        #expect(await importing.value == .saveFailed(.ENOSPC))
        #expect(!FileManager.default.fileExists(atPath: project.package.assetsURL.path))
        fails.set(false)
        #expect(await eventually(timeout: .seconds(20)) { session.notices.isEmpty })
        #expect(try ImportFixture.manifest(project.package).formatVersion == 3)
        await session.close()
    }
}

@MainActor @Test func importIntoAPackageAnotherAppChangedOpensItAgain() async throws {
    try await withTemporaryDirectory { dir in
        let project = try await ImportFixture.package(in: dir, formatVersion: 2)
        let caches = dir.appending(path: "Caches")
        let session = try await EditSession.open(project.package.url, take: nil, context: ImportFixture.context(caches: caches))
        // Another process upgrades the package with an edit of its own after this one opened, and lets it go.
        try await ImportFixture.upgradeElsewhere(project, caches: caches)
        let image = dir.appending(path: "Background.png")
        try ImportFixture.image().write(to: image)

        #expect(await session.importAsset(image) == .notEditable)
        #expect(session.notices.contains(.reopenedAfterOtherApp))
        #expect(session.document.style.padding == 0.3)
        #expect(!FileManager.default.fileExists(atPath: project.package.assetsURL.path))
        #expect(try EditLogReader.read(project.package.editLogURL).entries.count == 2)
        // It is a version 3 project now: the next import goes in.
        #expect(ImportFixture.path(await session.importAsset(image)) != nil)
        await session.close()
    }
}
