// SPDX-License-Identifier: GPL-3.0-or-later
import Darwin
import Dispatch
import Foundation
import ProjectFormat
import Synchronization

/// What an edit session takes from the app (and what the tests and `edit-stress` replace).
public struct EditContext: Sendable {
    /// The app the `create` lines name.
    public var app: AppInfo
    /// Where every project's cache folder goes (`ProjectCaches.defaultRoot`).
    public var cachesRoot: URL
    /// The look a new project starts with.
    public var defaultStyle: DefaultStyle
    /// The clock: a `do` line keeps `now()` truncated to whole seconds, and the grouping of a burst uses the exact instant.
    public var now: @Sendable () -> Date
    /// A new id: `makeID("c-")` is `c-` and 8 random hex digits.
    public var makeID: @Sendable (String) -> String
    /// When the log is compacted (`LogCompaction.isNeeded`).
    public var compaction: (maxBytes: Int, maxEntries: Int)
    /// The journal's calls to the disk.
    public var journalIO: EditJournalIO
    /// The writes and waits of the upgrade of a version 1 or 2 package to version 3.
    public var upgradeIO: PackageUpgradeIO
    /// The folder of the default style (`DefaultStyleStore.defaultDirectory` in the app), where the image of an image
    /// background of `defaultStyle` is: a new project copies it into its `assets/`. Without it, a new project with such a
    /// background gets Toma's.
    public var styleDirectory: URL?
    /// The camera a new project starts with (1c design §13.3): that of the style of the new projects, mirrored and with a
    /// shadow in Toma's.
    public var cameraLook: CameraLook = .newProjects

    public init(
        app: AppInfo, cachesRoot: URL, defaultStyle: DefaultStyle, now: @escaping @Sendable () -> Date,
        makeID: @escaping @Sendable (String) -> String,
        compaction: (maxBytes: Int, maxEntries: Int) = (LogCompaction.maxBytes, LogCompaction.maxEntries),
        journalIO: EditJournalIO = .system, upgradeIO: PackageUpgradeIO = .system, styleDirectory: URL? = nil,
        cameraLook: CameraLook = .newProjects
    ) {
        self.app = app
        self.cachesRoot = cachesRoot
        self.defaultStyle = defaultStyle
        self.now = now
        self.makeID = makeID
        self.compaction = compaction
        self.journalIO = journalIO
        self.upgradeIO = upgradeIO
        self.styleDirectory = styleDirectory
        self.cameraLook = cameraLook
    }
}

/// Whether a session can change its project.
public enum EditAccess: Equatable, Sendable {
    case editable
    case readOnly(ReadOnlyReason)
}

/// Why a project opened read-only (design §5.9). Nothing is written to it.
public enum ReadOnlyReason: Equatable, Sendable {
    /// Another process holds `edit.lock`.
    case openElsewhere
    /// Another process took `edit.lock` before the first edit of a version 1 or 2 project could (Task 12b).
    case otherAppStartedEditing
    /// The package is on a volume or in a folder that cannot be written, or whose file system has no `flock`.
    case diskNotWritable
    /// The edit document is of this `documentVersion`, newer than this app's, or another process moved the package to
    /// this `formatVersion`, newer than this app's, before its first edit here: there is nothing to show.
    case newerDocument(Int)
    /// `edit.json`, `edit-log.jsonl` or `edit.lock` is a symlink or not a regular file, or the document holds values no
    /// render can draw (a frame rate other than 24, 25, 30, 50 or 60, a clip speed outside 0.25…16): what can be read
    /// safely is shown, those values clamped.
    case unsafeEditFiles
    /// Another process changed the package before its first edit here into one this app cannot open (a manifest that
    /// no longer decodes, a take it removed): as with `newerDocument`, there is nothing to show (the legacy document is
    /// only a placeholder: it would show what the other app cut); the app says the project could not be opened.
    case unreadable
}

/// What a session has to tell (design §5.9).
public enum EditNotice: Equatable, Sendable {
    /// A version 1 or 2 project without edits (or a version 3 one upgraded from them, without a log yet) keeps its look.
    case legacyLook
    /// The log was damaged: the edit opens up to this instant, and the whole damaged file is kept apart.
    case recovered(upTo: Date)
    /// Another process upgraded and edited the project before its first edit here: it was opened again (Task 12b).
    case reopenedAfterOtherApp
    /// The last change could not be saved yet (`JournalState.failing`); it waits in memory and is retried. Gone once it
    /// is saved.
    case saveFailed(POSIXErrorCode)
}

/// What a step did.
public enum EditOutcome: Equatable, Sendable {
    /// Applied in memory and handed to the journal.
    case applied
    /// Nothing changed: the project is read-only or closed, the step changes nothing, does not apply to the document or
    /// would leave one no render can draw, or there is nothing to undo or redo.
    case refused
    /// The first change of a version 1 or 2 project, or one that comes while the package moves to version 3, applied in
    /// memory (Task 12b, plan decision 28). Once the upgrade is done it is in the log, or, if another process got to the
    /// package first or it can never be written, discarded: `access` and `notices` tell, and `flushed()` waits for each
    /// attempt.
    case pendingUpgrade
}

/// One project open in the editor (design §6.5): its edit document in memory, every change made durable through
/// `edit-log.jsonl`, and `edit.json` as the snapshot that saves replaying it.
///
/// `perform`, `undo` and `redo` change the document at once and hand the line to the `EditJournal`, which syncs it on
/// its own queue: the main thread never waits for the disk. A line is written only once `EditDocument.applying` took the
/// change. `edit.json` with `logSequence` N is written only after the journal confirmed line N (plan decision 20): two
/// seconds after the last change, every 200 entries and at closing (`SnapshotPolicy`). The snapshot, the compaction and
/// the closing run on a serial queue of the session's files, never on the main actor, and everything is written
/// relative to the package folder's descriptor, so a package renamed or moved in the Finder while open still gets it.
///
/// Opening (`open`): a version 1 or 2 package is shown with its legacy document and nothing is written until its first
/// edit, which moves it to version 3 on the queue of files (`PackageUpgrade`, plan decision 28): that step and those that
/// come meanwhile apply in memory at once (`.pendingUpgrade`) and wait for it; once it is back they go to the log in
/// order, or, if another process took `edit.lock` first, they are discarded and the project goes back to its legacy
/// document, read-only (`.otherAppStartedEditing`); if the package is not the one opened any more, they are discarded
/// and it opens again from the disk (`.reopenedAfterOtherApp`), or, if it cannot be opened any more, nothing is shown
/// (`.newerDocument`, `.unreadable`). An error that can pass (a full disk, `EIO`, a log that cannot be opened for
/// appending yet) keeps every step in memory, in order, with `.saveFailed`, and the upgrade is tried again every
/// `EditJournal.retryInterval` from the step it reached, the lock held; one that never can (a volume or folder that
/// cannot be written) discards them, read-only.
///
/// A version 3 package takes `edit.lock` and reads `edit.json` and `edit-log.jsonl` without following a symlink or
/// blocking on a FIFO; then, as design §6.5 and plan decision 5 say: with a log, its replay (from the snapshot when the
/// log has its line) and the undo history of the lines it applied; with a damaged line, or one that does not match, the
/// file is copied whole to `edit-log.jsonl.damaged-<yyyyMMdd-HHmmss>` and rewritten up to the last good line, unless
/// `edit.json` is newer than every good line: then the snapshot opens and the log becomes one `create` of it (the undo
/// history before it is lost, never an edit); with `upgradedFrom` and no log, the legacy document, whose `create` the
/// first edit writes; with only `edit.json`, that snapshot with an empty history and a log that starts with a `create`
/// of it; with neither, `NewDocument`, written at once. A log cut short is truncated and synced before the journal opens
/// it; one past `context.compaction` is compacted through the journal (`replaceLog`), after a snapshot at its last line,
/// and only if that makes it shorter.
///
/// A project of 1b, whose document is of `documentVersion` 1, stays in version 1 on disk until its first edit (1c design
/// §13.2): the session shows it migrated, but while `pendingMigration` holds, everything it writes is version 1 (the
/// snapshot, the compaction, the repair of the log), so the app of 1b still opens a project 1c only looked at. The first
/// line it hands to the journal (`perform`, `undo` or `redo`) goes with the `migrate` lines before it, in one write
/// (`EditJournal.append(_:)` of both); from then on the snapshot is of the current version. Every `create` the session
/// writes again keeps the version the log's `create` is written in (`createVersion`).
@MainActor
public final class EditSession {
    /// The project as opened; its manifest is the one the upgrade to version 3 wrote, once it did.
    public private(set) var project: LoadedProject
    public private(set) var document: EditDocument
    /// Grows with every change of `document`.
    public private(set) var revision = 0
    public private(set) var access: EditAccess
    public private(set) var notices: [EditNotice]
    /// Called on the main actor after each change of `document`, `access` or `notices`.
    public var onChange: (() -> Void)?

    private let context: EditContext
    private let projectCaches: ProjectCaches
    private let folder: PackageFolder
    /// The session's queue of files: snapshots, compactions and the closing.
    private let files = DispatchQueue(label: "dev.toma.EditSession.files", qos: .userInitiated)
    private var lock: HeldRecordingLock?
    private var journal: EditJournal?
    private var history = UndoHistory(entries: [])
    /// The changes of the `do` lines of each group in the stacks, in order.
    private var groups: [Int: [EditChange]] = [:]
    /// The lines of the log: those on disk at opening and those given to the journal since.
    private var entries: [EditLogEntry] = []
    private var logBytes = 0
    /// The `seq` of the last line on disk before the journal took any line; 0 without one.
    private var baseSeq = 0
    /// The `seq` of each line given to the journal, in order.
    private var appendedSeqs: [Int] = []
    /// The `documentVersion` `document` is written in on disk (1c design §13.2): the replay's (`EditReplay.version`) or
    /// the snapshot's it opened from; `EditDocument.currentVersion` for a new document, a legacy one, and once the session
    /// handed the journal a line, which migrates it.
    private var diskVersion = EditDocument.currentVersion
    /// The `documentVersion` the log's `create` is written in (`EditLogRead.createVersion`): every `create` the session
    /// writes again (the compaction at opening and at closing, the repair) keeps it, whether or not it migrated since.
    private var createVersion = EditDocument.currentVersion
    /// The document is of an older version on disk and no line was handed to the journal yet: what the session writes
    /// is written in `diskVersion`, and the first line goes with its `migrate`.
    private var pendingMigration: Bool { diskVersion < EditDocument.currentVersion }
    /// The legacy document whose `create` the first edit writes (version 1 or 2, or 3 with `upgradedFrom` and no log).
    private var pendingCreate: EditDocument?
    /// The manifest of a version 1 or 2 package as it was opened, while it can be edited and is not upgraded yet.
    private var legacyManifest: Manifest?
    /// The upgrade to version 3 under way.
    private var upgrade: PendingUpgrade?
    private var snapshotPolicy = SnapshotPolicy(entriesSinceSnapshot: 0)
    /// The `logSequence` of the `edit.json` on disk, when it names a line of the log.
    private var snapshotSeq: Int?
    private var snapshotTask: Task<Void, Never>?
    private var snapshotWanted = false
    private var idleTask: Task<Void, Never>?
    /// The log went away under the journal: a new one is being started.
    private var restartingLog = false
    private var restartTask: Task<Void, Never>?
    private var isClosed = false
    private var lastKnownURL: URL
    /// How many times the package was opened again from the disk after another process changed it (Task 12b).
    private var reopenings = 0

