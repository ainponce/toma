// SPDX-License-Identifier: GPL-3.0-or-later
import Darwin
import Foundation
import Library
import ProjectFormat
import RecorderKitTestSupport
import Testing

private let app = AppInfo(name: "Tests", version: "0")

@Test func identityRoundTripsAndSurvivesARename() throws {
    try withTemporaryDirectory { folder in
        let fileSystem = SystemFileSystem()
        let package = try ProjectPackage.create(in: folder, name: "Demo", app: app, now: Date())
        let identity = try PackageIdentity(of: package.url, in: fileSystem)
        #expect(identity.string == "\(identity.volume):\(identity.file)")
        #expect(PackageIdentity(string: identity.string) == identity)
        // The two keys of design §6.8, as Foundation reads them.
        let values = try package.url.resourceValues(forKeys: [.volumeUUIDStringKey, .fileIdentifierKey])
        #expect(identity.volume == values.volumeUUIDString)
        #expect(identity.file == values.fileIdentifier)

        // Renamed, and moved within the disk: the same project.
        let renamed = folder.appending(path: "Renamed.toma", directoryHint: .isDirectory)
        try FileManager.default.moveItem(at: package.url, to: renamed)
        #expect(try PackageIdentity(of: renamed, in: fileSystem) == identity)
        let subfolder = folder.appending(path: "Clientes", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: subfolder, withIntermediateDirectories: false)
        let moved = subfolder.appending(path: "Renamed.toma", directoryHint: .isDirectory)
        try FileManager.default.moveItem(at: renamed, to: moved)
        #expect(try PackageIdentity(of: moved, in: fileSystem) == identity)

        // A clone is another project, on the same volume, though the manifest's projectID is the same.
        let copy = folder.appending(path: "Renamed copia.toma", directoryHint: .isDirectory)
        #expect(clonefile(moved.path, copy.path, 0) == 0)
        let copyIdentity = try PackageIdentity(of: copy, in: fileSystem)
        #expect(copyIdentity != identity)
        #expect(copyIdentity.volume == identity.volume)
        #expect(try treeHash(copy) == treeHash(moved))
    }
}

@Test func onlyCanonicalStringsAreIdentities() throws {
    let identity = PackageIdentity(volume: "8C2F6A1E-0B3D-4E0F-9A51-0C1D2E3F4A5B", file: 5_130_042)
    #expect(identity.string == "8C2F6A1E-0B3D-4E0F-9A51-0C1D2E3F4A5B:5130042")
    #expect(PackageIdentity(string: "8C2F6A1E-0B3D-4E0F-9A51-0C1D2E3F4A5B:5130042") == identity)
    #expect(PackageIdentity(string: "V:18446744073709551615") == PackageIdentity(volume: "V", file: .max))
    for string in ["", "V", "V:", ":5", "V:-1", "V:+5", "V:05", "V: 5", "V:5 ", "V:0x5", "V:18446744073709551616"] {
        #expect(PackageIdentity(string: string) == nil, "\(string)")
    }

    // In JSON (the index, design §13.4) it is its string.
    let encoded = try JSONEncoder().encode([identity])
    #expect(String(decoding: encoded, as: UTF8.self) == #"["8C2F6A1E-0B3D-4E0F-9A51-0C1D2E3F4A5B:5130042"]"#)
    #expect(try JSONDecoder().decode([PackageIdentity].self, from: encoded) == [identity])
    #expect(throws: DecodingError.self) { try JSONDecoder().decode([PackageIdentity].self, from: Data(#"["V:x"]"#.utf8)) }
}

@Test func identityIsReadThroughTheFileSystemItIsGiven() throws {
    try withTemporaryDirectory { folder in
        let package = try ProjectPackage.create(in: folder, name: "Demo", app: app, now: Date())
        let slow = DelayingFileSystem(volumes: [
            .init(root: folder, info: DelayingFileSystem.volumeInfo(uuid: "FAKE-VOLUME"), delay: .milliseconds(30))
        ])
        let counting = CountingFileSystem(base: slow)
        let start = ContinuousClock.now
        let identity = try PackageIdentity(of: package.url, in: counting)
        #expect(ContinuousClock.now - start >= .milliseconds(60))
        #expect(identity.volume == "FAKE-VOLUME")
        #expect(identity.file == (try SystemFileSystem().stat(package.url)).fileID)
        // The package's own folder, and nothing inside it.
        #expect(Set(counting.accesses.map(\.url)) == [package.url])
        #expect(Set(counting.accesses.map(\.operation)) == [.volume, .stat])
    }
}

