// SPDX-License-Identifier: GPL-3.0-or-later
import Darwin
import Editing
import Foundation
import ProjectFormat

/// What the library can say about a project by reading it (design §6.6). "Recording", "Open in this app" and "In another
/// app" are not here: the app knows them from its own state, and locks are never probed to find out.
public enum ProjectState: Codable, Equatable, Sendable {
    case normal
    /// A take of the manifest is `recording` (in a package the app is not recording into: the app knows that one).
    case unfinished
    /// The project cannot be opened; why, for the help text: a manifest that cannot be read, a path in it that could
    /// leave the package, a document or an event log that cannot be read.
    case needsRepair(String)
    /// `formatVersion` > 3 or `documentVersion` > 2: a newer Toma wrote it.
    case newerVersion
    /// Its volume cannot be written to: it opens only to be looked at.
    case readOnlyVolume
    /// In `<projects folder>/Trash/` since the date it got there.
    case inTrash(since: Date)
    /// A project of Other places that a look asked by the user could not find.
    case unavailable(Unavailable)
}

/// Why a project of Other places is not available (design §6.5).
public enum Unavailable: Codable, Equatable, Sendable {
    /// Its disk, by name, is not connected.
    case diskNotConnected(String)
    case notFound
}

/// Where a project is.
public enum Place: Codable, Equatable, Sendable {
    /// In the projects folder; `subfolder` is the path of the folder it is in relative to the projects folder, `""` for
    /// the projects folder itself.
    case projectsFolder(subfolder: String)
    /// In `<projects folder>/Trash/`.
    case trash
    /// Out of the projects folder: Other places.
    case elsewhere
}

/// What a file looked like the last time the library looked: if it is the same, the file is not read again.
public struct FileSignature: Codable, Equatable, Sendable {
    /// In bytes.
    public var size: Int64
    /// The modification date, in nanoseconds since 1970.
    public var modified: Int64

    public init(size: Int64, modified: Int64) {
        self.size = size
        self.modified = modified
    }
}

/// What the library knows about a project: an entry of the index (design §13.4). Dates are in whole seconds, as they
/// are written.
public struct ProjectSummary: Codable, Equatable, Sendable {
    public var identity: PackageIdentity
    /// The package's path, without a `/` at its end.
    public var path: String
    /// The package's name without `.toma`.
    public var name: String
    public var place: Place
    /// When it was recorded: the manifest's `createdAt`.
    public var recordedAt: Date?
    /// How long the output lasts, by its document.
    public var outputSeconds: Double?
    public var aspect: Aspect?
    /// The take it shows (the last one) has a camera track.
    public var hasCamera: Bool
    public var formatVersion: Int?
    /// The `documentVersion` its document is written in on disk: 1 for a project of 1b not edited in 1c, which the
    /// app of 1b still opens.
    public var documentVersion: Int?
    public var state: ProjectState
    /// The space it takes on its disk, in bytes, once summed (later, and with less priority, than the rest).
    public var size: Int64?
    /// `manifest.json`, `edit.json` and `edit-log.jsonl` as they were before they were read; `nil` for one that is not
    /// there.
    public var manifest: FileSignature?
    public var edit: FileSignature?
    public var log: FileSignature?
    public var thumbnailKey: String?
    /// When the library last looked at it.
    public var lastSeen: Date

    public init(
        identity: PackageIdentity, path: String, name: String, place: Place, recordedAt: Date? = nil,
        outputSeconds: Double? = nil, aspect: Aspect? = nil, hasCamera: Bool, formatVersion: Int? = nil,
        documentVersion: Int? = nil, state: ProjectState, size: Int64? = nil, manifest: FileSignature? = nil,
        edit: FileSignature? = nil, log: FileSignature? = nil, thumbnailKey: String? = nil, lastSeen: Date
    ) {
        self.identity = identity
        self.path = path
        self.name = name
        self.place = place
        self.recordedAt = recordedAt
        self.outputSeconds = outputSeconds
        self.aspect = aspect
        self.hasCamera = hasCamera
        self.formatVersion = formatVersion
        self.documentVersion = documentVersion
        self.state = state
        self.size = size
        self.manifest = manifest
        self.edit = edit
        self.log = log
        self.thumbnailKey = thumbnailKey
        self.lastSeen = lastSeen
    }
}

/// Reads what the library shows of one project (design §6.8, "Qué se lee"), without writing anything, taking no lock
/// and never opening a video. Every access may take as long as its disk: never on the main thread.
public enum ProjectReader {
    /// The largest manifest that is read; a larger one is a project to repair, and is not read.
    public static let maxManifestBytes = 4 * 1_048_576