    private init(_ opened: Opened, context: EditContext) {
        project = opened.project
        document = opened.document
        access = opened.access
        notices = opened.notices
        self.context = context
        projectCaches = opened.caches
        folder = opened.folder
        lastKnownURL = opened.url
        adopt(opened)
    }

    /// Takes what opening found: at `open`, and again when the package is opened anew from the disk (Task 12b).
    private func adopt(_ opened: Opened) {
        project = opened.project
        document = opened.document
        access = opened.access
        notices = opened.notices
        lock = opened.lock
        journal = opened.journal
        history = opened.history
        groups = opened.groups
        entries = opened.entries
        logBytes = opened.logBytes
        baseSeq = opened.baseSeq
        appendedSeqs = opened.appendedSeqs
        diskVersion = opened.diskVersion
        createVersion = opened.createVersion
        pendingCreate = opened.pendingCreate
        let manifest = opened.project.manifest
        legacyManifest = manifest.formatVersion < 3 && opened.access == .editable ? manifest : nil
        snapshotSeq = opened.snapshotSeq
        snapshotPolicy = SnapshotPolicy(
            entriesSinceSnapshot: opened.snapshotSeq.map { seq in opened.entries.count(where: { $0.seq > seq }) }
                ?? opened.entries.count)
        if let journal {
            listen(to: journal)
            // A change before the session listened is never told again: what the journal is in now counts.
            journalChanged(to: journal.state)
        }
    }

    /// Opens the project at `url` for editing, its take `take` (the last one when `nil`). The work on files runs off
    /// the main actor. Throws what `LoadedProject.load` throws, and the error of an edit file that cannot be read for
    /// another reason than the ones `ReadOnlyReason` names.
    public static func open(_ url: URL, take: String?, context: EditContext) async throws -> EditSession {
        EditSession(try await Opening.open(url, take: take, context: context), context: context)
    }

    /// The project at `url` and its document as `open` would show it, without taking the lock or writing anything (for
    /// `recorder-dev`, the export and the library's thumbnails): a damaged log is replayed up to its last good line in
    /// memory, and a new project gets a `NewDocument` that is not saved. Throws `EditDocumentError.newerVersion` for a
    /// newer document and the `POSIXError` (`ELOOP`, `EFTYPE`) of an edit file that is a symlink or not a regular file:
    /// the take without its edit would show what was cut.
    ///
    /// The project comes with its events read (`LoadedProject.load(_:take:)`'s, whatever the document comes from), for
    /// the callers that draw or rebuild from them: an event log that cannot be read is thrown here, never drawn as no
    /// events. `readDocumentWithDiskVersion(_:take:context:)` gives a project that reads them only when asked for.
    public nonisolated static func readDocument(
        _ url: URL, take: String?, context: EditContext
    ) throws -> (LoadedProject, EditDocument) {
        let (project, document, _) = try readDocumentWithDiskVersion(url, take: take, context: context)
        try project.readEvents()
        return (project, document)
    }

    /// The document `readDocument(_:take:context:)` reads, and the `documentVersion` it is written in on disk (1c
    /// design §13.2): 1 for a project of 1b that has not been edited in 1c, which `document` shows migrated;
    /// `EditDocument.currentVersion` for one edited since, a legacy document (version 1 or 2 package) and a new one.
    ///
    /// The take's event log is read only for a document that comes from it, the legacy one (a version 1 or 2 package,
    /// one upgraded and never edited) or a `NewDocument`, and an error reading it is thrown then, as
    /// `LoadedProject.load` throws it. A document that comes from the edit files never needs it (the replay never reads
    /// events), and its project reads them only when they are asked for (`LoadedProject.events`, which then has none if
    /// they cannot be read; `LoadedProject.readEvents()` throws why): what does not use them never opens `events.jsonl`
    /// (Task 31b, design §15). One that is a link, is reached through one or is not a regular file is refused all the
    /// same, at once (`LoadedProject.load(_:take:deferringEvents:)`).
    public nonisolated static func readDocumentWithDiskVersion(
        _ url: URL, take: String?, context: EditContext
    ) throws -> (LoadedProject, EditDocument, diskVersion: Int) {
        try readDocumentWithDiskVersion(url, take: take, context: context, readingEvents: LoadedProject.takeEvents)
    }

    /// `readDocumentWithDiskVersion(_:take:context:)` with the take's events read by `read`.
    package nonisolated static func readDocumentWithDiskVersion(
        _ url: URL, take: String?, context: EditContext, readingEvents read: @escaping LoadedProject.EventsReader
    ) throws -> (LoadedProject, EditDocument, diskVersion: Int) {
        let project = try LoadedProject.load(url, take: take, deferringEvents: read)
        let files = try readOnlyEditFiles(of: project)
        let (document, diskVersion) = try readOnlyDocument(of: project, files: files, context: context)
        return (project, document, diskVersion)
    }

    /// What the library shows of the document `readDocumentWithDiskVersion(_:take:context:)` reads (design §6.8): its
    /// output's length and format and the version it is written in, equal to that document's
    /// (`DocumentOutline(_:diskVersion:)`). Read as it reads them, with the same errors, except that a document that
    /// would come from the take's events is told from the take without decoding them where it does not depend on them
    /// (`DocumentOutline.withoutEvents`): a version 1 or 2 package, or a version 3 one without edit files, of a take
    /// with at most one screen that recorded something, and for a `NewDocument` an event log that holds no pause. The
    /// project reads its events only when they are asked for, as `readDocumentWithDiskVersion`'s does.
    public nonisolated static func readOutline(
        _ url: URL, take: String?, context: EditContext
    ) throws -> (LoadedProject, DocumentOutline) {
        try readOutline(url, take: take, context: context, readingEvents: LoadedProject.takeEvents)
    }

    /// `readOutline(_:take:context:)` with the take's events read by `read`.
    package nonisolated static func readOutline(
        _ url: URL, take: String?, context: EditContext, readingEvents read: @escaping LoadedProject.EventsReader
    ) throws -> (LoadedProject, DocumentOutline) {
        let project = try LoadedProject.load(url, take: take, deferringEvents: read)
        let files = try readOnlyEditFiles(of: project)
        // Without edit files, a version 3 document comes from the events as a version 1 or 2 one does (`Resolution.of`
        // with no log and no `edit.json`): the legacy one if the package was upgraded, a `NewDocument` if not.
        if files.map({ $0.log == nil && $0.snapshot.isMissing }) ?? true {
            let isNew = files != nil && project.manifest.upgradedFrom == nil
            if let outline = try DocumentOutline.withoutEvents(of: project, isNewDocument: isNew) {
                return (project, outline)
            }
        }
        let (document, diskVersion) = try readOnlyDocument(of: project, files: files, context: context)
        return (project, DocumentOutline(document, diskVersion: diskVersion))
    }

    /// The edit files of a version 3 project for a read without the lock, `nil` for a version 1 or 2 one (which never
    /// looks at them): throws `EditDocumentError.newerVersion` for a newer document and the `POSIXError` of an edit
    /// file that is a symlink or not a regular file.
    private nonisolated static func readOnlyEditFiles(of project: LoadedProject) throws -> EditFiles? {
        guard project.manifest.formatVersion >= 3 else { return nil }
        let files = try EditFiles.read(project.package)
        if let version = files.newerVersion { throw EditDocumentError.newerVersion(version) }
        if let code = files.unsafe { throw POSIXError(code) }
        return files
    }

    /// The document `project` shows read-only with its edit `files` (`nil` for a version 1 or 2 package: the legacy
    /// one), and the version it is written in on disk. Its events are read only for a document that comes from them.
    private nonisolated static func readOnlyDocument(
        of project: LoadedProject, files: EditFiles?, context: EditContext
    ) throws -> (EditDocument, diskVersion: Int) {
        guard let files else {
            try project.readEvents()
            return (.legacy(for: project), EditDocument.currentVersion)
        }
        let resolution = try Resolution.of(project, files: files, context: context) { project in
            try project.readEvents()
            return project
        }
        return (resolution.shown, resolution.diskVersion)
    }

    /// Where the package is now (`F_GETPATH` of its folder), for what goes by path (importing an asset, the export, the
    /// caches); where it was last seen once the session is closed.
    public var packageURL: URL {
        if let path = folder.path() { lastKnownURL = URL(fileURLWithPath: path, isDirectory: true) }
        return lastKnownURL
    }

    public var caches: ProjectCaches { projectCaches }

    /// The label of the next undo; `nil` without one, while the project cannot be edited, and while a new log starts
    /// (nothing can be undone then: `canUndo` is false).
    public var undoLabel: EditLabel? { isEditable && !restartingLog ? history.undoLabel : nil }

    public var redoLabel: EditLabel? { isEditable && !restartingLog ? history.redoLabel : nil }

    /// Some change is not on disk yet (`JournalState` is not `.saved`), or is not in a log at all while a new one starts
    /// or while the package moves to version 3. Never depends on the snapshot, which the log can always make again.
    public var hasUnsavedChanges: Bool {
        guard let journal else { return upgrade != nil }
        return restartingLog || journal.state != .saved
    }

