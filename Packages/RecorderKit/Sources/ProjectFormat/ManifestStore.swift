// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import Synchronization

/// The in-memory manifest of a package, written durably to `manifest.json` after every change.
///
/// Changes are serialized under a lock and each one is written with
/// `DurableFile.writeAtomically`. If a write fails the change stays in memory,
/// the error is rethrown, and the next `update` or `flushPending()` writes it again.
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

    /// Applies `body` and writes the result. If `body` throws, nothing changes.
    public func update(_ body: (inout Manifest) throws -> Void) throws {
        try state.withLock { state in
            var manifest = state.manifest
            try body(&manifest)
            state.manifest = manifest
            state.needsWrite = true
            try write(&state)
        }
    }

    /// Writes a change whose earlier write failed. Does nothing if the file is up to date.
    public func flushPending() throws {
        try state.withLock { state in
            guard state.needsWrite else { return }
            try write(&state)
        }
    }

    private func write(_ state: inout State) throws {
        let data = try ProjectJSON.encoder().encode(state.manifest)
        try DurableFile.writeAtomically(data, to: package.manifestURL)
        state.needsWrite = false
    }
}
