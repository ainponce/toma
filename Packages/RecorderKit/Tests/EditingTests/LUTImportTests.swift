// SPDX-License-Identifier: GPL-3.0-or-later
import CryptoKit
import Darwin
import Foundation
import ProjectFormat
import RecorderKitTestSupport
import Synchronization
import Testing
// `@testable` only for `AssetImport.place`'s folder sync, the moment between a `.cube`'s hash and its copy.
@testable import Editing

/// What the tests of this file share.
private enum LUTFixture {
    static let base = HostTime(nanoseconds: 5_000_000_000_000)

    static func context(caches: URL) -> EditContext {
        let clock = Mutex(Date(timeIntervalSince1970: 1_794_773_523))
        let count = Mutex(0)
        return EditContext(
            app: AppInfo(name: "Toma", version: "0.2.0"), cachesRoot: caches, defaultStyle: .toma,
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

    /// A take of 1 s of one display, in a new package `Fixture.toma` of `formatVersion`.
    @concurrent static func package(in dir: URL, formatVersion: Int = 3) async throws -> LoadedProject {
        let builder = try TakeBuilder(in: dir, name: "Fixture", formatVersion: formatVersion)
        let frame = Rect(x: 0, y: 0, width: 640, height: 360)
        try await builder.addVideoTrack(
            id: "display-1", source: TrackSource(name: "Synthetic Display", displayID: 1, globalFrame: frame, pixelScale: 1),
            segments: [VideoSegmentSpec(start: base, seconds: 1, framesPerSecond: 10)])
        try builder.addEvents([InputEvent(t: base.adding(seconds: -0.01), kind: .displayGeometry(displayID: 1, frame: frame, scale: 1))])
        return try builder.write()
    }

    /// A 3D `.cube` of 2³ whose every row is `row`, with a title.
    static func cube(_ row: String = "0 0 0") -> Data {
        Data(("TITLE \"Fixture\"\r\nLUT_3D_SIZE 2\r\n" + String(repeating: row + "\r\n", count: 8)).utf8)
    }

    /// A 1D `.cube`.
    static let oneDimensional = Data("LUT_1D_SIZE 2\n0 0 0\n1 1 1\n".utf8)

    /// The name of an asset of `data`: 32 hex digits of its SHA-256.
    static func hash(_ data: Data) -> String {
        SHA256.hash(data: data).prefix(16).map { String(format: "%02x", $0) }.joined()
    }

    static func names(in folder: URL) throws -> [String] {
        try FileManager.default.contentsOfDirectory(atPath: folder.path).sorted()
    }

    @concurrent static func treeHash(of package: ProjectPackage) async throws -> String {
        try RecorderKitTestSupport.treeHash(package.url)
    }

    static func manifest(_ package: ProjectPackage) throws -> Manifest {
        try ProjectJSON.decoder().decode(Manifest.self, from: Data(contentsOf: package.manifestURL))
    }

    /// The inode of the file at `url`, without following a link.
    static func inode(_ url: URL) -> ino_t? {
        var info = stat()
        return lstat(url.path, &info) == 0 ? info.st_ino : nil
    }
}

@MainActor @Test func lutIsCopiedByItsContent() async throws {
    try await withTemporaryDirectory { dir in
        let project = try await LUTFixture.package(in: dir)
        let session = try await EditSession.open(
            project.package.url, take: nil, context: LUTFixture.context(caches: dir.appending(path: "Caches")))
        let cube = LUTFixture.cube("0.25 0.5 0.75")
        let first = dir.appending(path: "Teal and Orange.cube"), second = dir.appending(path: "Copy.CUBE")
        try cube.write(to: first)
        try cube.write(to: second)

        let path = "assets/\(LUTFixture.hash(cube)).cube"
        #expect(await session.importAsset(first, kind: .lut) == .imported(path))
        let name = String(path.dropFirst("assets/".count))
        #expect(PackageFileKind.lut.isValidName(name))
        #expect(try LUTFixture.names(in: project.package.assetsURL) == [name])
        #expect(try Data(contentsOf: project.package.fileURL(path)) == cube)
        // Read back as the render reads it: through the safe reader, then parsed.
        let read = try #require(SafePackageFile.read(path, in: project.package, as: .lut))
        #expect(try CubeLUT.parse(read).values == Array(repeating: SIMD3(0.25, 0.5, 0.75), count: 8))

        // The same content again, under another name: the file that is there, not copied again.
        let inode = LUTFixture.inode(project.package.fileURL(path))
        #expect(await session.importAsset(second, kind: .lut) == .imported(path))
        #expect(try LUTFixture.names(in: project.package.assetsURL) == [name])
        #expect(LUTFixture.inode(project.package.fileURL(path)) == inode)
        #expect(session.notices.isEmpty)
        await session.close()

        // `copyLUT` is the same copy, without a session.
        let other = LUTFixture.cube("1 1 1")
        let third = dir.appending(path: "White.cube")
        try other.write(to: third)
        #expect(try AssetImport.copyLUT(third, into: project.package) == "assets/\(LUTFixture.hash(other)).cube")
        #expect(try AssetImport.copyLUT(first, into: project.package) == path)
        #expect(try LUTFixture.names(in: project.package.assetsURL).count == 2)
    }
}

@MainActor @Test func aBrokenCubeWritesNothing() async throws {
    try await withTemporaryDirectory { dir in
        let project = try await LUTFixture.package(in: dir)
        let session = try await EditSession.open(
            project.package.url, take: nil, context: LUTFixture.context(caches: dir.appending(path: "Caches")))
        _ = await session.flushed()
        let before = try await LUTFixture.treeHash(of: project.package)

        // Each with its reason, and the package as it was.
        let oneD = dir.appending(path: "Curve.cube")
        try LUTFixture.oneDimensional.write(to: oneD)
        #expect(await session.importAsset(oneD, kind: .lut) == .notALUT(.oneDimensional))
        let short = dir.appending(path: "Short.cube")
        try Data("LUT_3D_SIZE 2\n0 0 0\n".utf8).write(to: short)
        #expect(await session.importAsset(short, kind: .lut) == .notALUT(.wrongCount(expected: 8, found: 1)))
        let png = dir.appending(path: "Picture.cube")
        try Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 0x00, 0x00, 0x00, 0x0D]).write(to: png)
        #expect(await session.importAsset(png, kind: .lut) == .notALUT(.notText))
        // Larger than a `.cube` is read: refused for its size, never read whole.
        let huge = dir.appending(path: "Huge.cube")
        let fd = open(huge.path, O_WRONLY | O_CREAT | O_EXCL, 0o644)
        #expect(fd >= 0)
        #expect(ftruncate(fd, off_t(PackageFileKind.lut.maxBytes + 1)) == 0)
        close(fd)
        #expect(await session.importAsset(huge, kind: .lut) == .notALUT(.tooLarge))
        #expect(throws: CubeLUTError.tooLarge) { try AssetImport.copyLUT(huge, into: project.package) }
        #expect(throws: CubeLUTError.oneDimensional) { try AssetImport.copyLUT(oneD, into: project.package) }

        // Not a `.cube` by its name, not there, or not a regular file: it cannot be opened as one.
        let named = dir.appending(path: "Look.txt")
        try LUTFixture.cube().write(to: named)
        #expect(await session.importAsset(named, kind: .lut) == .notAnImage)
        #expect(throws: AssetImportError.unsupportedExtension("txt")) { try AssetImport.copyLUT(named, into: project.package) }
        #expect(await session.importAsset(dir.appending(path: "Missing.cube"), kind: .lut) == .notAnImage)
        let folder = dir.appending(path: "Folder.cube", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
        #expect(await session.importAsset(folder, kind: .lut) == .notAnImage)
        let fifo = dir.appending(path: "Pipe.cube")
        #expect(mkfifo(fifo.path, 0o644) == 0)
        #expect(await session.importAsset(fifo, kind: .lut) == .notAnImage)
        // A `.cube` is never an image, nor an image a LUT.
        let good = dir.appending(path: "Good.cube")
        try LUTFixture.cube().write(to: good)
        #expect(await session.importAsset(good) == .notAnImage)
        #expect(await session.importAsset(good, kind: .image) == .notAnImage)

        #expect(!FileManager.default.fileExists(atPath: project.package.assetsURL.path))
        #expect(try await LUTFixture.treeHash(of: project.package) == before)
        #expect(session.notices.isEmpty)
        await session.close()
    }

    // In a version 2 package, a broken `.cube` does not upgrade it.
    try await withTemporaryDirectory { dir in
        let project = try await LUTFixture.package(in: dir, formatVersion: 2)
        let session = try await EditSession.open(
            project.package.url, take: nil, context: LUTFixture.context(caches: dir.appending(path: "Caches")))
        let before = try await LUTFixture.treeHash(of: project.package)
        let oneD = dir.appending(path: "Curve.cube")
        try LUTFixture.oneDimensional.write(to: oneD)
        #expect(await session.importAsset(oneD, kind: .lut) == .notALUT(.oneDimensional))
        #expect(try LUTFixture.manifest(project.package).formatVersion == 2)
        #expect(try await LUTFixture.treeHash(of: project.package) == before)

        // A good one upgrades it first, as an image does.
        let cube = LUTFixture.cube()
        let good = dir.appending(path: "Good.cube")
        try cube.write(to: good)
        #expect(await session.importAsset(good, kind: .lut) == .imported("assets/\(LUTFixture.hash(cube)).cube"))
        #expect(await session.flushed() == 1)
        #expect(try LUTFixture.manifest(project.package).formatVersion == 3)
        await session.close()
    }
}

@MainActor @Test func aLinkInAssetsIsNeverFollowed() async throws {
    try await withTemporaryDirectory { dir in
        let project = try await LUTFixture.package(in: dir)
        let outside = dir.appending(path: "Outside", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: false)
        let kept = outside.appending(path: "kept.txt")
        try Data("untouched".utf8).write(to: kept)
        try FileManager.default.createSymbolicLink(at: project.package.assetsURL, withDestinationURL: outside)
        let cube = LUTFixture.cube()
        let url = dir.appending(path: "Look.cube")
        try cube.write(to: url)

        let session = try await EditSession.open(
            project.package.url, take: nil, context: LUTFixture.context(caches: dir.appending(path: "Caches")))
        #expect(await session.importAsset(url, kind: .lut) == .saveFailed(.ELOOP))
        #expect(throws: POSIXError(.ELOOP)) { try AssetImport.copyLUT(url, into: project.package) }
        #expect(try LUTFixture.names(in: outside) == ["kept.txt"])
        #expect(try Data(contentsOf: kept) == Data("untouched".utf8))
        await session.close()

        // A link at the `.cube`'s name, or at its temporary name, is replaced, never written through; and the reader
        // never follows one.
        try FileManager.default.removeItem(at: project.package.assetsURL)
        try FileManager.default.createDirectory(at: project.package.assetsURL, withIntermediateDirectories: false)
        let name = "\(LUTFixture.hash(cube)).cube"
        let target = outside.appending(path: "target.cube"), spare = outside.appending(path: "spare.cube")
        try LUTFixture.cube("1 1 1").write(to: target)
        try Data("nor this".utf8).write(to: spare)
        try FileManager.default.createSymbolicLink(at: project.package.assetsURL.appending(path: name), withDestinationURL: target)
        #expect(SafePackageFile.read("assets/" + name, in: project.package, as: .lut) == nil)
        try FileManager.default.createSymbolicLink(at: project.package.assetsURL.appending(path: name + ".tmp"), withDestinationURL: spare)
        #expect(try AssetImport.copyLUT(url, into: project.package) == "assets/" + name)
        #expect(try LUTFixture.names(in: project.package.assetsURL) == [name])
        var info = stat()
        #expect(lstat(project.package.assetsURL.appending(path: name).path, &info) == 0)
        #expect(info.st_mode & S_IFMT == S_IFREG)
        #expect(try Data(contentsOf: project.package.assetsURL.appending(path: name)) == cube)
        #expect(try Data(contentsOf: target) == LUTFixture.cube("1 1 1"))
        #expect(try Data(contentsOf: spare) == Data("nor this".utf8))
    }
}

@Test func changedWhileCopyingIsRefused() throws {
    try withTemporaryDirectory { dir in
        let package = ProjectPackage(url: dir.appending(path: "Fixture.toma", directoryHint: .isDirectory))
        try FileManager.default.createDirectory(at: package.url, withIntermediateDirectories: true)
        let url = dir.appending(path: "Look.cube")
        try LUTFixture.cube().write(to: url)

        // `assets/` is made after the `.cube` is read and named, before it is cloned: its sync is where the file is
        // changed in place (the same file, other bytes).
        var changed = false
        let change = { (fd: Int32) throws in
            if !changed {
                changed = true
                let handle = try FileHandle(forWritingTo: url)
                try handle.write(contentsOf: LUTFixture.cube("1 1 1"))
                try handle.close()
            }
            try DurableFile.fullSync(fd)
        }
        let placed = Result { () throws(AssetImport.Failure) in
            try AssetImport.place(url, into: package, as: .lut, syncFolder: change)
        }
        guard case .failure(.changed) = placed else {
            Issue.record("not refused as changed: \(placed)")
            return
        }
        #expect(changed)
        #expect(try LUTFixture.names(in: package.assetsURL).isEmpty)

        // Tried again, it is what is there now.
        #expect(try AssetImport.copyLUT(url, into: package) == "assets/\(LUTFixture.hash(LUTFixture.cube("1 1 1"))).cube")
        #expect(try LUTFixture.names(in: package.assetsURL).count == 1)
    }
}