    /// Applies `step` and hands its `do` line to the journal, without waiting for the disk. A step with the same label
    /// and target as the last one, less than 1 s after it, joins its undo group (design §6.4). The first step of a
    /// version 1 or 2 package starts its upgrade to version 3, and the line waits for it, as those of the steps that come
    /// meanwhile do (`.pendingUpgrade`). The first line of a project of 1b goes with its `migrate` (`pendingMigration`).
    public func perform(_ step: EditStep) -> EditOutcome {
        guard isEditable, !step.changes.isEmpty, let next = try? document.applying(step.changes), next.isDrawable
        else { return .refused }
        if restartingLog {
            // The new log starts with a `create` of the document as it is then, this step included: an edited document,
            // of the current version.
            diskVersion = EditDocument.currentVersion
            change(to: next, seq: document.logSequence)
            return .applied
        }
        let at = context.now()
        // The lines before the `do` are recorded first, since they number it; only once they are handed over is the
        // history kept: if they are not, the next step writes them again.
        var history = history
        var lines = migrations(recordedIn: &history)
        if let create = legacyCreate(seq: history.nextSeq) {
            history.record(create)
            lines.append(create)
        }
        let group = history.groupForNext(step, at: at)
        let line = EditLogEntry.do(
            seq: history.nextSeq, group: group, label: step.label.rawValue, changes: step.changes, at: at.roundedToWholeSeconds)
        lines.append(line)
        guard let outcome = hand(lines, first: step, at: at) else { return .refused }
        // The first edit of a package upgraded without a log: it is not a project without edits any more (design §5.9).
        if pendingCreate != nil, outcome == .applied { notices.removeAll { $0 == .legacyLook } }
        // A new group ends what could be redone.
        let closing = groups[group] == nil ? history.undone : []
        history.record(line)
        self.history = history
        pendingCreate = nil
        diskVersion = EditDocument.currentVersion
        for group in closing { groups[group] = nil }
        groups[group, default: []] += step.changes
        change(to: next, seq: line.seq)
        return outcome
    }

    /// Whether `undo()` would undo a group now, rather than refuse: the Edit menu offers it only then. Changes nothing.
    /// `false` too where the first line's `migrate` would cut the history (1c design §13.2), as `undo()` refuses then.
    public var canUndo: Bool { undoing() != nil }

    /// Whether `redo()` would redo a group now, rather than refuse. Changes nothing; `false` where the first line's
    /// `migrate` would cut the history, as for `canUndo`.
    public var canRedo: Bool { redoing() != nil }

    /// An undo or a redo as it would be handed over: its lines (the `migrate` lines first while `pendingMigration`
    /// holds, then its own), the history once they are recorded, and the document it leaves.
    private struct HistoryStep {
        var lines: [EditLogEntry]
        var history: UndoHistory
        var next: EditDocument
    }

    /// The undo of the group on top of the undo stack; `nil` when `undo()` refuses.
    private func undoing() -> HistoryStep? {
        guard isEditable, !restartingLog, let group = history.done.last, let changes = groups[group],
            let next = try? document.applying(changes.reversed().map(\.inverse)), next.isDrawable
        else { return nil }
        return historyStep(to: next) { history in
            history.done.last == group ? .undo(seq: history.nextSeq, group: group) : nil
        }
    }

    /// The redo of the group on top of the redo stack; `nil` when `redo()` refuses.
    private func redoing() -> HistoryStep? {
        guard isEditable, !restartingLog, let group = history.undone.last, let changes = groups[group],
            let next = try? document.applying(changes), next.isDrawable
        else { return nil }
        return historyStep(to: next) { history in
            history.undone.last == group ? .redo(seq: history.nextSeq, group: group) : nil
        }
    }

    /// Undoes the group on top of the undo stack.
    public func undo() -> EditOutcome { take(undoing()) }

    /// Redoes the group on top of the redo stack.
    public func redo() -> EditOutcome { take(redoing()) }

    /// Copies the image at `url` into the package's `assets/` for a background (`AssetImport.copy`), for the step that
    /// names it, which comes after: `.imported(path)` once it is on the drive. The file is decoded first, on the queue of
    /// files, as the package's asset reader decodes one: `.notAnImage` if it does not, and nothing is written.
    ///
    /// A version 1 or 2 package moves to version 3 first, with only the `create` of its legacy document (the upgrade with
    /// no step), or after the upgrade a step started: nothing is copied into a package that is not at version 3 yet. An
    /// error that passes, of that upgrade (tried again, as for `perform`) or of the copy (a full disk, `EIO`), is shown as
    /// `EditNotice.saveFailed`, and the import waits and is tried again every `EditJournal.retryInterval`, as an edit's
    /// line is; it gives up with `.saveFailed` if the caller's task is cancelled or the session closes meanwhile, and at
    /// once for an error that never passes (`Opening.lastingRefusal`). A disk's error is never `.notAnImage`.
    /// `.notEditable` while the project cannot be edited, if another process took `edit.lock` first (read-only then) or
    /// changed the package (it is opened again), as with `perform`.
    public func importAsset(_ url: URL) async -> AssetImportOutcome {
        guard isEditable else { return .notEditable }
        guard (try? await Self.run(on: files, { AssetImport.decodes(url) })) == true else { return .notAnImage }
        guard isEditable else { return .notEditable }
        let reopened = reopenings
        if journal == nil, upgrade == nil, let manifest = legacyManifest, let legacy = pendingCreate,
            let create = legacyCreate(seq: history.nextSeq), (try? create.jsonLine()) != nil
        {
            history.record(create)
            pendingCreate = nil
            startUpgrade(manifest, legacy: legacy, first: nil, at: context.now(), lines: [create])
            change(to: document, seq: create.seq)
        }
        // The upgrade through its attempts, the failed ones shown by `finishUpgradeAttempt`.
        while let upgrade {
            if Task.isCancelled { return .saveFailed(shownSaveFailure ?? .ECANCELED) }
            if let attempt = upgrade.attempt {
                await attempt.value
            } else if let retry = upgrade.retry {
                await retry.value
            } else {
                // Closed after its last attempt failed.
                break
            }
        }
        guard reopenings == reopened, isEditable, journal != nil else {
            return upgrade != nil ? .saveFailed(shownSaveFailure ?? .EIO) : .notEditable
        }
        var failing: POSIXErrorCode?
        defer { if failing != nil { showSaveFailed(journalFailure) } }
        while true {
            let package = ProjectPackage(url: packageURL)
            let placed = (try? await Self.run(on: files) { () -> Result<String, AssetImport.Failure> in
                Result { () throws(AssetImport.Failure) in try AssetImport.place(url, into: package) }
            }) ?? .failure(.destination(POSIXError(.EIO)))
            switch placed {
            case let .success(path):
                return .imported(path)
            case .failure(.unsupported), .failure(.source), .failure(.changed):
                return .notAnImage
            case let .failure(.destination(error)):
                guard Opening.lastingRefusal(error) == nil else { return .saveFailed(error.code) }
                failing = error.code
                showSaveFailed(error.code)
                try? await Task.sleep(for: EditJournal.retryInterval)
                guard !Task.isCancelled, isEditable else { return .saveFailed(error.code) }
            }
        }
    }

    /// "Apply Default Style" (design §5.9): `StyleCommands.applyDefaultStyle` of `style` for the take, as one step that
    /// `perform` takes. An image background is brought into the package first from `styleDirectory`, the default style's
    /// folder (its `<sha>.<ext>`, with `importAsset`); without the folder, or if the image is not there, does not decode
    /// or cannot be saved, the classic gradient (`Background.tomaClassic`) is applied in its place. `.refused` if the
    /// project cannot be edited, or has all of it already.
    public func applyDefaultStyle(_ style: DefaultStyle, styleDirectory: URL?) async -> EditOutcome {
        guard isEditable else { return .refused }
        var style = style
        if case let .image(file) = style.style.background {
            var background = Background.tomaClassic
            if let styleDirectory, let name = DefaultStyleStore.assetName(file) {
                switch await importAsset(styleDirectory.appending(path: name)) {
                case let .imported(path): background = .image(file: path)
                case .notEditable: return .refused
                case .notAnImage, .saveFailed: break
                }
            }
            style.style.background = background
        }
        guard let step = StyleCommands.applyDefaultStyle(document, style, take: project.take, events: project.events)
        else { return .refused }
        return perform(step)
    }

    /// "Apply" a named style (1c design §8): `StyleCommands.applyStyle` of `style` for the take, as one step that `perform`
    /// takes. An image background is brought into the package first from `imageDirectory`, the folder of the style's
    /// image (`StyleLibrary.imageDirectory(of:)`), with `importAsset`, as `applyDefaultStyle` does; without the folder, or
    /// if the image is not there or does not decode, the rest is applied and the project keeps its background
    /// (`imageMissing`). An error of the disk is never a missing image: `importAsset` tries it again meanwhile, and if it
    /// gives up (`.saveFailed`, shown in `notices`) nothing is applied. `.refused` if the project cannot be edited, or has
    /// all of it already.
    public func applyStyle(_ style: NamedStyle, imageDirectory: URL?) async -> (outcome: EditOutcome, imageMissing: Bool) {
        guard isEditable else { return (.refused, false) }
        var style = style
        var imageMissing = false
        if case let .image(file) = style.look.style.background {
            var imported: String?
            if let imageDirectory, let name = DefaultStyleStore.assetName(file) {
                switch await importAsset(imageDirectory.appending(path: name)) {
                case let .imported(path): imported = path
                case .notEditable, .saveFailed: return (.refused, false)
                case .notAnImage: break
                }
            }
            imageMissing = imported == nil
            // The document as it is after the import, which waited.
            style.look.style.background = imported.map { .image(file: $0) } ?? document.style.background
        }
        guard let step = StyleCommands.applyStyle(document, style, take: project.take, events: project.events)
        else { return (.refused, imageMissing) }
        return (perform(step), imageMissing)
    }

    /// Waits for the attempt at the upgrade to version 3 under way to come back, then until the journal confirmed every
    /// line handed to it before the call, or an attempt to write one failed, and returns the `seq` of the last line on
    /// disk: 0 without a log.
    public func flushed() async -> Int {
        while let attempt = upgrade?.attempt { await attempt.value }
        guard let journal else { return baseSeq }
        let (base, seqs) = (baseSeq, appendedSeqs)
        let confirmed = await journal.flushed()
        // Lines handed over meanwhile can be confirmed with the ones before them.
        let known = journal === self.journal ? appendedSeqs : seqs
        return confirmed == 0 ? base : known[min(confirmed, known.count) - 1]
    }

