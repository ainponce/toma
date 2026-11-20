// SPDX-License-Identifier: GPL-3.0-or-later
import Darwin
import Foundation
import ProjectFormat

/// What the library shows of a project's document (1c design §6.8): the output's length and format, and the
/// `documentVersion` it is written in on disk (`EditSession.readOutline`).
public struct DocumentOutline: Equatable, Sendable {
    /// The output's length: `TimeMap(sequence:).durationSeconds` of the document's sequence.
    public var outputSeconds: Double
    public var aspect: Aspect
    /// The `documentVersion` the document is written in on disk, as `EditSession.readDocumentWithDiskVersion` gives it.
    public var diskVersion: Int
    /// The takes the sequence shows, each once, in the order it first shows them (phase 3 design §8.1: the library's
    /// camera is any of theirs).
    public var takes: [String]

    public init(outputSeconds: Double, aspect: Aspect, diskVersion: Int, takes: [String] = []) {
        self.outputSeconds = outputSeconds
        self.aspect = aspect
        self.diskVersion = diskVersion
        self.takes = takes
    }

    /// `document`'s, written on disk in `diskVersion`.
    public init(_ document: EditDocument, diskVersion: Int) {
        var takes: [String] = []
        for clip in document.sequence where !takes.contains(clip.take) { takes.append(clip.take) }
        self.init(
            outputSeconds: TimeMap(sequence: document.sequence).durationSeconds, aspect: document.aspect,
            diskVersion: diskVersion, takes: takes)
    }

    /// The outline of the document that comes from `project`'s events, `EditDocument.legacy(for:)` or, with
    /// `isNewDocument`, `NewDocument.make`, told without decoding them; `nil` where it depends on them.
    ///
    /// Both are 16:9 at `EditDocument.currentVersion`, and as long as no pause cuts it, a `NewDocument`'s sequence
    /// lasts what the legacy one's does: one clip at 1× over `TakeTimeline.editableBounds` (a take of 0 s keeps that
    /// clip). So the outline is that of the legacy document of the take without its events, unless:
    /// - two or more screens recorded a segment (`ScreenChoice.dependsOnEvents`): the screen whose bounds count is the
    ///   one under the first pointer position of the events;
    /// - for a `NewDocument`, the event log may hold a `paused` event, which cuts the clip
    ///   (`TakeTimeline.recordedSpans`). Told from its bytes, read with `SafeRead` and never decoded: it may when they
    ///   hold the word `paused`, or a `\` (an escape could spell it in a key or a value). Throws what reading it
    ///   throws, as the full read would.
    static func withoutEvents(of project: LoadedProject, isNewDocument: Bool) throws -> DocumentOutline? {
        let take = project.take
        guard !ScreenChoice.dependsOnEvents(take) else { return nil }
        if isNewDocument, try mayHoldAPause(take: take.id, of: project.package) { return nil }
        return DocumentOutline(EditDocument.legacy(take: take, events: []), diskVersion: EditDocument.currentVersion)
    }

    /// Whether the event log of `take` may hold a `paused` event, by its bytes; `false` without an event log.
    private static func mayHoldAPause(take: String, of package: ProjectPackage) throws -> Bool {
        let data: Data
        do {
            // Where `EventLogReader.read(take:of:)` reads it.
            data = try SafeRead.regularFile("takes/\(take)/events.jsonl", in: package.url)
        } catch let error as POSIXError where error.code == .ENOENT {
            return false
        }
        let word = Array("paused".utf8)
        return data.withUnsafeBytes { (bytes: UnsafeRawBufferPointer) in
            guard let base = bytes.baseAddress else { return false }
            return memchr(base, Int32(UInt8(ascii: "\\")), bytes.count) != nil
                || memmem(base, bytes.count, word, word.count) != nil
        }
    }
}
