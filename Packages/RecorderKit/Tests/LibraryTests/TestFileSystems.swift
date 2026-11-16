// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import Library
import ProjectFormat
import Synchronization

/// A file system that answers as `base` does and writes down every access, in order: what the library touched, for
/// the tests that check it never reads a video, never looks inside a package it was not asked about and never probes a
/// lock.
final class CountingFileSystem: LibraryFileSystem {
    enum Operation: Equatable, Sendable {
        case list, stat, volume, read, allocatedSize
    }

    struct Access: Equatable, Sendable {
        var operation: Operation
        var url: URL
    }

    private let base: any LibraryFileSystem
    private let log = Mutex<[Access]>([])

    init(base: any LibraryFileSystem = SystemFileSystem()) {
        self.base = base
    }

    /// Every access so far, in the order they began.
    var accesses: [Access] { log.withLock { $0 } }

    /// The accesses of `operation` so far, in order.
    func urls(of operation: Operation) -> [URL] {
        accesses.filter { $0.operation == operation }.map(\.url)
    }

    func reset() {
        log.withLock { $0 = [] }
    }

    func list(_ directory: URL) throws -> [URL] {
        note(.list, directory)
        return try base.list(directory)
    }

    func stat(_ url: URL, withAddedDate: Bool) throws -> FileStat {
        note(.stat, url)
        return try base.stat(url, withAddedDate: withAddedDate)
    }

    func volume(of url: URL) throws -> VolumeInfo {
        note(.volume, url)
        return try base.volume(of: url)
    }

    func read(_ url: URL, maxBytes: Int) throws -> Data {
        note(.read, url)
        return try base.read(url, maxBytes: maxBytes)
    }

    func allocatedSize(of package: URL) throws -> Int64 {
        note(.allocatedSize, package)
        return try base.allocatedSize(of: package)
    }

    private func note(_ operation: Operation, _ url: URL) {
        log.withLock { $0.append(Access(operation: operation, url: url)) }
    }
}

/// A file system of made-up volumes over `base`: a URL under one of `volumes` (by path) is on that volume, which
/// `volume(of:)` describes as the test says, and every access to it first waits the volume's delay, blocking the calling
/// thread as a slow disk does. A URL under none of them is `base`'s, without waiting. The files themselves are always
/// `base`'s: only the volume they seem to be on is made up.
final class DelayingFileSystem: LibraryFileSystem {
    struct FakeVolume: Sendable {
        /// The folder the volume holds: itself and everything under it.
        var root: URL
        var info: VolumeInfo
        var delay: Duration

        init(root: URL, info: VolumeInfo, delay: Duration = .zero) {
            self.root = root
            self.info = info
            self.delay = delay
        }
    }

    private let base: any LibraryFileSystem
    private let volumes: [FakeVolume]

    init(base: any LibraryFileSystem = SystemFileSystem(), volumes: [FakeVolume]) {
        self.base = base
        self.volumes = volumes
    }

    /// A volume that is local, internal, writable and neither removable nor synced unless the test says otherwise.
    static func volumeInfo(
        uuid: String, name: String = "Fake", isInternal: Bool = true, isRemovable: Bool = false, isNetwork: Bool = false,
        isSynced: Bool = false, availableBytes: Int64 = 100_000_000_000, isReadOnly: Bool = false
    ) -> VolumeInfo {
        VolumeInfo(
            uuid: uuid, name: name, isInternal: isInternal, isRemovable: isRemovable, isNetwork: isNetwork, isSynced: isSynced,
            availableBytes: availableBytes, isReadOnly: isReadOnly)
    }

    func list(_ directory: URL) throws -> [URL] {
        wait(for: directory)
        return try base.list(directory)
    }

    func stat(_ url: URL, withAddedDate: Bool) throws -> FileStat {
        wait(for: url)
        return try base.stat(url, withAddedDate: withAddedDate)
    }

    func volume(of url: URL) throws -> VolumeInfo {
        wait(for: url)
        return try fakeVolume(of: url)?.info ?? base.volume(of: url)
    }

    func read(_ url: URL, maxBytes: Int) throws -> Data {
        wait(for: url)
        return try base.read(url, maxBytes: maxBytes)
    }

    func allocatedSize(of package: URL) throws -> Int64 {
        wait(for: package)
        return try base.allocatedSize(of: package)
    }

    private func fakeVolume(of url: URL) -> FakeVolume? {
        let path = url.standardizedFileURL.path
        return volumes.first { volume in
            let root = volume.root.standardizedFileURL.path
            return path == root || path.hasPrefix(root.hasSuffix("/") ? root : root + "/")
        }
    }

    private func wait(for url: URL) {
        guard let delay = fakeVolume(of: url)?.delay, delay > .zero else { return }
        Thread.sleep(forTimeInterval: delay.seconds)
    }
}