    /// Stops taking steps, writes the snapshot and compacts the log if every line is on disk, closes the journal (one
    /// last attempt for the lines that are not), releases `edit.lock` and closes the folder. Lines still not on disk are
    /// lost then, and `hasUnsavedChanges` stays `true`: the app asks before closing (design §5.9).
    public func close() async {
        guard !isClosed else { return }
        isClosed = true
        // The upgrade under way comes back first, after one last attempt if it was waiting to try again: its lines go to
        // the journal, which closes below. If it still fails, they are lost and `hasUnsavedChanges` stays `true`.
        if upgrade != nil {
            upgrade?.retry?.cancel()
            upgrade?.retry = nil
            runUpgradeAttempt()
            while let attempt = upgrade?.attempt { await attempt.value }
        }
        idleTask?.cancel()
        restartTask?.cancel()
        // A new log whose files are touched already gets its `create`, which the journal saves below.
        await restartTask?.value
        await snapshotTask?.value
        if let journal {
            if !restartingLog, await journal.flushed() == appendedSeqs.count, journal.state == .saved {
                await writeSnapshotIfBehind()
                await compactIfNeeded(journal)
            }
            await journal.close()
            if !restartingLog, journal.state == .saved { await writeSnapshotIfBehind() }
        }
        let (lock, folder) = (self.lock, self.folder)
        self.lock = nil
        _ = packageURL
        try? await Self.run(on: files) {
            // Through the folder: a package moved while open loses its own lock file, and nothing at its old path goes.
            lock?.release(inDirectory: folder.descriptor)
            folder.close()
        }
    }

    // MARK: - Lines

    private var isEditable: Bool {
        access == .editable && !isClosed && (journal != nil || upgrade != nil || legacyManifest != nil)
    }

    /// The `seq` of the last line of the log.
    private var lastSeq: Int { entries.last?.seq ?? 0 }

    /// Hands `lines` on: to the journal (`.applied`); in a version 1 or 2 package, those of the first step, `first`
    /// made at `at`, to the upgrade they start, and any others behind it (`.pendingUpgrade`). `nil`, and nothing handed
    /// over, if one cannot be encoded or the journal is closed.
    private func hand(_ lines: [EditLogEntry], first step: EditStep? = nil, at: Date? = nil) -> EditOutcome? {
        if let journal { return append(lines, to: journal) ? .applied : nil }
        if upgrade != nil {
            guard (try? lines.map({ try $0.jsonLine() })) != nil else { return nil }
            upgrade?.queued += lines
            return .pendingUpgrade
        }
        // Only a step can come first: before it there is nothing to undo or redo. Its lines are encoded on the queue of
        // files, with the manifest.
        guard let manifest = legacyManifest, let step, let at, let legacy = pendingCreate else { return nil }
        startUpgrade(manifest, legacy: legacy, first: step, at: at, lines: lines)
        return .pendingUpgrade
    }

    /// The undo or the redo whose line `line` makes from the history after the `migrate` lines of the first line while
    /// `pendingMigration` holds, leaving `next`. Changes nothing. `nil` when `line` gives `nil`, its group not on top any
    /// more: a `migrate` that cuts the history (a line of 1b before it writes inside of what it adds, 1c design §13.2)
    /// leaves nothing before it to undo or redo, and the step is refused.
    private func historyStep(to next: EditDocument, _ line: (UndoHistory) -> EditLogEntry?) -> HistoryStep? {
        var history = history
        var lines = migrations(recordedIn: &history)
        guard let last = line(history) else { return nil }
        lines.append(last)
        history.record(last)
        return HistoryStep(lines: lines, history: history, next: next)
    }

    /// Hands the lines of `step`, an undo or a redo, to the journal, and moves the document to the one it leaves;
    /// `.refused` without one, or if they cannot be handed over.
    private func take(_ step: HistoryStep?) -> EditOutcome {
        guard let step, let last = step.lines.last, let outcome = hand(step.lines) else { return .refused }
        history = step.history
        diskVersion = EditDocument.currentVersion
        change(to: step.next, seq: last.seq)
        return outcome
    }

    /// The `migrate` lines that go before the first line the session hands to the journal while `pendingMigration`
    /// holds (1c design §13.2), one for each version from `diskVersion` to the current one, numbered from
    /// `history.nextSeq` and recorded in `history`; none otherwise.
    private func migrations(recordedIn history: inout UndoHistory) -> [EditLogEntry] {
        guard pendingMigration else { return [] }
        return (diskVersion..<EditDocument.currentVersion).map { from in
            let migrate = EditLogEntry.migrate(seq: history.nextSeq, from: from, to: from + 1)
            history.record(migrate)
            return migrate
        }
    }

    /// Hands `lines` to the journal, all at once (`EditJournal.append(_:)`: one write); `false`, and nothing handed
    /// over, if one cannot be encoded or the journal is closed.
    private func append(_ lines: [EditLogEntry], to journal: EditJournal) -> Bool {
        guard let encoded = try? lines.map({ try $0.jsonLine(writingDocumentAt: createVersion) }),
            // Only a closed journal throws.
            (try? journal.append(encoded)) != nil
        else { return false }
        appendedSeqs += lines.map(\.seq)
        entries += lines
        logBytes += encoded.reduce(0) { $0 + $1.utf8.count + 1 }
        snapshotPolicy.entriesSinceSnapshot += lines.count
        snapshotPolicy.lastChange = .now
        if snapshotPolicy.isDue(now: .now) {
            startSnapshot()
        } else {
            armIdleTimer()
        }
        return true
    }

    private func change(to next: EditDocument, seq: Int) {
        document = next
        document.logSequence = seq
        revision += 1
        onChange?()
    }

    private func listen(to journal: EditJournal) {
        journal.onStateChange { [weak self, weak journal] state in
            MainActor.assumeIsolated {
                guard let self, let journal, self.journal === journal else { return }
                self.journalChanged(to: state)
            }
        }
    }

    private func journalChanged(to state: JournalState) {
        switch state {
        case let .failing(code):
            showSaveFailed(code)
            // The log is gone, or another file is at its name: its lines can never be confirmed there.
            if code == .ENOENT || code == .ESTALE { restartLog() }
        case .saved:
            showSaveFailed(nil)
            snapshotIfDue()
        case .pending:
            break
        }
    }

    /// The `create` of the legacy document whose `create` the first edit writes (`pendingCreate`), numbered `seq`, the
    /// next line's; `nil` without one.
    private func legacyCreate(seq: Int) -> EditLogEntry? {
        guard var created = pendingCreate else { return nil }
        created.logSequence = seq
        return .create(seq: seq, document: created, app: context.app)
    }

    /// The code of the `.saveFailed` shown, if one is.
    private var shownSaveFailure: POSIXErrorCode? {
        notices.lazy.compactMap { if case let .saveFailed(code) = $0 { code } else { nil } }.first
    }

    /// The code of the journal's failure, if it is failing.
    private var journalFailure: POSIXErrorCode? {
        if case let .failing(code)? = journal?.state { code } else { nil }
    }

    private func showSaveFailed(_ code: POSIXErrorCode?) {
        var updated = notices.filter { if case .saveFailed = $0 { false } else { true } }
        if let code { updated.append(.saveFailed(code)) }
        guard updated != notices else { return }
        notices = updated
        onChange?()
    }

    /// The log went away under the journal (`ENOENT`) or another file took its name (`ESTALE`): once the journal is
    /// closed, a new log starts with a `create` of the document as it is then, so no edit is lost, only the undo history
    /// before it (as with plan decision 5). Steps that come meanwhile change the document and go into that `create`.
    private func restartLog() {
        guard isEditable, !restartingLog, let old = journal else { return }
        restartingLog = true
        // Nothing can be undone or redone until it has started: said now, after the flag (the labels read it).
        onChange?()
        idleTask?.cancel()
        restartTask = Task { [weak self] in
            await old.close()
            await self?.startNewLog()
        }
    }

    /// Whatever is at the log's name is moved aside (never removed) and a new journal opened, on the queue of files;
    /// then, back on the main actor, the journal takes a `create` of the document as it is by then: no sync waits here,
    /// the journal syncs on its queue. The `create` is encoded before anything is touched, so a document that could not
    /// be encoded never moves a log aside. Tried again every `EditJournal.retryInterval` until it works. Once the files
    /// are touched it goes to the end even if the session is closing, which waits for it: the old log is aside by then.
    private func startNewLog() async {
        guard !isClosed, restartingLog else { return }
        guard (try? createOfDocument()) != nil else { return retryNewLog() }
        let (files, folder, now, io) = (files, folder, context.now(), context.journalIO)
        let opened = try? await Self.run(on: files) { () -> EditJournal in
            try folder.moveAside(Opening.logName, now: now)
            guard let path = folder.path() else { throw POSIXError(.EBADF) }
            let package = URL(fileURLWithPath: path, isDirectory: true)
            return try EditJournal(logURL: package.appending(path: Opening.logName), io: io)
        }
        guard let journal = opened, let new = try? createOfDocument() else {
            if let opened { await opened.close() }
            return retryNewLog()
        }
        let (create, line) = new
        // Listened to before the line goes, and its state read after: a change before the session listens is never lost.
        self.journal = journal
        listen(to: journal)
        guard (try? journal.append(line)) != nil else { return retryNewLog() }
        createVersion = diskVersion
        history = UndoHistory(entries: [create], createVersion: createVersion)
        groups = [:]
        entries = [create]
        logBytes = line.utf8.count + 1
        baseSeq = 0
        appendedSeqs = [create.seq]
        pendingCreate = nil
        snapshotSeq = nil
        snapshotPolicy = SnapshotPolicy(entriesSinceSnapshot: 1, lastChange: .now)
        restartingLog = false
        document.logSequence = create.seq
        startSnapshot()
        onChange?()
        journalChanged(to: journal.state)
    }

    /// The `create` that starts a new log with the document as it is now, and its line, written in `diskVersion`: a
    /// project of 1b not edited yet stays in version 1.
    private func createOfDocument() throws -> (EditLogEntry, String) {
        var created = document
        created.logSequence = history.nextSeq
        let create = EditLogEntry.create(seq: created.logSequence, document: created, app: context.app)
        return (create, try create.jsonLine(writingDocumentAt: diskVersion))
    }

    private func retryNewLog() {
        guard !isClosed, restartingLog else { return }
        restartTask = Task { [weak self] in
            try? await Task.sleep(for: EditJournal.retryInterval)
            guard !Task.isCancelled else { return }
            await self?.startNewLog()
        }
    }

    // MARK: - The upgrade to version 3

