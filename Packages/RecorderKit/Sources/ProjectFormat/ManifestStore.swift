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
/// `raiseFormatVersion(to:)`, which the recorder calls before it writes what only version 4 defines (a track of a
/// device, a `keyPress` event): a take without them leaves a version 3 package at 3.
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
    /// version is refused the same way, with `ManifestStoreError.needsFormatVersion(4)`: raise the version first.
    ///
    /// `body` runs while the store's lock is held, and the lock is not recursive:
    /// `body` must never call back into this store.
    public func update(_ body: (inout Manifest) throws -> Void) throws {
        try state.withLock { state in
            var manifest = state.manifest
            try body(&manifest)
            manifest.formatVersion = state.manifest.formatVersion
            if manifest.formatVersion < 4, manifest.needsFormatVersion4 {
                throw ManifestStoreError.needsFormatVersion(4)
            }
            let data = try ProjectJSON.encoder().encode(manifest)
            state.manifest = manifest
            state.needsWrite = true
            try write(data, &state)
        }
    }

    /// Moves the package to format `version`, with one write, when it is at an earlier one; does nothing when it is at
    /// `version` or later (a version only goes up). The recorder calls it with 4 before it adds a track of a device or
    /// writes the first `keyPress` event of a take.
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
            try DurableFile.writeAtomically(try ProjectJSON.encoder().encode(manifest), to: package.manifestURL)
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
    /// The change needs a package of this format version (a track of a device needs 4), and the package is at an
    /// earlier one: `ManifestStore.raiseFormatVersion(to:)` first.
    case needsFormatVersion(Int)
    /// This version is newer than `Manifest.newestFormatVersion`: this version cannot write it.
    case unsupportedVersion(Int)
    /// The package is of this version, before `Manifest.recordableFormatVersions`: only its first edit moves it, to 3.
    case notRecordable(Int)
}