@Test func statDescribesTheItemItselfAndNeverFollows() async throws {
    try await withTemporaryDirectory { folder in
        let fileSystem = SystemFileSystem()
        let file = folder.appending(path: "file.json")
        try Data("0123456789".utf8).write(to: file)
        let directory = folder.appending(path: "dir.toma", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        let link = folder.appending(path: "link.toma")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: directory)
        let fileLink = folder.appending(path: "link.json")
        try FileManager.default.createSymbolicLink(at: fileLink, withDestinationURL: file)
        let fifo = folder.appending(path: "fifo.json")
        #expect(mkfifo(fifo.path, 0o600) == 0)

        let fileStat = try fileSystem.stat(file)
        #expect(fileStat.kind == .regular)
        #expect(fileStat.size == 10)
        let values = try file.resourceValues(forKeys: [.contentModificationDateKey, .fileIdentifierKey])
        let modified = try #require(values.contentModificationDate)
        #expect(abs(Double(fileStat.modified) / 1e9 - modified.timeIntervalSince1970) < 0.001)
        #expect(fileStat.fileID == values.fileIdentifier)
        #expect(try fileSystem.stat(directory).kind == .directory)
        #expect(try fileSystem.stat(link).kind == .symlink)
        #expect(try fileSystem.stat(link).fileID != fileSystem.stat(directory).fileID)
        #expect(try fileSystem.stat(fileLink).kind == .symlink)
        #expect(try fileSystem.stat(fifo).kind == .other)
        #expect(throws: POSIXError(.ENOENT)) { try fileSystem.stat(folder.appending(path: "missing")) }

        // A file's modification date in nanoseconds: one written later is later.
        try await Task.sleep(for: .milliseconds(20))
        try Data("x".utf8).write(to: file)
        #expect(try fileSystem.stat(file).modified > fileStat.modified)

        // Nothing is listed, read or measured through a link, and a FIFO is refused at once.
        #expect(throws: POSIXError(.ENOTDIR)) { try fileSystem.list(link) }
        #expect(throws: POSIXError(.ELOOP)) { try fileSystem.read(fileLink, maxBytes: 100) }
        #expect(throws: POSIXError(.ELOOP)) { try fileSystem.allocatedSize(of: link) }
        #expect(throws: POSIXError(.EFTYPE)) { try fileSystem.read(fifo, maxBytes: 100) }
        #expect(throws: POSIXError(.ENOTDIR)) { try fileSystem.list(file) }
    }
}

@Test func addedToDirectoryIsWhenItArrived() async throws {
    try await withTemporaryDirectory { folder in
        let fileSystem = SystemFileSystem()
        let package = try ProjectPackage.create(in: folder, name: "Demo", app: app, now: Date())
        let trash = folder.appending(path: "Trash", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: trash, withIntermediateDirectories: false)
        let created = try #require(try fileSystem.stat(package.url).addedToDirectory)

        // APFS keeps the date to the nanosecond.
        try await Task.sleep(for: .milliseconds(50))
        let beforeMove = Date()
        let trashed = trash.appending(path: "Demo.toma", directoryHint: .isDirectory)
        try FileManager.default.moveItem(at: package.url, to: trashed)
        let added = try #require(try fileSystem.stat(trashed).addedToDirectory)
        #expect(added > created)
        #expect(added.timeIntervalSince(beforeMove) > -1)
        #expect(added.timeIntervalSinceNow < 1)
        let foundation = try #require(try trashed.resourceValues(forKeys: [.addedToDirectoryDateKey]).addedToDirectoryDate)
        #expect(abs(added.timeIntervalSince(foundation)) < 0.000_01)
    }
}