    /// The upgrade to version 3 that the first edit of a version 1 or 2 package started (Task 12b, plan decision 28),
    /// until it is done or refused.
    private struct PendingUpgrade {
        /// The manifest as the package was opened.
        var opened: Manifest
        /// The document as the package has it, which a refused upgrade goes back to.
        var legacy: EditDocument
        /// The first step (none for `importAsset`) and when it was made: the upgrade's clock is that instant.
        var first: EditStep?
        var at: Date
        /// What the upgrade writes: the `create` and the `do` of the first step.
        var written: [EditLogEntry]
        /// The lines of the steps that came after the first one, in order.
        var queued: [EditLogEntry] = []
        /// How far the last attempt got, with the lock it holds; `nil` before the first one.
        var progress: PackageUpgrade.Progress?
        /// The attempt under way.
        var attempt: Task<Void, Never>?
        /// The wait before the next attempt, after one that failed.
        var retry: Task<Void, Never>?
    }

    /// Starts moving the package to version 3 with `step`, made at `at`, whose `lines` (`create` and `do`) the upgrade
    /// writes as `perform` numbered them. Without a step (`importAsset`), only the `create`. Nothing here waits for the
    /// lock or the disk.
    private func startUpgrade(
        _ manifest: Manifest, legacy: EditDocument, first step: EditStep?, at: Date, lines: [EditLogEntry]
    ) {
        assert((try? PackageUpgrade.entries(legacy: legacy, first: step, at: at, app: context.app)) == lines)
        upgrade = PendingUpgrade(opened: manifest, legacy: legacy, first: step, at: at, written: lines)
        runUpgradeAttempt()
    }

    /// One attempt at the upgrade, from where the last one got, unless one is under way.
    private func runUpgradeAttempt() {
        guard var upgrade, upgrade.attempt == nil else { return }
        var pinned = context
        pinned.now = { [at = upgrade.at] in at }
        let (files, folder, caches, take, context) = (files, folder, projectCaches, project.take.id, context)
        let (progress, opened, legacy, first) = (upgrade.progress, upgrade.opened, upgrade.legacy, upgrade.first)
        upgrade.retry = nil
        upgrade.attempt = Task { [weak self] in
            let outcome = await Self.attemptUpgrade(
                progress, on: files, folder: folder, caches: caches, take: take, opened: opened, legacy: legacy,
                first: first, upgradeContext: pinned, context: context)
            self?.finishUpgradeAttempt(outcome)
        }
        self.upgrade = upgrade
    }

    /// On the queue of files: `PackageUpgrade.advance` from `progress` and, at version 3, the journal opened on the log
    /// it wrote. An error that can never be saved past refuses it (the lock let go); any other one, and a log that
    /// cannot be opened for appending yet, keeps the progress and the lock for the next attempt. If the package is not
    /// the one opened any more, it is opened again from the disk, off the main actor.
    @concurrent
    private nonisolated static func attemptUpgrade(
        _ progress: PackageUpgrade.Progress?, on queue: DispatchQueue, folder: PackageFolder, caches: ProjectCaches,
        take: String, opened: Manifest, legacy: EditDocument, first: EditStep?, upgradeContext: EditContext,
        context: EditContext
    ) async -> UpgradeOutcome {
        let part = try? await run(on: queue) { () -> UpgradeStep in
            var progress = progress
            do {
                if progress == nil {
                    let encoded = try PackageUpgrade.Encoded(
                        opened: opened, legacy: legacy, first: first, context: upgradeContext)
                    progress = PackageUpgrade.Progress(encoded: encoded)
                }
                guard var reached = progress, let path = folder.path() else { throw POSIXError(.EBADF) }
                let package = ProjectPackage(url: URL(fileURLWithPath: path, isDirectory: true))
                defer { progress = reached }
                switch try PackageUpgrade.advance(
                    &reached, package, folder: folder.descriptor, opened: opened, io: upgradeContext.upgradeIO)
                {
                case let .upgraded(lock, manifest):
                    do {
                        let journal = try EditJournal(logURL: package.editLogURL, io: context.journalIO)
                        return .done(.upgraded(lock, manifest, journal, logBytes: reached.encoded.log.count))
                    } catch {
                        // What the upgrade wrote is on disk and the lock held: the next attempt opens the log again.
                        return .done(.failed(reached, Opening.code(of: error)))
                    }
                case .lockTaken:
                    return .done(.refused(.otherAppStartedEditing))
                case .changedMeanwhile:
                    return .reopen
                }
            } catch {
                if let reason = Opening.lastingRefusal(error) {
                    progress?.lock?.release(inDirectory: folder.descriptor)
                    return .done(.refused(reason))
                }
                // Only the encoding comes before `progress`, and its errors are lasting ones.
                guard let progress else { return .done(.refused(.diskNotWritable)) }
                return .done(.failed(progress, Opening.code(of: error)))
            }
        }
        switch part ?? .done(.refused(.diskNotWritable)) {
        case let .done(outcome):
            return outcome
        case .reopen:
            do {
                return .reopened(try await Opening.reopen(folder, take: take, caches: caches, context: context))
            } catch let LoadedProjectError.unsupportedFormatVersion(version) {
                return .refused(.newerDocument(version))
            } catch {
                return .refused(.unreadable)
            }
        }
    }

    /// On the main actor, once an attempt is back:
    /// - at version 3, the session goes on as one, the steps after the first handed to the journal in order;
    /// - failed for now, every step stays in memory, `.saveFailed` tells, and the next attempt comes in
    ///   `EditJournal.retryInterval` (the session is at version 3 as far as the attempt got);
    /// - refused (another process holds the lock, or the error can never be saved past), every step is discarded and
    ///   the legacy document shown, read-only;
    /// - opened again, every step is discarded and the session is what the disk has.
    private func finishUpgradeAttempt(_ outcome: UpgradeOutcome) {
        guard var upgrade else { return }
        upgrade.attempt = nil
        switch outcome {
        case let .upgraded(lock, manifest, journal, logBytes):
            self.upgrade = nil
            self.lock = lock
            project.manifest = manifest
            legacyManifest = nil
            self.journal = journal
            listen(to: journal)
            entries = upgrade.written
            self.logBytes = logBytes
            baseSeq = upgrade.written.last?.seq ?? 0
            snapshotPolicy = SnapshotPolicy(entriesSinceSnapshot: upgrade.written.count, lastChange: .now)
            // It has its first edit: it is not a project without edits any more (design §5.9).
            notices.removeAll { $0 == .legacyLook }
            showSaveFailed(nil)
            // Each of them was encoded once already, and the journal is open: they all go.
            if upgrade.queued.isEmpty || !append(upgrade.queued, to: journal) { armIdleTimer() }
        case let .failed(progress, code):
            upgrade.progress = progress
            self.upgrade = upgrade
            lock = progress.lock
            if progress.manifestWritten { project.manifest = progress.encoded.manifest }
            if progress.logWritten {
                entries = upgrade.written
                logBytes = progress.encoded.log.count
                baseSeq = upgrade.written.last?.seq ?? 0
            }
            showSaveFailed(code)
            if !isClosed { retryUpgrade() }
        case let .refused(reason):
            self.upgrade = nil
            lock = nil
            document = upgrade.legacy
            revision += 1
            history = UndoHistory(entries: [])
            groups = [:]
            pendingCreate = nil
            legacyManifest = nil
            access = .readOnly(reason)
            notices.removeAll { if case .saveFailed = $0 { true } else { false } }
            onChange?()
        case let .reopened(opened):
            self.upgrade = nil
            adopt(opened)
            reopenings += 1
            revision += 1
            notices.append(.reopenedAfterOtherApp)
            onChange?()
        }
    }

    private func retryUpgrade() {
        upgrade?.retry = Task { [weak self] in
            try? await Task.sleep(for: EditJournal.retryInterval)
            guard !Task.isCancelled else { return }
            self?.runUpgradeAttempt()
        }
    }

    // MARK: - Snapshots

    private func armIdleTimer() {
        idleTask?.cancel()
        idleTask = Task { [weak self] in
            try? await Task.sleep(for: SnapshotPolicy.idleDelay)
            guard !Task.isCancelled else { return }
            self?.snapshotIfDue()
        }
    }

    private func snapshotIfDue() {
        guard !isClosed, !restartingLog, snapshotPolicy.isDue(now: .now) else { return }
        startSnapshot()
    }

    /// Writes the snapshot of the document as it is now, in the version it is in on disk then, once the journal confirmed
    /// every line handed to it; one at a time. It names the line the document includes (`logSequence`): when the lines
    /// of a step go to the journal, the document is still the one before them.
    private func startSnapshot() {
        guard !isClosed, !restartingLog, let journal, document.isDrawable else { return }
        guard snapshotTask == nil else {
            snapshotWanted = true
            return
        }
        let (target, version, lines) = (document, diskVersion, appendedSeqs.count)
        snapshotTask = Task { [weak self] in
            let confirmed = await journal.flushed()
            await self?.finishSnapshot(target, writtenIn: version, lines: lines, confirmed: confirmed, journal: journal)
        }
    }

    private func finishSnapshot(
        _ target: EditDocument, writtenIn version: Int, lines: Int, confirmed: Int, journal: EditJournal
    ) async {
        let seq = target.logSequence
        // Decision 20: only once every line up to `seq` is on disk; a journal that recovers brings it back (`.saved`).
        if journal === self.journal, !isClosed, confirmed >= lines, seq != snapshotSeq, await write(target, writtenIn: version) {
            snapshotSeq = seq
            snapshotPolicy.entriesSinceSnapshot = appendedSeqs.count - lines
        }
        snapshotTask = nil
        if snapshotWanted {
            snapshotWanted = false
            snapshotIfDue()
        }
    }

    /// At closing, with every line on disk: the snapshot of the last line, if `edit.json` is not that one already; in
    /// version 1 for a project of 1b not edited in this session.
    private func writeSnapshotIfBehind() async {
        let seq = lastSeq
        guard seq > 0, snapshotSeq != seq, document.isDrawable, await write(document, writtenIn: diskVersion) else { return }
        snapshotSeq = seq
    }

    private func write(_ snapshot: EditDocument, writtenIn version: Int) async -> Bool {
        let folder = folder
        return (try? await Self.run(on: files) { try Opening.writeSnapshot(snapshot, writtenIn: version, in: folder) }) != nil
    }

    /// At closing, with every line on disk and the snapshot at the last one: the compaction, through the journal, if the
    /// log is past a threshold and it makes the log shorter. Its `create` stays in `createVersion`.
    private func compactIfNeeded(_ journal: EditJournal) async {
        let (entries, createVersion) = (entries, createVersion)
        guard snapshotSeq == lastSeq,
            LogCompaction.isNeeded(
                bytes: logBytes, entries: entries.count, maxBytes: context.compaction.maxBytes,
                maxEntries: context.compaction.maxEntries),
            let shorter = try? await Self.run(on: files, { try Opening.compaction(of: entries, createVersion: createVersion) })
        else { return }
        let (compacted, lines) = shorter
        guard (try? await journal.replaceLog(with: lines)) != nil else { return }
        self.entries = compacted
        logBytes = lines.reduce(0) { $0 + $1.utf8.count + 1 }
    }

