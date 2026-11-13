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

    /// Applies `body` and writes the result. If `body` throws or its result cannot be
    /// encoded, nothing changes and the error is rethrown.
    ///
    /// `body` runs while the store's lock is held, and the lock is not recursive:
    /// `body` must never call back into this store.
    public func update(_ body: (inout Manifest) throws -> Void) throws {
        try state.withLock { state in
            var manifest = state.manifest
            try body(&manifest)
            let data = try ProjectJSON.encoder().encode(manifest)
            state.manifest = manifest
            state.needsWrite = true
            try write(data, &state)
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
