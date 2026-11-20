// SPDX-License-Identifier: GPL-3.0-or-later
import ArgumentParser
import Darwin
import Editing
import Foundation
import ProjectFormat
import Synchronization

// MARK: - edit-stress

struct EditStress: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "edit-stress",
        abstract: "Edits a package at random until it is killed, printing what is saved after each step. For the crash test.",
        discussion: """
            Opens the package's last take in an edit session (EditSession.open) and repeats random steps: a set of \
            the padding, the corner radius or the shadow, the insertion or the removal of a zoom block, an undo (one \
            step in ten, when there is something to undo) or a redo. After each one it waits for the session to save \
            it (EditSession.flushed()) and prints "confirmed <seq>": the seq of the last line of edit-log.jsonl on \
            the disk, as the session reports it. Steps come one after another, so those on one value less than 1 s \
            apart join one undo group. It never stops by itself: it runs until it is killed, or until its parent \
            process goes away. It exits 1 if the project opens read-only or with a damaged log, or if a step is \
            refused.

            With --compact-every <k>, the log is compacted when it has more than k lines (never for its size), and \
            the session is closed and opened again every 60 steps, so that the compaction at closing and at opening \
            happens while it runs.

            With --kill-in-upgrade, the package must be of version 1 or 2: the first step starts its upgrade to \
            version 3 (design §6.1), and edit-stress kills itself with SIGKILL right after the step of the upgrade \
            it names: after-lock (edit.lock taken and the manifest read again, nothing written), after-manifest (the \
            manifest rewritten at version 3) or after-log (the log written with the create and the first step). It \
            exits 1 if the upgrade ends without getting there.

            With --kill-in-compaction, which needs --compact-every, edit-stress kills itself with SIGKILL in the first \
            compaction of the log (the swap of EditJournal.replaceLog), right after the step it names: after-snapshot \
            (the snapshot at the log's last seq written, before the new log is), after-temporary (the new log written \
            and synced next to the old one, before the rename) or after-rename (renamed over the old log, before the \
            folder is synced).
            """
    )

    @Argument(help: "The .toma package.")
    var package: String

    @Option(help: "Seed of the random choices.")
    var seed: UInt64

    @Option(help: "Compact the log when it has more than this many lines, and close and open the session every 60 steps.")
    var compactEvery: Int?

    @Option(help: "Kill this process with SIGKILL in the upgrade to version 3: after-lock, after-manifest or after-log.")
    var killInUpgrade: UpgradeKillPoint?

    @Option(help: "Kill this process with SIGKILL in the first compaction: after-snapshot, after-temporary or after-rename.")
    var killInCompaction: CompactionKillPoint?

    @Option(help: "Folder for the project's cache folder. A folder in the temporary directory when omitted.")
    var caches: String?

    func validate() throws {
        if let compactEvery, compactEvery < 1 { throw ValidationError("--compact-every must be positive.") }
        if compactEvery != nil, killInUpgrade != nil {
            throw ValidationError("--kill-in-upgrade ends with the first step: leave out --compact-every.")
        }
        if killInCompaction != nil, compactEvery == nil {
            throw ValidationError("--kill-in-compaction needs --compact-every: without it the log is never compacted.")
        }
    }

    func run() async throws {
        let url = URL(fileURLWithPath: package, isDirectory: true)
        let cachesRoot = caches.map { URL(fileURLWithPath: $0, isDirectory: true) }
            ?? FileManager.default.temporaryDirectory.appending(path: "recorder-dev-caches", directoryHint: .isDirectory)
        let compaction: (maxBytes: Int, maxEntries: Int) = compactEvery.map { (maxBytes: Int.max, maxEntries: $0) }
            ?? (maxBytes: LogCompaction.maxBytes, maxEntries: LogCompaction.maxEntries)
        let context = EditContext(
            app: editingApp, cachesRoot: cachesRoot, defaultStyle: .toma, now: { Date() },
            makeID: { prefix in prefix + String(format: "%08x", UInt32.random(in: .min ... .max)) }, compaction: compaction,
            journalIO: killInCompaction.map { journalIO(killing: $0, log: ProjectPackage(url: url).editLogURL.lastPathComponent) }
                ?? .system,
            upgradeIO: killInUpgrade.map { upgradeIO(killing: $0, in: ProjectPackage(url: url)) } ?? .system)
        let stress = await StressRun(
            url: url, context: context, reopenEvery: compactEvery == nil ? nil : 60, killPoint: killInUpgrade,
            random: SeededGenerator(seed: seed))
        try await stress.run()
    }
}