    /// Runs `body` on `queue` and waits for it without blocking the caller's thread.
    private nonisolated static func run<T: Sendable>(
        on queue: DispatchQueue, _ body: @escaping @Sendable () throws -> T
    ) async throws -> T {
        try await withCheckedThrowingContinuation { continuation in
            queue.async { continuation.resume(with: Result { try body() }) }
        }
    }
}

// MARK: - Opening

/// What `EditSession.open` hands to the session from off the main actor.
private struct Opened: Sendable {
    var project: LoadedProject
    var caches: ProjectCaches
    var folder: PackageFolder
    var url: URL
    var document: EditDocument
    var access = EditAccess.editable
    var notices: [EditNotice] = []
    var lock: HeldRecordingLock?
    var journal: EditJournal?
    var history = UndoHistory(entries: [])
    var groups: [Int: [EditChange]] = [:]
    var entries: [EditLogEntry] = []
    var logBytes = 0
    var baseSeq = 0
    var appendedSeqs: [Int] = []
    var diskVersion = EditDocument.currentVersion
    var createVersion = EditDocument.currentVersion
    var pendingCreate: EditDocument?
    var snapshotSeq: Int?
}

/// What an attempt at the upgrade to version 3 gives back to the main actor.
private enum UpgradeOutcome: Sendable {
    /// At version 3, its log (of `logBytes`) open for appending.
    case upgraded(HeldRecordingLock, Manifest, EditJournal, logBytes: Int)
    /// Not yet, for this error: how far it got, with the lock held from step 1 on, for the next attempt.
    case failed(PackageUpgrade.Progress, POSIXErrorCode)
    /// Never: the package is the legacy one (or, after step 2, what a crash before step 3 leaves), read-only.
    case refused(ReadOnlyReason)
    /// Another process changed the package: it as the disk has it now.
    case reopened(Opened)
}

/// How the part of an attempt on the queue of files ends.
private enum UpgradeStep: Sendable {
    case done(UpgradeOutcome)
    /// The package is to be opened again from the disk.
    case reopen
}

private enum Opening {
    static let logName = "edit-log.jsonl"
    static let snapshotName = "edit.json"

    /// Everything `EditSession.open` does to the files, off the main actor (`@concurrent`, so it stays off it even where
    /// `nonisolated` functions run on their caller's actor).
    @concurrent
    static func open(_ url: URL, take: String?, context: EditContext) async throws -> Opened {
        let project = try LoadedProject.load(url, take: take)
        let caches = ProjectCaches(root: context.cachesRoot, projectID: project.manifest.resolvedProjectID)
        // It can be made again: the project opens without it.
        try? FileManager.default.createDirectory(at: caches.directory, withIntermediateDirectories: true)
        let folder = try PackageFolder(url)
        let current = folder.path().map { URL(fileURLWithPath: $0, isDirectory: true) } ?? url
        return try await open(project, folder: folder, url: current, caches: caches, context: context)
    }

    /// The package `folder` is open on, its take `take`, opened anew from the disk where it is now, with the caches it
    /// had (Task 12b: another process changed it before its first edit here).
    @concurrent
    static func reopen(
        _ folder: PackageFolder, take: String, caches: ProjectCaches, context: EditContext
    ) async throws -> Opened {
        guard let path = folder.path() else { throw POSIXError(.EBADF) }
        let url = URL(fileURLWithPath: path, isDirectory: true)
        let project = try LoadedProject.load(url, take: take)
        return try await open(project, folder: folder, url: url, caches: caches, context: context)
    }

    private static func open(
        _ project: LoadedProject, folder: PackageFolder, url current: URL, caches: ProjectCaches, context: EditContext
    ) async throws -> Opened {
        var opened = Opened(project: project, caches: caches, folder: folder, url: current, document: .legacy(for: project))
        let package = project.package

        guard project.manifest.formatVersion >= 3 else {
            // Nothing is written to a version 1 or 2 package until its first edit, which upgrades it and writes the
            // `create` of this document: the lock is only asked about.
            opened.notices = [.legacyLook]
            if RecordingLock.isHeld(at: package.editLockURL) {
                opened.access = .readOnly(.openElsewhere)
            } else {
                opened.pendingCreate = opened.document
            }
            return opened
        }
        let lock: HeldRecordingLock
        do {
            // Another opener's `RecordingLock.isHeld` takes the lock for a moment: that is not another app editing.
            lock = try await RecordingLock.acquire(
                at: package.editLockURL, info: .current(now: context.now()), retries: RecordingLock.probeRetries,
                retryDelay: RecordingLock.probeRetryDelay)
        } catch let error as POSIXError {
            guard let reason = lockRefusal(error.code) else { throw error }
            return try readOnly(opened, reason, context: context)
        }
        let files: EditFiles
        do {
            files = try EditFiles.read(package)
        } catch {
            lock.release(inDirectory: folder.descriptor)
            throw error
        }
        let resolution = Resolution.of(project, files: files, context: context)
        opened.document = resolution.shown
        opened.diskVersion = resolution.diskVersion
        opened.createVersion = resolution.createVersion
        if resolution.legacyLook { opened.notices = [.legacyLook] }
        opened.baseSeq = resolution.entries.last?.seq ?? 0
        if let refusal = resolution.refusal {
            lock.release(inDirectory: folder.descriptor)
            opened.access = .readOnly(refusal)
            return opened
        }

        let journal: EditJournal
        do {
            let logURL = current.appending(path: logName)
            try prepareLog(resolution, read: files.log != nil, logURL: logURL, folder: folder, context: context)
            if let recovered = resolution.recoveredUpTo { opened.notices.append(.recovered(upTo: recovered)) }
            journal = try EditJournal(logURL: logURL, io: context.journalIO)
        } catch {
            lock.release(inDirectory: folder.descriptor)
            opened.access = .readOnly(writeRefusal(error))
            return opened
        }
        opened.lock = lock
        opened.journal = journal
        if resolution.isNewDocument {
            // Its default style's image goes into the package before the `create` that names it.
            opened.document.style.background = DefaultStyleStore.background(
                resolution.document.style.background, from: context.styleDirectory, into: ProjectPackage(url: current))
        }

        // While the document is of an older version on disk, everything written here is in that version (1c design §13.2).
        let (diskVersion, createVersion) = (resolution.diskVersion, resolution.createVersion)
        var entries = resolution.entries
        var history = UndoHistory(entries: entries, createVersion: createVersion)
        var snapshotSeq = resolution.snapshotSeq
        if resolution.startsLog {
            opened.document.logSequence = max(1, opened.document.logSequence)
            let create = EditLogEntry.create(seq: opened.document.logSequence, document: opened.document, app: context.app)
            do {
                try journal.append(try create.jsonLine(writingDocumentAt: createVersion))
            } catch {
                await journal.close()
                lock.release(inDirectory: folder.descriptor)
                opened.lock = nil
                opened.journal = nil
                opened.access = .readOnly(.unsafeEditFiles)
                return opened
            }
            history.record(create)
            entries.append(create)
            opened.appendedSeqs = [create.seq]
            // Decision 20: the snapshot only once its line is on disk.
            if await journal.flushed() == 1, snapshotSeq != create.seq,
                (try? writeSnapshot(opened.document, writtenIn: diskVersion, in: folder)) != nil
            {
                snapshotSeq = create.seq
            }
        }
        if resolution.createsLogAtFirstEdit { opened.pendingCreate = opened.document }

        var logBytes = folder.size(of: logName) ?? 0
        if !resolution.startsLog, let last = entries.last?.seq,
            LogCompaction.isNeeded(
                bytes: logBytes, entries: entries.count, maxBytes: context.compaction.maxBytes,
                maxEntries: context.compaction.maxEntries),
            let shorter = try? compaction(of: entries, createVersion: createVersion)
        {
            let (compacted, lines) = shorter
            // The snapshot first, at the last line: the compaction renumbers the lines before it.
            if snapshotSeq != last, (try? writeSnapshot(opened.document, writtenIn: diskVersion, in: folder)) != nil {
                snapshotSeq = last
            }
            if snapshotSeq == last, (try? await journal.replaceLog(with: lines)) != nil {
                entries = compacted
                history = UndoHistory(entries: compacted, createVersion: createVersion)
                logBytes = folder.size(of: logName) ?? logBytes
            }
        }
        opened.entries = entries
        opened.history = history
        opened.groups = groupChanges(of: entries, in: history)
        opened.logBytes = logBytes
        opened.snapshotSeq = snapshotSeq
        return opened
    }

    /// The project read-only, its document read without writing anything; a newer document wins over `reason`.
    private static func readOnly(_ opened: Opened, _ reason: ReadOnlyReason, context: EditContext) throws -> Opened {
        var opened = opened
        let files = try EditFiles.read(opened.project.package)
        let resolution = Resolution.of(opened.project, files: files, context: context)
        opened.document = resolution.shown
        opened.diskVersion = resolution.diskVersion
        opened.createVersion = resolution.createVersion
        if resolution.legacyLook { opened.notices = [.legacyLook] }
        opened.baseSeq = resolution.entries.last?.seq ?? 0
        if case let .newerDocument(version)? = resolution.refusal {
            opened.access = .readOnly(.newerDocument(version))
        } else {
            opened.access = .readOnly(reason)
        }
        return opened
    }

    /// Puts the log in the state the journal takes it in: a damaged one kept apart and rewritten, its `create` in the
    /// version it is written in (and an `edit.json` that is the only record but cannot be read kept apart too), or one
    /// that ends inside a line, or with a `migrate` that its first edit did not follow, truncated; then synced, so a
    /// snapshot never names a line that is not on the drive (plan decision 20).
    private static func prepareLog(
        _ resolution: Resolution, read: Bool, logURL: URL, folder: PackageFolder, context: EditContext
    ) throws {
        if resolution.keepsSnapshotApart { try folder.keepApart(snapshotName, now: context.now()) }
        guard read else { return }
        if resolution.rewritesLog {
            try folder.keepApart(logName, now: context.now())
            try DurableFile.writeAtomically(
                try lines(of: resolution.entries, createVersion: resolution.createVersion), named: logName,
                inDirectory: folder.descriptor)
        } else {
            _ = try EditLogReader.truncateIncompleteTail(logURL)
            try folder.fullSync(logName)
        }
    }