@Test func listGivesEveryEntryAndReadKeepsToItsLimit() throws {
    try withTemporaryDirectory { folder in
        let fileSystem = SystemFileSystem()
        for name in ["a.toma", ".hidden", "Trash", "b.json"] {
            try Data().write(to: folder.appending(path: name))
        }
        #expect(Set(try fileSystem.list(folder).map(\.lastPathComponent)) == ["a.toma", ".hidden", "Trash", "b.json"])
        let parents = Set(try fileSystem.list(folder).map { $0.deletingLastPathComponent().standardizedFileURL })
        #expect(parents == [folder.standardizedFileURL])

        let manifest = folder.appending(path: "manifest.json")
        try Data(repeating: 7, count: 1_000).write(to: manifest)
        #expect(try fileSystem.read(manifest, maxBytes: 1_000) == Data(repeating: 7, count: 1_000))
        #expect(throws: POSIXError(.EFBIG)) { try fileSystem.read(manifest, maxBytes: 999) }
        #expect(throws: POSIXError(.ENOENT)) { try fileSystem.read(folder.appending(path: "missing"), maxBytes: 999) }
    }
}

@Test func allocatedSizeCountsThePackageAndNothingItLinksTo() throws {
    try withTemporaryDirectory { folder in
        let fileSystem = SystemFileSystem()
        let package = try ProjectPackage.create(in: folder, name: "Demo", app: app, now: Date())
        let empty = try fileSystem.allocatedSize(of: package.url)
        #expect(empty > 0)

        let take = package.url.appending(path: "takes/take-001", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: take, withIntermediateDirectories: true)
        try Data(repeating: 1, count: 100_000).write(to: take.appending(path: "screen.mov"))
        let big = folder.appending(path: "big.bin")
        try Data(repeating: 2, count: 4_000_000).write(to: big)
        try FileManager.default.createSymbolicLink(at: take.appending(path: "link.mov"), withDestinationURL: big)

        let size = try fileSystem.allocatedSize(of: package.url)
        #expect(size >= empty + 100_000)
        #expect(size < empty + 1_000_000)
    }
}

@Test func volumeOfTheTemporaryFolderIsLocalAndInternal() throws {
    try withTemporaryDirectory { folder in
        let volume = try SystemFileSystem().volume(of: folder)
        let values = try folder.resourceValues(forKeys: [.volumeUUIDStringKey, .volumeLocalizedNameKey])
        #expect(volume.uuid == values.volumeUUIDString)
        #expect(volume.name == values.volumeLocalizedName)
        #expect(volume.isInternal)
        #expect(!volume.isRemovable)
        #expect(!volume.isNetwork)
        #expect(!volume.isSynced)
        #expect(!volume.isReadOnly)
        #expect(volume.availableBytes > 0)
    }
}

@Test func aDiskImageIsNeitherInternalNorFixedAndCanBeReadOnly() throws {
    try withTemporaryDirectory { folder in
        let image = try DiskImage.attach(sizeMegabytes: 20, fileSystem: .apfs, in: folder)
        defer { try? image.detach(force: true) }
        let package = try ProjectPackage.create(in: image.mountPoint, name: "Demo", app: app, now: Date())
        let volume = try SystemFileSystem().volume(of: package.url)
        #expect(volume.uuid != (try SystemFileSystem().volume(of: folder)).uuid)
        #expect(volume.name == "TomaTest")
        #expect(!volume.isInternal)
        #expect(volume.isRemovable)
        #expect(!volume.isNetwork)
        #expect(!volume.isSynced)
        #expect(!volume.isReadOnly)
        // Free space as the disk has it, though the figure for important usage is 0 on an image.
        #expect(volume.availableBytes > 1_000_000)
        #expect(volume.availableBytes < 20 * 1_048_576)
        #expect(try PackageIdentity(of: package.url, in: SystemFileSystem()).volume == volume.uuid)

        // The same disk attached read-only.
        try image.detach()
        try image.reattach(readOnly: true)
        let readOnly = try SystemFileSystem().volume(of: package.url)
        #expect(readOnly.isReadOnly)
        #expect(readOnly.uuid == volume.uuid)
    }
}