/// Where `edit-stress --kill-in-upgrade` kills itself in the upgrade of a version 1 or 2 package to version 3.
enum UpgradeKillPoint: String, CaseIterable, ExpressibleByArgument, Sendable {
    /// Step 1 done: `edit.lock` taken and the manifest read again; nothing written.
    case afterLock = "after-lock"
    /// Step 2 done: the manifest at version 3, no log.
    case afterManifest = "after-manifest"
    /// Step 3 done: the log written with the `create` and the first step, before the journal opens it.
    case afterLog = "after-log"
}

/// Where `edit-stress --kill-in-compaction` kills itself in the first compaction of the log: the swap of
/// `EditJournal.replaceLog`, which writes the new log to `<log>.tmp`, full-syncs it, renames it over the log and syncs
/// the folder, after the snapshot at the log's last seq.
enum CompactionKillPoint: String, CaseIterable, ExpressibleByArgument, Sendable {
    /// The snapshot written, the new log not yet: at the first write to the temporary file.
    case afterSnapshot = "after-snapshot"
    /// The new log written and full-synced next to the old one, before the rename.
    case afterTemporary = "after-temporary"
    /// The new log renamed over the old one, before the folder is synced.
    case afterRename = "after-rename"
}

/// The calls of `EditJournalIO.system`, with a SIGKILL of this process at `point` of the first swap of the log named
/// `log`: the swap's calls are those on the descriptor of `<log>.tmp`, and the folder sync right after its full sync.
private func journalIO(killing point: CompactionKillPoint, log: String) -> EditJournalIO {
    let temporary = log + ".tmp"
    // Whether the temporary file was full-synced: the next folder sync follows its rename.
    let synced = Mutex(false)
    @Sendable func isTemporary(_ descriptor: Int32) -> Bool {
        var path = [CChar](repeating: 0, count: Int(MAXPATHLEN))
        guard fcntl(descriptor, F_GETPATH, &path) != -1 else { return false }
        return String(decoding: path.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self).hasSuffix("/" + temporary)
    }
    let system = EditJournalIO.system
    return EditJournalIO(
        open: system.open,
        write: { descriptor, bytes in
            if point == .afterSnapshot, isTemporary(descriptor) { killThisProcess() }
            return try system.write(descriptor, bytes)
        },
        fullSync: { descriptor in
            try system.fullSync(descriptor)
            guard isTemporary(descriptor) else { return }
            if point == .afterTemporary { killThisProcess() }
            synced.withLock { $0 = true }
        },
        fsync: { descriptor in
            try system.fsync(descriptor)
            guard isTemporary(descriptor) else { return }
            if point == .afterTemporary { killThisProcess() }
            synced.withLock { $0 = true }
        },
        syncDirectory: { directory in
            if point == .afterRename, synced.withLock({ $0 }) { killThisProcess() }
            try system.syncDirectory(directory)
        })
}

/// The app the `create` lines of `edit-stress` name, as `synth-record` names it in the manifest.
private let editingApp = AppInfo(name: "recorder-dev", version: "dev")

/// The writes of `PackageUpgradeIO.system`, with a SIGKILL of this process around the one of `point`.
private func upgradeIO(killing point: UpgradeKillPoint, in package: ProjectPackage) -> PackageUpgradeIO {
    let manifest = package.manifestURL.lastPathComponent
    let log = package.editLogURL.lastPathComponent
    return PackageUpgradeIO(
        write: { data, name, directory in
            if point == .afterLock, name == manifest { killThisProcess() }
            try PackageUpgradeIO.system.write(data, name, directory)
            if point == .afterManifest && name == manifest || point == .afterLog && name == log { killThisProcess() }
        },
        pause: PackageUpgradeIO.system.pause)
}

/// The crash test's `kill -9`, at an exact point.
private func killThisProcess() -> Never {
    kill(getpid(), SIGKILL)
    while true { pause() }
}

/// The steps of one `edit-stress`, on the main actor with its session.
@MainActor
private final class StressRun {
    private let url: URL
    private let context: EditContext
    private let reopenEvery: Int?
    private let killPoint: UpgradeKillPoint?
    private var random: SeededGenerator