    /// The summary of the package at `url`, which is in `place`.
    ///
    /// Through `fileSystem`: the package itself (which must be a folder, never a link), its volume, the signatures of
    /// `manifest.json`, `edit.json` and `edit-log.jsonl`, and the manifest, of at most `maxManifestBytes`. Only once the
    /// manifest was read and is one this version reads, and unless a take is still `recording` (whose event log is
    /// being written), the document with `readDocument` (by default `EditSession`'s, with `context`: no lock, nothing
    /// written, the tail of the log applied), for the output's length and format and the version it is written in.
    /// The size on disk and the thumbnail are left for later.
    ///
    /// The state, the first that holds: a package that is not there is `.unavailable(.notFound)`, with an identity of
    /// file 0, which no item has (the caller keeps the one it knew); a link, a manifest or a document that cannot be
    /// read is `.needsRepair`; a newer format or document `.newerVersion`; then `.inTrash` (in `place` `.trash`, since
    /// the package got there), `.unfinished`, `.readOnlyVolume`, `.normal`.
    public static func summary(
        of url: URL, place: Place, fileSystem: any LibraryFileSystem,
        readDocument: (@Sendable (URL) throws -> (LoadedProject, EditDocument, Int))? = nil, context: EditContext,
        now: Date
    ) -> ProjectSummary {
        let package = ProjectPackage(url: url)
        let name = url.deletingPathExtension().lastPathComponent
        let lastSeen = now.roundedToWholeSeconds
        let volume: VolumeInfo
        let folder: FileStat
        do {
            volume = try fileSystem.volume(of: url)
            folder = try fileSystem.stat(url, withAddedDate: place == .trash)
        } catch {
            return ProjectSummary(
                identity: PackageIdentity(volume: url.path, file: 0), path: url.path, name: name, place: place,
                hasCamera: false, state: .unavailable(.notFound), lastSeen: lastSeen)
        }
        var summary = ProjectSummary(
            identity: PackageIdentity(volume: volume.uuid, file: folder.fileID), path: url.path, name: name, place: place,
            hasCamera: false, state: .normal, lastSeen: lastSeen)
        guard folder.kind == .directory else {
            summary.state = .needsRepair(folder.kind == .symlink ? "The package is a link." : "The package is not a folder.")
            return summary
        }
        func signature(_ file: URL) -> FileSignature? {
            (try? fileSystem.stat(file, withAddedDate: false)).map { FileSignature(size: $0.size, modified: $0.modified) }
        }
        summary.manifest = signature(package.manifestURL)
        summary.edit = signature(package.editURL)
        summary.log = signature(package.editLogURL)

        let manifest: Manifest
        do {
            let data = try fileSystem.read(package.manifestURL, maxBytes: maxManifestBytes)
            let version = try Manifest.formatVersion(of: data)
            summary.formatVersion = version
            guard version <= Manifest.currentFormatVersion else {
                summary.state = .newerVersion
                return summary
            }
            guard Manifest.supportedFormatVersions.contains(version) else {
                summary.state = .needsRepair("manifest.json: there is no format version \(version).")
                return summary
            }
            manifest = try ProjectJSON.decoder().decode(Manifest.self, from: data)
            try manifest.validatePaths()
        } catch {
            summary.state = .needsRepair("manifest.json: \(reason(error))")
            return summary
        }
        summary.recordedAt = manifest.createdAt
        summary.hasCamera = manifest.takes.last?.tracks.contains { $0.kind == .camera } ?? false

        let isUnfinished = manifest.takes.contains { $0.status == .recording }
        if !isUnfinished {
            let read: (URL) throws -> (LoadedProject, EditDocument, Int) =
                readDocument ?? { url in
                    let (project, document, diskVersion) = try EditSession.readDocumentWithDiskVersion(
                        url, take: nil, context: context)
                    return (project, document, diskVersion)
                }
            do {
                let (project, document, diskVersion) = try read(url)
                summary.formatVersion = project.manifest.formatVersion
                summary.documentVersion = diskVersion
                summary.outputSeconds = TimeMap(sequence: document.sequence).durationSeconds
                summary.aspect = document.aspect
                summary.hasCamera = project.take.tracks.contains { $0.kind == .camera }
                if diskVersion > EditDocument.currentVersion {
                    summary.state = .newerVersion
                    return summary
                }
            } catch let EditDocumentError.newerVersion(version) {
                summary.documentVersion = version
                summary.state = .newerVersion
                return summary
            } catch let LoadedProjectError.unsupportedFormatVersion(version) where version > Manifest.currentFormatVersion {
                // The manifest changed since it was read.
                summary.formatVersion = version
                summary.state = .newerVersion
                return summary
            } catch {
                summary.state = .needsRepair(reason(error))
                return summary
            }
        }

        if place == .trash {
            let since = folder.addedToDirectory ?? Date(timeIntervalSince1970: Double(folder.modified) / 1e9)
            summary.state = .inTrash(since: since.roundedToWholeSeconds)
        } else if isUnfinished {
            summary.state = .unfinished
        } else if volume.isReadOnly {
            summary.state = .readOnlyVolume
        }
        return summary
    }

    /// `error` in a few words, for the help text of a project to repair.
    private static func reason(_ error: any Error) -> String {
        switch error {
        case let error as POSIXError: String(cString: strerror(error.code.rawValue)) + "."
        case is DecodingError: "It is not one this version reads."
        case let error as LoadedProjectError: "\(error)."
        default: "\(error)"
        }
    }
}
