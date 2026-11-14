// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation

/// One take of a package as read from disk, for the tools that look at a recording: the verifier,
/// the renderer and the exporter. Loading never changes anything in the package.
public struct LoadedProject: Sendable {
    public var package: ProjectPackage
    public var manifest: Manifest
    public var take: TakeRecord
    /// The take's `events.jsonl` in file order, which is not always the order of `t`. Empty if the
    /// take has no event log. A cut-short last line and lines this version cannot read are skipped.
    public var events: [InputEvent]

    public init(package: ProjectPackage, manifest: Manifest, take: TakeRecord, events: [InputEvent]) {
        self.package = package
        self.manifest = manifest
        self.take = take
        self.events = events
    }

    /// Reads the package at `url`, its take `take` (the last one in the manifest when `nil`) and that
    /// take's events.
    ///
    /// Throws `LoadedProjectError` for a manifest of a newer format version, one with a path that could
    /// leave the package (`Manifest.validatePaths()`), a package without takes or an unknown take, and
    /// the underlying error if the manifest or the event log cannot be read.
    public static func load(_ url: URL, take: String? = nil) throws -> LoadedProject {
        let package = ProjectPackage(url: url)
        let data = try Data(contentsOf: package.manifestURL)
        let version = try Manifest.formatVersion(of: data)
        guard version <= Manifest.currentFormatVersion else { throw LoadedProjectError.unsupportedFormatVersion(version) }
        let manifest = try ProjectJSON.decoder().decode(Manifest.self, from: data)
        do {
            try manifest.validatePaths()
        } catch {
            throw LoadedProjectError.invalidPath(error)
        }
        let record: TakeRecord
        if let take {
            guard let found = manifest.takes.first(where: { $0.id == take }) else {
                throw LoadedProjectError.takeNotFound(take)
            }
            record = found
        } else {
            guard let last = manifest.takes.last else { throw LoadedProjectError.noTakes }
            record = last
        }
        let eventsURL = package.eventsURL(take: record.id)
        let events = FileManager.default.fileExists(atPath: eventsURL.path) ? try EventLogReader.read(eventsURL).events : []
        return LoadedProject(package: package, manifest: manifest, take: record, events: events)
    }
}

public enum LoadedProjectError: Error, Equatable {
    /// The manifest was written by a newer version of the format, which this version cannot read safely.
    case unsupportedFormatVersion(Int)
    /// The manifest has no takes.
    case noTakes
    /// The manifest has no take with this ID.
    case takeNotFound(String)
    /// A path in the manifest could leave the package. Nothing was read through it.
    case invalidPath(PackagePathError)
}

extension Manifest {
    /// The `formatVersion` of an encoded manifest, decoded on its own: a manifest of a newer format,
    /// which this version may not be able to decode, is still recognized as newer.
    public static func formatVersion(of data: Data) throws -> Int {
        try ProjectJSON.decoder().decode(FormatVersion.self, from: data).formatVersion
    }

    private struct FormatVersion: Decodable {
        var formatVersion: Int
    }
}