    init(url: URL, context: EditContext, reopenEvery: Int?, killPoint: UpgradeKillPoint?, random: SeededGenerator) {
        self.url = url
        self.context = context
        self.reopenEvery = reopenEvery
        self.killPoint = killPoint
        self.random = random
    }

    private enum Choice {
        case perform(EditStep)
        case undo, redo
    }

    func run() async throws {
        var session = try await open()
        if let killPoint, session.project.manifest.formatVersion >= 3 {
            await session.close()
            printError("error: --kill-in-upgrade \(killPoint.rawValue) needs a package of version 1 or 2")
            throw ExitCode.failure
        }
        var steps = 0
        // An orphan (the script that started it is gone) stops: nothing would ever kill it.
        while getppid() != 1 {
            let outcome = switch choice(in: session.document, undo: session.undoLabel != nil, redo: session.redoLabel != nil) {
            case let .perform(step): session.perform(step)
            case .undo: session.undo()
            case .redo: session.redo()
            }
            guard outcome != .refused else {
                await session.close()
                printError("error: step \(steps + 1) was refused (\(describe(session)))")
                throw ExitCode.failure
            }
            let seq = await session.flushed()
            if let killPoint {
                printError("error: the upgrade ended before \(killPoint.rawValue) (\(describe(session)))")
                throw ExitCode.failure
            }
            print("confirmed \(seq)")
            fflush(stdout)
            steps += 1
            if let reopenEvery, steps.isMultiple(of: reopenEvery) {
                await session.close()
                session = try await open()
            }
        }
        await session.close()
    }

    /// The session, editable, or a failure.
    private func open() async throws -> EditSession {
        let session = try await EditSession.open(url, take: nil, context: context)
        let recovered = session.notices.contains { if case .recovered = $0 { true } else { false } }
        guard session.access == .editable, !recovered else {
            await session.close()
            printError("error: the project opened with \(describe(session))")
            throw ExitCode.failure
        }
        return session
    }

    /// What the session can do and tells, for an error.
    private func describe(_ session: EditSession) -> String {
        "access \(session.access), notices \(session.notices)"
    }

    /// The next step: an undo one time in ten and a redo one in twenty, when there is one; a zoom block inserted or
    /// removed one time in four; otherwise a set of the padding, the corner radius or the shadow.
    private func choice(in document: EditDocument, undo: Bool, redo: Bool) -> Choice {
        let roll = Int.random(in: 0..<100, using: &random)
        if roll < 10, undo { return .undo }
        if roll < 15, redo { return .redo }
        if roll < 40, let step = zoomStep(document) { return .perform(step) }
        return .perform(styleStep(document))
    }

    /// A new value of the padding (0 to 0.2), the corner radius (0 to 0.05) or the shadow (0 to 1).
    private func styleStep(_ document: EditDocument) -> EditStep {
        let (path, label, steps, unit) = [
            ("/style/padding", EditLabel.padding, 200, 1_000.0),
            ("/style/cornerRadius", .cornerRadius, 50, 1_000.0),
            ("/style/shadow", .shadow, 100, 100.0),
        ].randomElement(using: &random)!
        while true {
            if let change = document.setChange(path, Double(Int.random(in: 0...steps, using: &random)) / unit) {
                return EditStep(label: label, target: path, changes: [change])
            }
        }
    }

    /// The removal of one of the document's zoom blocks (always with 12 or more, half the time otherwise), or the
    /// insertion of a new one, of 0.3 to 1.2 s within a clip, in order of its start; `nil` if there is no clip to put
    /// it in.
    private func zoomStep(_ document: EditDocument) -> EditStep? {
        let regions = document.zoom.regions
        if !regions.isEmpty, regions.count >= 12 || Bool.random(using: &random) {
            let index = Int.random(in: regions.indices, using: &random)
            guard let change = document.removeChange(.zoomRegions, at: index) else { return nil }
            return EditStep(label: .zoomDelete, target: regions[index].id, changes: [change])
        }
        guard let clip = document.sequence.randomElement(using: &random), clip.end > clip.start else { return nil }
        let span = clip.end.nanoseconds - clip.start.nanoseconds
        let length = min(span, UInt64.random(in: 300_000_000...1_200_000_000, using: &random))
        let start = clip.start.nanoseconds + UInt64.random(in: 0...(span - length), using: &random)
        var id: String
        repeat {
            id = "z-" + String(format: "%08x", UInt32.random(in: .min ... .max, using: &random))
        } while regions.contains(where: { $0.id == id })
        let focus: ZoomFocus = Bool.random(using: &random) ? .follow : .fixed(x: hundredths(), y: hundredths())
        let region = ZoomRegion(
            id: id, take: clip.take, start: HostTime(nanoseconds: start), end: HostTime(nanoseconds: start + length),
            origin: .user, depth: Double(Int.random(in: 6...12, using: &random)) / 4, focus: focus,
            instant: Int.random(in: 0..<4, using: &random) == 0)
        let index = regions.firstIndex { $0.start > region.start } ?? regions.count
        return EditStep(label: .zoomAdd, target: id, changes: [document.insertChange(.zoomRegions, at: index, region)])
    }