    /// Writes `edit.json`: `document` in `version`, as `DocumentMigration.reverted` gives it (the JSON the replay gives
    /// before decoding it, 1c design §13.2) when that is older than the document's. Throws `EncodingError.invalidValue`
    /// for a document that version cannot hold, and writes nothing then.
    static func writeSnapshot(_ document: EditDocument, writtenIn version: Int, in folder: PackageFolder) throws {
        let data: Data
        if version == document.documentVersion {
            data = try ProjectJSON.encoder().encode(document)
        } else if let written = DocumentMigration.reverted(try JSONValue(encoding: document), to: version) {
            data = try ProjectJSON.encoder().encode(written)
        } else {
            throw EncodingError.invalidValue(
                document, EncodingError.Context(codingPath: [], debugDescription: "The document has no version \(version)."))
        }
        try DurableFile.writeAtomically(data, named: snapshotName, inDirectory: folder.descriptor)
    }

    /// `LogCompaction.compact(entries, createVersion:)` and its lines, the `create` in `createVersion`, if it is shorter
    /// (Task 10: a compaction that drops nothing rewrites nothing).
    static func compaction(of entries: [EditLogEntry], createVersion: Int) throws -> ([EditLogEntry], [String])? {
        let compacted = LogCompaction.compact(entries, createVersion: createVersion)
        guard compacted.count < entries.count else { return nil }
        return (compacted, try compacted.map { try $0.jsonLine(writingDocumentAt: createVersion) })
    }

    /// The bytes of a log of `entries`, its `create` in `createVersion`.
    private static func lines(of entries: [EditLogEntry], createVersion: Int) throws -> Data {
        Data(try entries.map { try $0.jsonLine(writingDocumentAt: createVersion) + "\n" }.joined().utf8)
    }

    /// The changes of the `do` lines of each group still in the stacks: of a log the replay applied, every `do` of a group
    /// comes while it is applied, so all of them are what its undo inverts.
    private static func groupChanges(of entries: [EditLogEntry], in history: UndoHistory) -> [Int: [EditChange]] {
        let live = Set(history.done + history.undone)
        var groups: [Int: [EditChange]] = [:]
        for case let .do(_, group, _, changes, _) in entries where live.contains(group) {
            groups[group, default: []] += changes
        }
        return groups
    }

    /// Why `edit.lock` could not be taken, if it is a reason to open read-only.
    private static func lockRefusal(_ code: POSIXErrorCode) -> ReadOnlyReason? {
        switch code {
        case .EAGAIN: .openElsewhere
        // A volume without `flock` (SMB, exFAT, FAT) says `ENOTSUP` or `EOPNOTSUPP`.
        case .EROFS, .EACCES, .EPERM, .ENOTSUP, .EOPNOTSUPP, .ENOSPC, .EDQUOT: .diskNotWritable
        case .ELOOP, .EFTYPE, .EISDIR, .ENXIO: .unsafeEditFiles
        default: nil
        }
    }

    /// The reason to stay read-only for an error that writing again can never get past: a volume or folder that cannot
    /// be written (`EROFS`, `EACCES`, `EPERM`, no `flock`), a file that is not one this can write safely, or one that is
    /// not of the disk (the encoding). `nil` for any other (`ENOSPC`, `EDQUOT`, `EIO`, `EMFILE`…): it is tried again.
    static func lastingRefusal(_ error: any Error) -> ReadOnlyReason? {
        guard let code = (error as? POSIXError)?.code else { return .diskNotWritable }
        switch code {
        case .EROFS, .EACCES, .EPERM, .ENOTSUP, .EOPNOTSUPP, .EINVAL: return .diskNotWritable
        case .ELOOP, .EFTYPE, .EISDIR, .ENXIO, .ENOTDIR: return .unsafeEditFiles
        default: return nil
        }
    }

    static func code(of error: any Error) -> POSIXErrorCode {
        (error as? POSIXError)?.code ?? .EIO
    }

    static func writeRefusal(_ error: any Error) -> ReadOnlyReason {
        let code = (error as? POSIXError)?.code
        return code.map { [.ELOOP, .EFTYPE, .EISDIR, .ENXIO, .ENOTDIR].contains($0) } == true ? .unsafeEditFiles : .diskNotWritable
    }
}

// MARK: - Reading the edit files

/// What `edit.json` and `edit-log.jsonl` hold, read with `SafeRead.regularFile(at:)`: never through a symlink, never
/// blocked on a FIFO.
private struct EditFiles: Sendable {
    /// A document is read migrated, with the `documentVersion` it is written in.
    enum Snapshot: Sendable {
        case missing
        case document(EditDocument, modified: Date, version: Int)
        /// It decodes, but no render could draw it (`isDrawable`).
        case undrawable(EditDocument, version: Int)
        /// It cannot be read or decoded.
        case unreadable

        var isMissing: Bool {
            if case .missing = self { true } else { false }
        }
    }

    var snapshot = Snapshot.missing
    /// `nil` without `edit-log.jsonl`.
    var log: EditLogRead?
    /// When `edit-log.jsonl` was created.
    var logCreated: Date?
    /// A document, or a `migrate` to one, of a `documentVersion` newer than this app's.
    var newerVersion: Int?
    /// The error of an edit file that is a symlink or not a regular file; it is read as missing.
    var unsafe: POSIXErrorCode?

    /// Throws only for a log that cannot be read for another reason (`EACCES`, `EIO`).
    static func read(_ package: ProjectPackage) throws -> EditFiles {
        var files = EditFiles()
        do {
            files.log = try EditLogReader.read(package.editLogURL)
            files.logCreated = dates(of: package.editLogURL)?.created
        } catch let EditDocumentError.newerVersion(version) {
            files.newerVersion = version
        } catch let error as POSIXError where error.code == .ENOENT {
        } catch let error as POSIXError where isUnsafe(error.code) {
            files.unsafe = error.code
        }
        do {
            let data = try SafeRead.regularFile(at: package.editURL)
            do {
                let document = try EditDocument.decode(data)
                let version = EditDocument.writtenVersion(of: data) ?? EditDocument.currentVersion
                files.snapshot = document.isDrawable
                    ? .document(document, modified: dates(of: package.editURL)?.modified ?? .distantPast, version: version)
                    : .undrawable(document, version: version)
            } catch let EditDocumentError.newerVersion(version) {
                files.newerVersion = max(files.newerVersion ?? version, version)
            } catch {
                files.snapshot = .unreadable
            }
        } catch let error as POSIXError where error.code == .ENOENT {
        } catch let error as POSIXError where isUnsafe(error.code) {
            files.unsafe = files.unsafe ?? error.code
        } catch {
            files.snapshot = .unreadable
        }
        return files
    }

    private static func isUnsafe(_ code: POSIXErrorCode) -> Bool {
        [.ELOOP, .EFTYPE, .ENXIO, .EOPNOTSUPP].contains(code)
    }

    private static func dates(of url: URL) -> (created: Date, modified: Date)? {
        var info = stat()
        guard lstat(url.path, &info) == 0 else { return nil }
        func date(_ time: timespec) -> Date { Date(timeIntervalSince1970: Double(time.tv_sec) + Double(time.tv_nsec) / 1e9) }
        return (date(info.st_birthtimespec), date(info.st_mtimespec))
    }
}

/// What the edit files say the document is (design §6.5, plan decision 5), before anything is written: what `open`
/// shows and `readDocument` returns.
private struct Resolution: Sendable {
    var document: EditDocument
    /// The lines the log keeps: only those the replay applied.
    var entries: [EditLogEntry] = []
    /// The log file is kept apart and rewritten as `entries`.
    var rewritesLog = false
    /// `edit.json` cannot be read and nothing else holds the edit: it is kept apart before anything replaces it.
    var keepsSnapshotApart = false
    /// The log starts with a `create` of `document` (at its `logSequence`, at least 1), written at opening.
    var startsLog = false
    /// `document` is the legacy one: the first edit writes its `create`.
    var createsLogAtFirstEdit = false
    /// `document` is a `NewDocument`, which `startsLog` writes.
    var isNewDocument = false
    var recoveredUpTo: Date?
    var legacyLook = false
    /// The `logSequence` of `edit.json`, when it names a line the log keeps.
    var snapshotSeq: Int?
    var refusal: ReadOnlyReason?
    /// The `documentVersion` `document` is written in on disk (1c design §13.2): the replay's (`EditReplay.version`), the
    /// snapshot's it starts from, or the current one for a legacy or new document.
    var diskVersion = EditDocument.currentVersion
    /// The `documentVersion` of the `create` of the log the session keeps: that of `entries` (`EditLogRead.createVersion`),
    /// or `diskVersion` for a log that starts with a `create` of `document`.
    var createVersion = EditDocument.currentVersion

    /// The resolution for `project`, loaded with its events.
    static func of(_ project: LoadedProject, files: EditFiles, context: EditContext) -> Resolution {
        of(project, files: files, context: context) { $0 }
    }

