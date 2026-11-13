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
    /// Throws `LoadedProjectError` for a manifest of a newer format version, a package without takes
    /// or an unknown take, and the underlying error if the manifest or the event log cannot be read.
    public static func load(_ url: URL, take: String? = nil) throws -> LoadedProject {
        let package = ProjectPackage(url: url)
        let manifest = try ProjectJSON.decoder().decode(Manifest.self, from: Data(contentsOf: package.manifestURL))
        guard manifest.formatVersion <= Manifest.currentFormatVersion else {
            throw LoadedProjectError.unsupportedFormatVersion(manifest.formatVersion)
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
}