    /// A number of hundredths from 0 to 1, at random.
    private func hundredths() -> Double {
        Double(Int.random(in: 0...100, using: &random)) / 100
    }
}

/// SplitMix64: random numbers that only depend on the seed.
private struct SeededGenerator: RandomNumberGenerator {
    private var state: UInt64

    init(seed: UInt64) {
        state = seed
    }

    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}

// MARK: - edit-check

struct EditCheck: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "edit-check",
        abstract: "Checks that a package's edit holds every step reported saved and opens. Writes nothing.",
        discussion: """
            Never opens an edit session (EditSession.open) and never writes: it reads the package as \
            EditSession.readDocument does, and the log with EditLogReader.read, then replays the log (EditReplay) \
            and undoes its undo stack (UndoHistory) in memory. Prints "OK: …" and exits 0 when all of this holds; \
            otherwise prints "FAIL: …" with the first that does not, and exits 1:
            - the project loads and readDocument reads its document;
            - edit-log.jsonl reaches at least the seq --confirmed (it is 0 without the log): every step reported \
            saved is in it;
            - every line of the log is whole but perhaps a last one cut short, it replays to its last line, and no \
            damaged file was kept apart (a name with ".damaged-");
            - a version 1 or 2 package has neither edit.json nor edit-log.jsonl, and one of version 3 has no \
            edit.json without a line of the log;
            - the document the project opens with is the log's replay from its create (the snapshot agrees with \
            the log) or, without a line, the document the project starts with;
            - undoing every group of the undo stack, one undo for each, gives back the create's document, which is \
            the document the project started with: the legacy one if it is or was of version 1 or 2, otherwise a \
            new one (NewDocument with the toma style, the ids of its clips aside, which are random).
            """
    )

    @Argument(help: "The .toma package.")
    var package: String

    @Option(help: "The seq of the last step reported saved: the log must reach it (0 if none was).")
    var confirmed: Int

    @Flag(help: "The project is a saved Replay: its create is ReplayDocument's (the sequence cut at the Replay's start), so it is not compared with NewDocument's.")
    var replay = false

    func run() throws {
        let url = URL(fileURLWithPath: package, isDirectory: true)
        let context = EditContext(
            app: editingApp, cachesRoot: FileManager.default.temporaryDirectory, defaultStyle: .toma, now: { Date() },
            makeID: { prefix in prefix + String(format: "%08x", UInt32.random(in: .min ... .max)) })
        let opened: (project: LoadedProject, document: EditDocument)
        do {
            opened = try EditSession.readDocument(url, take: nil, context: context)
        } catch {
            throw failure("the project does not open: \(error)")
        }
        let (project, document) = opened
        let package = project.package
        let manifest = project.manifest
        let damaged = (try? FileManager.default.contentsOfDirectory(atPath: url.path))?.filter { $0.contains(".damaged-") } ?? []
        guard damaged.isEmpty else { throw failure("damaged files were kept apart: \(damaged.sorted().joined(separator: ", "))") }
        let log: EditLogRead?
        do {
            log = try EditLogReader.read(package.editLogURL)
        } catch let error as POSIXError where error.code == .ENOENT {
            log = nil
        } catch {
            throw failure("edit-log.jsonl cannot be read: \(error)")
        }
        if manifest.formatVersion < 3, log != nil || exists(package.editURL) {
            throw failure("a package of version \(manifest.formatVersion) has edit files")
        }
        if let line = log?.damagedLine { throw failure("line \(line) of edit-log.jsonl (from 0) is damaged") }
        let entries = log?.entries ?? []
        let seq = entries.last?.seq ?? 0
        guard seq >= confirmed else {
            throw failure("edit-log.jsonl ends at seq \(seq), but seq \(confirmed) was reported saved")
        }

        let legacy = manifest.formatVersion < 3 || manifest.upgradedFrom != nil
        let kind = legacy ? "legacy" : "new"
        let initial = legacy
            ? EditDocument.legacy(for: project) : NewDocument.make(project: project, defaultStyle: .toma, makeID: { $0 })
        func isInitial(_ document: EditDocument) -> Bool {
            state(document, keepingClipIDs: legacy) == state(initial, keepingClipIDs: legacy)
        }
        let version = "version \(manifest.formatVersion)" + (manifest.upgradedFrom.map { " (upgraded from \($0))" } ?? "")

        guard case let .create(_, created, _)? = entries.first else {
            if exists(package.editURL) { throw failure("edit.json is there without a line of edit-log.jsonl") }
            guard isInitial(document) else {
                throw failure("without a line of edit-log.jsonl, the project does not open with the \(kind) document")
            }
            print("OK: \(version), no line in edit-log.jsonl, the \(kind) document")
            return
        }
        guard replay || isInitial(created) else { throw failure("the create of edit-log.jsonl is not the \(kind) document") }
        // A new document's `create` is in the oldest version that holds it (2), and the first edit migrates it.
        let createVersion = log?.createVersion ?? EditDocument.currentVersion
        guard let replay = EditReplay.replay(snapshot: nil, entries: entries, createVersion: createVersion),
            replay.mismatchSeq == nil, replay.lastAppliedSeq == seq
        else {
            throw failure("edit-log.jsonl does not replay to its last line, seq \(seq)")
        }
        guard document == replay.document else {
            throw failure("the project does not open with the replay of edit-log.jsonl: edit.json does not agree with it")
        }

        let history = UndoHistory(entries: entries, createVersion: createVersion)
        let live = Set(history.done + history.undone)
        var groups: [Int: [EditChange]] = [:]
        var walk = DocumentMigration.LogWalk(createVersion: createVersion)
        for entry in entries {
            switch entry {
            case let .migrate(_, from, to):
                _ = walk.walkMigrate(from: from, to: to)
            case let .do(_, group, _, changes, _) where live.contains(group):
                // Undone on the document of the current version: carried there from the version the line is in.
                guard let carried = DocumentMigration.carried(changes, from: walk.version, to: EditDocument.currentVersion) else {
                    throw failure("the changes of group \(group) do not carry to the current version")
                }
                groups[group, default: []] += carried
            default:
                break
            }
        }
        var json: JSONValue
        do {
            json = try JSONValue(encoding: replay.document)
        } catch {
            throw failure("the replay of edit-log.jsonl cannot be encoded: \(error)")
        }
        for (count, group) in history.done.reversed().enumerated() {
            do {
                json = try json.applying((groups[group] ?? []).reversed().map(\.inverse))
            } catch {
                throw failure("undo \(count + 1) of \(history.done.count), of group \(group), does not apply: \(error)")
            }
        }
        let undone: EditDocument
        do {
            undone = try json.decoded(as: EditDocument.self)
        } catch {
            throw failure("undoing the \(history.done.count) groups leaves no document: \(error)")
        }
        guard (try? JSONValue(encoding: undone)) == json, state(undone) == state(created) else {
            throw failure("undoing the \(history.done.count) groups does not give back the create of edit-log.jsonl")
        }
        print(
            "OK: \(version), edit-log.jsonl at seq \(seq) in \(entries.count) lines, \(history.done.count) undos back to the "
                + "\(kind) document, \(history.undone.count) to redo")
    }

    /// Prints "FAIL: `message`" and gives the error that ends the command with 1.
    private func failure(_ message: String) -> ExitCode {
        print("FAIL: \(message)")
        return .failure
    }

    /// `document` at no line of the log in particular and, unless `keepingClipIDs`, with the ids of its clips aside.
    private func state(_ document: EditDocument, keepingClipIDs: Bool = true) -> EditDocument {
        var document = document
        document.logSequence = 0
        if !keepingClipIDs {
            for index in document.sequence.indices { document.sequence[index].id = "" }
        }
        return document
    }

    /// Whether anything is at `url`, a symlink included, without following it.
    private func exists(_ url: URL) -> Bool {
        var info = stat()
        return lstat(url.path, &info) == 0
    }
}