    /// The resolution for `project`, whose events may not be read yet: they are asked for (`withEvents`, which gives
    /// `project` with its events read and throws what reading them throws) only for a document that comes from them, the
    /// legacy one or a `NewDocument`. A document from the edit files never needs them.
    static func of(
        _ project: LoadedProject, files: EditFiles, context: EditContext,
        withEvents: (LoadedProject) throws -> LoadedProject
    ) rethrows -> Resolution {
        if let version = files.newerVersion {
            // Nothing to show: the app shows no preview.
            return Resolution(document: .legacy(for: try withEvents(project)), refusal: .newerDocument(version))
        }
        var snapshot: (document: EditDocument, modified: Date, version: Int)?
        if case let .document(document, modified, version) = files.snapshot { snapshot = (document, modified, version) }
        var resolution: Resolution
        if let log = files.log, case .create? = log.entries.first,
            case let (replay, good)? = replayed(log, snapshot: snapshot.map { ($0.document, $0.version) })
        {
            if let snapshot, snapshot.document.logSequence > replay.lastAppliedSeq {
                // Plan decision 5: `edit.json` is newer than every line that can be applied (the damage is before it,
                // or the log lost lines it holds). It opens, and the log starts again with a `create` of it.
                resolution = .starting(from: snapshot.document, writtenIn: snapshot.version)
                resolution.rewritesLog = true
                resolution.recoveredUpTo = snapshot.modified
            } else {
                resolution = Resolution(
                    document: replay.document, entries: good, diskVersion: replay.version,
                    createVersion: log.createVersion ?? EditDocument.currentVersion)
                if let snapshot, good.contains(where: { $0.seq == snapshot.document.logSequence }) {
                    resolution.snapshotSeq = snapshot.document.logSequence
                }
                if log.damagedLine != nil || replay.mismatchSeq != nil {
                    resolution.rewritesLog = true
                    resolution.recoveredUpTo = lastDoDate(in: good) ?? files.logCreated ?? context.now()
                }
            }
        } else {
            // No line to start from: no log, an empty one, one cut short or damaged in its first line.
            let damaged = files.log?.damagedLine != nil
            if let snapshot {
                resolution = .starting(from: snapshot.document, writtenIn: snapshot.version)
                if damaged { resolution.recoveredUpTo = snapshot.modified }
            } else if case let .undrawable(document, version) = files.snapshot {
                resolution = Resolution(document: document, diskVersion: version, createVersion: version)
            } else if project.manifest.upgradedFrom != nil {
                resolution = Resolution(
                    document: .legacy(for: try withEvents(project)), createsLogAtFirstEdit: true, legacyLook: true)
            } else {
                resolution = Resolution(
                    document: NewDocument.make(
                        project: try withEvents(project), defaultStyle: context.defaultStyle, makeID: context.makeID,
                        cameraLook: context.cameraLook),
                    startsLog: true, isNewDocument: true)
            }
            if damaged {
                resolution.rewritesLog = true
                resolution.recoveredUpTo = resolution.recoveredUpTo ?? files.logCreated ?? context.now()
            }
            if case .unreadable = files.snapshot { resolution.keepsSnapshotApart = true }
        }
        if files.unsafe != nil { resolution.refusal = .unsafeEditFiles }
        if !resolution.document.isDrawable {
            // Task 5: a document edited by hand never reaches a render it would stop; it is only shown.
            resolution.document = resolution.document.drawable
            resolution.refusal = resolution.refusal ?? .unsafeEditFiles
        }
        return resolution
    }

    /// `document` as it is shown before anything is written: a new document never with the image of its default style,
    /// which only an editable opening copies into the package.
    var shown: EditDocument {
        guard isNewDocument else { return document }
        var shown = document
        shown.style.background = DefaultStyleStore.unsavedBackground(document.style.background)
        return shown
    }

    /// `snapshot`, written in `version`, with a log that starts with a `create` of it in that version.
    private static func starting(from snapshot: EditDocument, writtenIn version: Int) -> Resolution {
        Resolution(
            document: snapshot, startsLog: true, snapshotSeq: snapshot.logSequence >= 1 ? snapshot.logSequence : nil,
            diskVersion: version, createVersion: version)
    }

    /// The replay of `log`, from `snapshot` (in the version it is written in) or from its `create`, and the lines it
    /// applied, which the log keeps (Task 10: the history comes only from those). They never end with a `migrate`: like
    /// the reader (1c plan decision 6), a replay that stops right after one stops before it, as if the first edit that
    /// wrote it had not come, so a repaired log never ends with one either. `nil` if there is nothing to start from.
    private static func replayed(
        _ log: EditLogRead, snapshot: (document: EditDocument, version: Int)?
    ) -> (replay: EditReplay, good: [EditLogEntry])? {
        var entries = log.entries
        // Where the first replay stopped: the log is repaired up to the good lines.
        var mismatch: Int?
        while var replay = EditReplay.replay(
            snapshot: snapshot?.document, snapshotVersion: snapshot?.version ?? EditDocument.currentVersion, entries: entries,
            createVersion: log.createVersion ?? EditDocument.currentVersion)
        {
            var good = Array(entries.prefix { $0.seq <= replay.lastAppliedSeq })
            guard case .migrate? = good.last else {
                replay.mismatchSeq = replay.mismatchSeq ?? mismatch
                return (replay, good)
            }
            mismatch = mismatch ?? replay.mismatchSeq
            while case .migrate? = good.last { good.removeLast() }
            entries = good
        }
        return nil
    }

    /// The `at` of the last `do` of `entries`: the edit is recovered up to then.
    private static func lastDoDate(in entries: [EditLogEntry]) -> Date? {
        for case let .do(_, _, _, _, at) in entries.reversed() { return at }
        return nil
    }
}

// MARK: - The package folder

/// The package's folder, open with `O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC`: the session writes relative to
/// it, so a package that is renamed or moved while open still gets its files. Only the session's file queue writes
/// through it and closes it, so no write races the closing.
private final class PackageFolder: Sendable {
    private let fd: Mutex<Int32>

    init(_ url: URL) throws {
        let fd = Darwin.open(url.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else { throw posixError() }
        self.fd = Mutex(fd)
    }

    deinit {
        close()
    }

    /// The descriptor; -1 once closed, which every call refuses with `EBADF`.
    var descriptor: Int32 { fd.withLock { $0 } }

    func close() {
        fd.withLock { fd in
            if fd >= 0 { Darwin.close(fd) }
            fd = -1
        }
    }

    /// Where the folder is now (`F_GETPATH`); `nil` once closed or if the system cannot tell.
    func path() -> String? {
        fd.withLock { fd in
            guard fd >= 0 else { return nil }
            var buffer = [CChar](repeating: 0, count: Int(MAXPATHLEN))
            return buffer.withUnsafeMutableBufferPointer { buffer in
                guard let base = buffer.baseAddress, fcntl(fd, F_GETPATH, base) != -1 else { return nil }
                return String(cString: base)
            }
        }
    }

    /// The size of the regular file `name`; `nil` if there is none.
    func size(of name: String) -> Int? {
        var info = stat()
        guard fstatat(descriptor, name, &info, AT_SYMLINK_NOFOLLOW) == 0, info.st_mode & S_IFMT == S_IFREG else { return nil }
        return Int(info.st_size)
    }

    /// `F_FULLFSYNC` (or `fsync`) of the regular file `name`.
    func fullSync(_ name: String) throws {
        let file = try openRegular(name)
        defer { Darwin.close(file) }
        try DurableFile.fullSync(file)
    }

    /// Copies the whole regular file `name` to `<name>.damaged-<yyyyMMdd-HHmmss>` (with `-2`, `-3`… after it while that
    /// name is taken), full-synced with the folder. Never replaces nor removes anything.
    func keepApart(_ name: String, now: Date) throws {
        let source = try openRegular(name)
        defer { Darwin.close(source) }
        let bytes = try Self.readAll(source)
        let (copy, copyName) = try createFree(name, now: now) { openat(descriptor, $0, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o644) }
        do {
            try Self.writeAll(bytes, to: copy)
            try DurableFile.fullSync(copy)
        } catch {
            Darwin.close(copy)
            unlinkat(descriptor, copyName, 0)
            throw error
        }
        Darwin.close(copy)
        try DurableFile.fullSync(descriptor)
    }

    /// Renames whatever is at `name` (a file that is not the one written there) to a free
    /// `<name>.damaged-<yyyyMMdd-HHmmss>` name, without replacing anything; nothing if there is nothing at `name`.
    func moveAside(_ name: String, now: Date) throws {
        var info = stat()
        guard fstatat(descriptor, name, &info, AT_SYMLINK_NOFOLLOW) == 0 else {
            guard errno == ENOENT else { throw posixError() }
            return
        }
        _ = try createFree(name, now: now) { free in
            renameatx_np(descriptor, name, descriptor, free, UInt32(RENAME_EXCL)) == 0 ? 0 : -1
        }
    }

    /// `make` with free names of the form `<name>.damaged-<stamp>`, `-2`, `-3`…, until it does not fail with `EEXIST`:
    /// its result and the name.
    private func createFree(_ name: String, now: Date, _ make: (String) -> Int32) throws -> (Int32, String) {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        let stem = name + ".damaged-" + formatter.string(from: now)
        for attempt in 1...1000 {
            let candidate = attempt == 1 ? stem : stem + "-\(attempt)"
            let result = make(candidate)
            if result >= 0 { return (result, candidate) }
            guard errno == EEXIST else { throw posixError() }
        }
        throw POSIXError(.EEXIST)
    }

    /// Opens the regular file `name` for reading, never through a symlink and never blocking on a FIFO.
    private func openRegular(_ name: String) throws -> Int32 {
        let file = openat(descriptor, name, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        guard file >= 0 else { throw posixError() }
        var info = stat()
        guard fstat(file, &info) == 0, info.st_mode & S_IFMT == S_IFREG else {
            let error = info.st_mode & S_IFMT == S_IFREG ? posixError() : POSIXError(.EFTYPE)
            Darwin.close(file)
            throw error
        }
        return file
    }

    private static func readAll(_ file: Int32) throws -> [UInt8] {
        var bytes: [UInt8] = []
        var buffer = [UInt8](repeating: 0, count: 64 * 1024)
        while true {
            let count = buffer.withUnsafeMutableBytes { Darwin.read(file, $0.baseAddress, $0.count) }
            if count < 0 {
                if errno == EINTR { continue }
                throw posixError()
            }
            if count == 0 { return bytes }
            bytes += buffer[..<count]
        }
    }

    private static func writeAll(_ bytes: [UInt8], to file: Int32) throws {
        var written = 0
        try bytes.withUnsafeBytes { buffer in
            while written < buffer.count {
                let count = Darwin.write(file, buffer.baseAddress! + written, buffer.count - written)
                if count < 0 {
                    if errno == EINTR { continue }
                    throw posixError()
                }
                written += count
            }
        }
    }
}

private func posixError() -> POSIXError {
    POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
}

// MARK: - What a render can draw

extension EditDocument {
    /// Whether every value the render reads as a number of frames or a rate is one the design allows: a frame rate of
    /// `EditDocument.frameRates` and clip speeds in `ClipSpeed.range` (Task 5: an absurd frame rate stops
    /// `TimeMap.frameCount`).
    fileprivate var isDrawable: Bool {
        Self.frameRates.contains(frameRate) && sequence.allSatisfy { ClipSpeed.range.contains($0.speed) }
    }

    /// This document with its frame rate the nearest allowed one and its speeds as `TimeMap` reads them
    /// (`ClipSpeed.clamped`).
    fileprivate var drawable: EditDocument {
        var document = self
        if !Self.frameRates.contains(frameRate) {
            let rate = min(max(frameRate, 0), 1_000)
            document.frameRate = Self.frameRates.min { abs($0 - rate) < abs($1 - rate) } ?? 60
        }
        for index in document.sequence.indices {
            document.sequence[index].speed = ClipSpeed.clamped(document.sequence[index].speed)
        }
        return document
    }
}
