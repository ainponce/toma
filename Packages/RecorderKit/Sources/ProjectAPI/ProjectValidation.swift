// SPDX-License-Identifier: GPL-3.0-or-later
import Darwin
import Editing
import Foundation
import ProjectFormat

/// What `toma validate` says of a package (plan 4b, Task A4): whether Toma reads it whole, the versions it is in, and
/// what is wrong with it. Its JSON is part of the API: keys are only ever added.
public struct ValidationReport: Codable, Equatable, Sendable {
    /// No problem and no missing file. Lines of an event log Toma skips do not count against it: a reader skips an
    /// event it does not know (format 1.0, "Estabilidad"), so they are told apart only by `skippedEventLines`.
    public var valid: Bool
    /// The manifest's `formatVersion`; `nil` for a package whose manifest cannot be read.
    public var formatVersion: Int?
    /// The `documentVersion` the edit document is written in on disk; `nil` without one.
    public var documentVersion: Int?
    /// What is wrong, in English, a sentence each: why the package does not open, the rules of the document it breaks
    /// (`DocumentRules`), a damaged line of its edit log, an event log that cannot be read.
    public var problems: [String]
    /// The whole lines of the takes' event logs that are not an event this version reads (damaged, or of a newer
    /// type), which the readers skip.
    public var skippedEventLines: Int
    /// The files the manifest or the document names that are not in the package, by their path from it.
    public var missingFiles: [String]

    public init(
        valid: Bool, formatVersion: Int?, documentVersion: Int?, problems: [String], skippedEventLines: Int,
        missingFiles: [String]
    ) {
        self.valid = valid
        self.formatVersion = formatVersion
        self.documentVersion = documentVersion
        self.problems = problems
        self.skippedEventLines = skippedEventLines
        self.missingFiles = missingFiles
    }
}

/// How a package is checked: opened for reading (`TomaProject`, which never writes), then its document's rules, its
/// edit log, its takes' event logs and the files it names, each read without following a link.
enum ProjectValidation {
    @MainActor static func report(_ url: URL, environment: APIEnvironment) async -> ValidationReport {
        let project: TomaProject
        do {
            project = try await TomaProject.open(url, mode: .read, environment: environment)
        } catch {
            let error = TomaProject.apiError(error)
            return ValidationReport(
                valid: false, formatVersion: Self.formatVersion(at: url), documentVersion: nil, problems: [error.description],
                skippedEventLines: 0, missingFiles: [])
        }
        let loaded = project.project, document = project.document, documentVersion = project.documentVersion
        await project.close()
        let found = await Task.detached { Self.check(loaded, document: document) }.value
        return ValidationReport(
            valid: found.problems.isEmpty && found.missing.isEmpty, formatVersion: loaded.manifest.formatVersion,
            documentVersion: documentVersion, problems: found.problems, skippedEventLines: found.skipped,
            missingFiles: found.missing)
    }

    /// What is wrong with `project` and its `document`, read from the disk.
    private nonisolated static func check(
        _ project: LoadedProject, document: EditDocument
    ) -> (problems: [String], skipped: Int, missing: [String]) {
        var problems = DocumentRules.problems(in: document).map(sentence)
        let package = project.package
        if project.manifest.formatVersion >= 3, let log = try? EditLogReader.read(package.editLogURL), let line = log.damagedLine {
            problems.append("line \(line + 1) of edit-log.jsonl is damaged: Toma reads the log up to the line before it")
        }
        var skipped = 0
        var missing: [String] = []
        for take in project.takes {
            do {
                skipped += try EventLogReader.read(take: take.id, of: package).skippedLines
            } catch let error as POSIXError where error.code == .ENOENT {
                missing.append("takes/\(take.id)/events.jsonl")
            } catch {
                problems.append("the event log of \(take.id) cannot be read: it is a link or not a regular file")
            }
        }
        var named: [String] = []
        for take in project.takes {
            for track in take.tracks { named += track.segments.map(\.file) }
        }
        named += assets(of: document)
        var seen = Set<String>()
        for path in named where seen.insert(path).inserted && !exists(path, in: package.url) {
            missing.append(path)
        }
        return (problems, skipped, missing)
    }

    /// The files of `assets/` the document names: imported clips, images and clips over the output, music of the
    /// user's, a background image.
    private nonisolated static func assets(of document: EditDocument) -> [String] {
        var paths: [String] = []
        for clip in document.sequence {
            if case let .media(media)? = clip.content { paths.append(media.asset) }
        }
        for annotation in document.annotations.items {
            switch annotation.kind {
            case let .image(image): paths.append(image.asset)
            case let .clip(clip): paths.append(clip.asset)
            case .text, .arrow, .shape, .callout, .step: break
            }
        }
        paths += document.music.items.map(\.source)
        if case let .image(file) = document.style.background { paths.append(file) }
        return paths.filter { $0.hasPrefix("assets/") }
    }

    /// Whether something is at `path` from the package's folder, a link included (never followed).
    private nonisolated static func exists(_ path: String, in package: URL) -> Bool {
        var info = stat()
        return lstat(package.appending(path: path).path, &info) == 0
    }

    /// The manifest's `formatVersion` of a package that does not open, if its manifest can be read at all.
    private nonisolated static func formatVersion(at url: URL) -> Int? {
        guard let data = try? SafeRead.regularFile(at: url.appending(path: "manifest.json", directoryHint: .notDirectory)),
            case let .object(object)? = try? JSONDecoder().decode(JSONValue.self, from: data),
            let version = object["formatVersion"]?.double, version == version.rounded()
        else { return nil }
        return Int(version)
    }

    /// A rule of the document a document breaks, in a sentence.
    private nonisolated static func sentence(_ problem: DocumentProblem) -> String {
        switch problem {
        case let .contentNotAPoint(clip):
            "clip \(clip) has content but is not a point of its take"
        case let .outOfOrder(clip):
            "clip \(clip) starts before the end of an earlier clip of its take"
        case let .audioShiftOutOfRange(clip):
            "clip \(clip) shifts its sound further than its neighbours allow"
        case let .contentDuration(clip):
            "the content of clip \(clip) lasts longer or shorter than a clip may"
        case let .assetOutsideAssets(path):
            "\(path) is not a file of its kind in assets/ nor a theme of the library"
        case let .clipAnnotationAnchoredToContent(annotation):
            "annotation \(annotation) is a clip anchored to the take: a clip plays over the output only"
        case let .infoTooLong(field):
            "the \(field) is longer than \(field == "title" ? ProjectInfo.titleLimit : ProjectInfo.summaryLimit) characters"
        }
    }
}
