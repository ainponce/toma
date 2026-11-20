// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import Synchronization

/// The in-memory manifest of a package, written durably to `manifest.json` after every change.
///
/// Changes are serialized under a lock and each one is written with
/// `DurableFile.writeAtomically`. A change that cannot be encoded (for example a
/// non-finite `Double`) is rejected like a throwing `body`: nothing changes. If the
/// write itself fails, the change stays in memory, the error is rethrown, and the
/// next `update` or `flushPending()` writes it again.
///
/// The store keeps the manifest's `formatVersion` as it was read: a package's version is decided when it is
/// created and nothing rewrites it, so a version 1 package stays at version 1. The one exception is
/// `raiseFormatVersion(to:)` and `update(raisingTo:_:)`, which the recorder calls as it writes what only version 4
/// defines (a track of a device, a `keyPress` event) or adds a second take, which only version 5 allows: a single take
/// without them leaves a version 3 package at 3.
///
/// Use one `ManifestStore` per package, in a single writer process: every write goes
/// through the same `manifest.json.tmp`, so two writers would overwrite each other's
/// temporary file.
public final class ManifestStore: Sendable {
    public let package: ProjectPackage

    private struct State {
        var manifest: Manifest
        var needsWrite: Bool
    }

    private let state: Mutex<State>

    public init(package: ProjectPackage) throws {
        let data = try Data(contentsOf: package.manifestURL)
        let manifest = try ProjectJSON.decoder().decode(Manifest.self, from: data)
        self.package = package
        self.state = Mutex(State(manifest: manifest, needsWrite: false))
    }

    public var manifest: Manifest {
        state.withLock { $0.manifest }
    }

    /// Applies `body` and writes the result, with the manifest's `formatVersion` as it was (a change of it
    /// is undone). If `body` throws or its result cannot be encoded, nothing changes and the error is rethrown.
    /// A result with a track only version 4 defines (`Manifest.needsFormatVersion4`) in a manifest of an earlier
    /// version is refused the same way, with `ManifestStoreError.needsFormatVersion(4)`, and one that adds a take to a
    /// package that then has two or more (`Manifest.needsFormatVersion5`) in a manifest before 5 with
    /// `ManifestStoreError.needsFormatVersion(5)`: raise the version first. A package that has two takes below 5 already
    /// (no app writes one) still gets its takes changed, so recovery closes them: only a take added is refused.
    ///
    /// `body` runs while the store's lock is held, and the lock is not recursive:
    /// `body` must never call back into this store.
    public func update(_ body: (inout Manifest) throws -> Void) throws {
        try apply(raisingTo: nil, body)
    }

    /// `update(_:)` in a package moved to format `version` by the same write, when it is at an earlier one (as
    /// `raiseFormatVersion(to:)` moves it; at `version` or later it stays where it is): the disk has the manifest before
    /// or after both, never the new version without the change, nor the change without it. The recorder adds a take that
    /// needs a version this way (a second take, 5; a take with a device's track, 4), so a write cut between the two
    /// never leaves a package of one take at a version an older app refuses.
    ///
    /// Throws `ManifestStoreError.unsupportedVersion` for a version after `Manifest.newestFormatVersion`, and
    /// `ManifestStoreError.notRecordable` for a package of version 1 or 2 that `version` would move: nothing changes. A
    /// write that fails keeps the change, its version with it, in memory, as `update(_:)` does: the next `update` or
    /// `flushPending()` writes them together.
    public func update(raisingTo version: Int, _ body: (inout Manifest) throws -> Void) throws {
        try apply(raisingTo: version, body)
    }

    /// `update(_:)`, raised to `version` when there is one (`update(raisingTo:_:)`).
    private func apply(raisingTo version: Int?, _ body: (inout Manifest) throws -> Void) throws {
        if let version, version > Manifest.newestFormatVersion { throw ManifestStoreError.unsupportedVersion(version) }
        try state.withLock { state in
            var manifest = state.manifest
            try body(&manifest)
            manifest.formatVersion = state.manifest.formatVersion
            if let version, manifest.formatVersion < version {
                guard Manifest.recordableFormatVersions.contains(manifest.formatVersion) else {
                    throw ManifestStoreError.notRecordable(manifest.formatVersion)
                }
                manifest.formatVersion = version
            }
            if manifest.formatVersion < 4, manifest.needsFormatVersion4 {
                throw ManifestStoreError.needsFormatVersion(4)
            }
            if manifest.formatVersion < 5, manifest.needsFormatVersion5 {
                let before = Set(state.manifest.takes.map(\.id))
                if manifest.takes.contains(where: { !before.contains($0.id) }) {
                    throw ManifestStoreError.needsFormatVersion(5)
                }
            }
            let data = try ProjectJSON.encoder().encode(manifest)
            state.manifest = manifest
            state.needsWrite = true
            try write(data, &state)
        }
    }

    /// Moves the package to format `version`, with one write, when it is at an earlier one; does nothing when it is at
    /// `version` or later (a version only goes up). The recorder calls it with 4 before it writes the first `keyPress`
    /// event of a take; a take that needs a version is added with `update(raisingTo:_:)`, in one write.
    ///
    /// Throws `ManifestStoreError.unsupportedVersion` for a version after `Manifest.newestFormatVersion`, and
    /// `ManifestStoreError.notRecordable` for a package of version 1 or 2 (before `Manifest.recordableFormatVersions`):
    /// only its first edit moves it, to 3, with what that version adds. Unlike `update(_:)`, a write that fails leaves
    /// the version as it was, in memory too, and rethrows: what needs the new version is still refused, so nothing of it
    /// waits in memory to be written into a package of the old one. A change still waiting from an earlier failed write
    /// goes in the same write.
    public func raiseFormatVersion(to version: Int) throws {
        guard version <= Manifest.newestFormatVersion else { throw ManifestStoreError.unsupportedVersion(version) }
        try state.withLock { state in
            let current = state.manifest.formatVersion
            guard current < version else { return }
            guard Manifest.recordableFormatVersions.contains(current) else {
                throw ManifestStoreError.notRecordable(current)
            }
            var manifest = state.manifest
            manifest.formatVersion = version
            do {
                try DurableFile.writeAtomically(try ProjectJSON.encoder().encode(manifest), to: package.manifestURL)
            } catch {
                // The write can fail after its rename (syncing the folder), leaving the disk at `version` while the
                // memory stays at `current`: the next `flushPending()` writes the manifest from memory again.
                state.needsWrite = true
                throw error
            }
            state.manifest = manifest
            state.needsWrite = false
        }
    }

    /// Writes a change whose earlier write failed. Does nothing if the file is up to date.
    public func flushPending() throws {
        try state.withLock { state in
            guard state.needsWrite else { return }
            try write(ProjectJSON.encoder().encode(state.manifest), &state)
        }
    }

    private func write(_ data: Data, _ state: inout State) throws {
        try DurableFile.writeAtomically(data, to: package.manifestURL)
        state.needsWrite = false
    }
}

/// Why `ManifestStore` refused a change. Nothing was written.
public enum ManifestStoreError: Error, Equatable, Sendable {
    /// The change needs a package of this format version (a track of a device needs 4, a second take 5), and the
    /// package is at an earlier one: `ManifestStore.raiseFormatVersion(to:)` first.
    case needsFormatVersion(Int)
    /// This version is newer than `Manifest.newestFormatVersion`: this version cannot write it.
    case unsupportedVersion(Int)
    /// The package is of this version, before `Manifest.recordableFormatVersions`: only its first edit moves it, to 3.
    case notRecordable(Int)
}
