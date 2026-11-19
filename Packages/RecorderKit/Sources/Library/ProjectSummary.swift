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
    case needsRepair(RepairReason)
    /// `formatVersion` > `Manifest.newestFormatVersion` (4) or `documentVersion` > 2: a newer Toma wrote it.
    case newerVersion
    /// Its volume cannot be written to: it opens only to be looked at.
    case readOnlyVolume
    /// In `<projects folder>/Trash/` since the date it got there.
    case inTrash(since: Date)
    /// A project of Other places that a look asked by the user could not find.
    case unavailable(Unavailable)
}

/// Why a project cannot be opened (design §6.6, "Para reparar"): which part of it and what is wrong, as values the app
/// says in words. `description` says it in English, for logs.
public struct RepairReason: Codable, Equatable, Sendable, CustomStringConvertible {
    /// The part of the project that could not be read.
    public enum Part: String, Codable, Sendable {
        /// The package itself.
        case package
        /// `manifest.json`.
        case manifest
        /// What the editor reads: the document, its event log, the take's events.
        case edit
    }

    /// What is wrong with it.
    public enum Problem: Codable, Equatable, Sendable {
        /// The package is a link (never followed).
        case isALink
        /// The package is not a folder.
        case notAFolder
        /// A manifest of a format version that does not exist.
        case unknownFormat(Int)
        /// The system refused, with this `errno` (`EIO`, `EACCES`, `EFBIG` for a manifest past its limit, `ELOOP` for a
        /// link inside, `EFTYPE` for something that is not a regular file…).
        case system(Int32)
        /// It is damaged, or not one this version reads.
        case unreadable
        /// A path in it could leave the package: nothing was read through it.
        case pathLeavesThePackage
        /// A take it names is not there, or it has none.
        case missingTake
        /// Anything else, in English.
        case other(String)
    }

    public var part: Part
    public var problem: Problem

    public init(part: Part, problem: Problem) {
        self.part = part
        self.problem = problem
    }

    /// The reason in English: "manifest.json: File too large.".
    public var description: String {
        let what: String
        switch problem {
        case .isALink: return "The package is a link."
        case .notAFolder: return "The package is not a folder."
        case .unknownFormat(let version): what = "there is no format version \(version)."
        case .system(let code): what = String(cString: strerror(code)) + "."
        case .unreadable: what = "It is not one this version reads."
        case .pathLeavesThePackage: what = "A path in it leaves the package."
        case .missingTake: what = "A take is missing."
        case .other(let text): what = text
        }
        switch part {
        case .package: return "The package cannot be looked at: " + what
        case .manifest: return "manifest.json: " + what
        case .edit: return what
        }
    }

    /// The reason `error` gives for `part`.
    static func of(_ part: Part, _ error: any Error) -> RepairReason {
        RepairReason(part: part, problem: ProjectReader.problem(of: error))
    }
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
    /// `manifest.json`, `edit.json` and `edit-log.jsonl`, and the manifest, of at most `maxManifestBytes`. Only once
    /// the manifest was read and is one this version reads, and unless a take is still `recording` (whose event log is
    /// being written), the document's outline with `readDocument` (by default `EditSession.readOutline`, with
    /// `context`: no lock, nothing written, the tail of the log applied, the event log decoded only where the outline
    /// depends on it), for the output's length and format and the version it is written in. The size on disk and the
    /// thumbnail are left for later.
    ///
    /// The state, the first that holds: a package that is not there (`ENOENT`, `ENOTDIR`) is `.unavailable(.notFound)`
    /// and one that cannot be looked at for another reason (`EIO`, `EACCES`…) `.needsRepair`, both with an identity of
    /// file 0, which no item has (the caller keeps the one it knew, and a disk that fails for a moment never makes a
    /// project look gone); a link, a manifest or a document that cannot be read is `.needsRepair`; a newer format or
    /// document `.newerVersion`; then `.inTrash` (in `place` `.trash`, since the package got there), `.unfinished`,
    /// `.readOnlyVolume`, `.normal`. The volume's free space is never asked.
    public static func summary(
        of url: URL, place: Place, fileSystem: any LibraryFileSystem,
        readDocument: (@Sendable (URL) throws -> (LoadedProject, DocumentOutline))? = nil, context: EditContext,
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
            let state: ProjectState = isMissing(error) ? .unavailable(.notFound) : cannotBeLookedAt(error)
            return ProjectSummary(
                identity: PackageIdentity(volume: url.path, file: 0), path: url.path, name: name, place: place,
                hasCamera: false, state: state, lastSeen: lastSeen)
        }
        var summary = ProjectSummary(
            identity: PackageIdentity(volume: volume.uuid, file: folder.fileID), path: url.path, name: name, place: place,
            hasCamera: false, state: .normal, lastSeen: lastSeen)
        guard folder.kind == .directory else {
            summary.state = .needsRepair(RepairReason(part: .package, problem: folder.kind == .symlink ? .isALink : .notAFolder))
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
            guard version <= Manifest.newestFormatVersion else {
                summary.state = .newerVersion
                return summary
            }
            guard Manifest.supportedFormatVersions.contains(version) else {
                summary.state = .needsRepair(RepairReason(part: .manifest, problem: .unknownFormat(version)))
                return summary
            }
            manifest = try ProjectJSON.decoder().decode(Manifest.self, from: data)
            try manifest.validatePaths()
        } catch {
            summary.state = .needsRepair(.of(.manifest, error))
            return summary
        }
        summary.recordedAt = manifest.createdAt
        summary.hasCamera = manifest.takes.last?.tracks.contains { $0.kind == .camera } ?? false

        let isUnfinished = manifest.takes.contains { $0.status == .recording }
        if !isUnfinished {
            let read = readDocument ?? defaultReadDocument(context: context)
            do {
                let (project, outline) = try read(url)
                summary.formatVersion = project.manifest.formatVersion
                summary.documentVersion = outline.diskVersion
                summary.outputSeconds = outline.outputSeconds
                summary.aspect = outline.aspect
                summary.hasCamera = project.take.tracks.contains { $0.kind == .camera }
                if outline.diskVersion > EditDocument.currentVersion {
                    summary.state = .newerVersion
                    return summary
                }
            } catch let EditDocumentError.newerVersion(version) {
                summary.documentVersion = version
                summary.state = .newerVersion
                return summary
            } catch let LoadedProjectError.unsupportedFormatVersion(version) where version > Manifest.newestFormatVersion {
                // The manifest changed since it was read.
                summary.formatVersion = version
                summary.state = .newerVersion
                return summary
            } catch {
                summary.state = .needsRepair(.of(.edit, error))
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

    /// `readDocument`'s default, also the library scanner's: `EditSession.readOutline` with `context`.
    static func defaultReadDocument(
        context: EditContext
    ) -> @Sendable (URL) throws -> (LoadedProject, DocumentOutline) {
        { url in try EditSession.readOutline(url, take: nil, context: context) }
    }

    /// The state of a package that could not be looked at for another reason than not being there: `error` says why.
    static func cannotBeLookedAt(_ error: any Error) -> ProjectState {
        .needsRepair(.of(.package, error))
    }

    /// What is wrong, by `error`: the system's code, a file that does not decode, or what `LoadedProject` refused.
    static func problem(of error: any Error) -> RepairReason.Problem {
        if let code = posixCode(of: error) { return .system(code) }
        if error is DecodingError { return .unreadable }
        guard let error = error as? LoadedProjectError else { return .other("\(error)") }
        switch error {
        case .invalidPath: return .pathLeavesThePackage
        case .noTakes, .takeNotFound: return .missingTake
        case .unsupportedFormatVersion(let version): return .unknownFormat(version)
        }
    }

    /// Whether `error` says nothing is at the path: `ENOENT`, `ENOTDIR` (a folder on the way is not one), or
    /// Foundation's "no such file", itself or as its underlying error.
    static func isMissing(_ error: any Error) -> Bool {
        if let code = posixCode(of: error) { return code == ENOENT || code == ENOTDIR }
        let error = error as NSError
        return error.domain == NSCocoaErrorDomain
            && [CocoaError.fileNoSuchFile.rawValue, CocoaError.fileReadNoSuchFile.rawValue].contains(error.code)
    }

    /// The POSIX error `error` is or carries as its underlying error, if any.
    private static func posixCode(of error: any Error) -> Int32? {
        let error = error as NSError
        if error.domain == NSPOSIXErrorDomain { return Int32(error.code) }
        return (error.userInfo[NSUnderlyingErrorKey] as? NSError).flatMap { posixCode(of: $0) }
    }
}
