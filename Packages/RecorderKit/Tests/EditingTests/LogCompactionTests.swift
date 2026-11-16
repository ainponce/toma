// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import Testing
// Not @testable: the session uses only the public API.
import Editing
import ProjectFormat

let app = AppInfo(name: "Toma", version: "0.2.0")

/// The document every log of these tests starts from, small so that applying lines is cheap.
enum SmallDocument {
    static let document = EditDocument(
        documentVersion: EditDocument.currentVersion,
        logSequence: 0,
        aspect: .landscape,
        frameRate: 60,
        sequence: [
            Clip(id: "c-00000001", take: "take-001", start: HostTime(nanoseconds: 1_000), end: HostTime(nanoseconds: 9_000), speed: 1)
        ],
        screens: ScreenPlan(initial: ["take-001": "display-1"], changes: []),
        style: StageStyle(
            background: .tomaClassic, backgroundBlur: 0, padding: 0.08, cornerRadius: 0.012, shadow: 0, frame: .none,
            screenSampling: .bilinear, geometryTransition: .none),
        cursor: CursorStyle(
            show: true, style: .toma, scale: 1, smoothing: .off, hideWhenIdle: false, idleDelay: 2, clickEffect: "none",
            clickSound: "none", clickSoundGain: 0.5, motionBlur: 0),
        zoom: ZoomPlan(
            show: true,
            auto: AutoZoomSettings(
                enabled: false, triggers: .clicks, holdWhileTyping: true, depth: 2, groupGap: 2.5, leadIn: 0.5, leadOut: 1,
                follow: true, planner: "autoZoom-1"),
            spring: SpringSpec(damping: 1, response: 0.7), motionBlur: 0, regions: [], suppressed: []),
        camera: CameraPlan(show: true, initial: [:], changes: []),
        audio: AudioPlan(limiter: false, tracks: [:]))

    static let create = EditLogEntry.create(seq: 1, document: document, app: app)
}

/// 2026-11-15T20:12:03Z, the date of the example of design §6.3.
private let date = Date(timeIntervalSince1970: 1_794_773_523)

private func set(_ path: String, _ before: Double, _ after: Double) throws -> EditChange {
    .set(path: try JSONPointer(path), before: .number(before), after: .number(after))
}

private func doLine(_ seq: Int, group: Int, _ changes: EditChange..., label: EditLabel = .padding, at: Date = date) -> EditLogEntry {
    .do(seq: seq, group: group, label: label.rawValue, changes: changes, at: at)
}

private func replay(_ entries: [EditLogEntry]) throws -> EditReplay {
    try #require(EditReplay.replay(snapshot: nil, entries: entries))
}

/// `document` with the `logSequence` of the fixture, to compare states whatever line they are at.
private func state(_ document: EditDocument) -> EditDocument {
    var document = document
    document.logSequence = SmallDocument.document.logSequence
    return document
}

private func seqsGrow(_ entries: [EditLogEntry]) -> Bool {
    zip(entries, entries.dropFirst()).allSatisfy { $0.seq < $1.seq }
}

// MARK: - Equivalence

@Test func compactionKeepsStateAndStacks() throws {
    var generator = SplitMix64(seed: 0x746f_6d61_2d74_3130)
    var editor = Editor(SmallDocument.document)
    var clock = date
    for _ in 0..<300 {
        let roll = Int.random(in: 0..<20, using: &generator)
        if roll < 10 {
            clock += Double.random(in: 0.05...1.4, using: &generator)
            if let step = randomStep(editor.document, using: &generator) {
                try editor.perform(step, at: clock)
            }
        } else if roll < 15 {
            for _ in 0..<Int.random(in: 1...3, using: &generator) {
                try editor.undo()
            }
        } else if roll < 19 {
            for _ in 0..<Int.random(in: 1...2, using: &generator) {
                try editor.redo()
            }
        } else {
            // A gap in the seqs, which the log allows.
            editor.history.nextSeq += Int.random(in: 1...3, using: &generator)
        }
    }
    // And three undos at the end, so that some undone groups are written by decision 4.
    for _ in 0..<3 {
        try editor.undo()
    }
    #expect(editor.clearedRedos >= 2, "a new group after an undo at least twice")
    #expect(editor.history.undone.count >= 3, "groups left to redo")

    let original = try replay(editor.entries)
    #expect(original.mismatchSeq == nil)
    #expect(state(original.document) == state(editor.document))

    let compacted = LogCompaction.compact(editor.entries)
    #expect(compacted.count < editor.entries.count)
    #expect(compacted.first == SmallDocument.create)
    #expect(compacted.last?.seq == editor.entries.last?.seq)
    #expect(seqsGrow(compacted))
    #expect(try compacted.map { try EditLogEntry(jsonLine: $0.jsonLine()) } == compacted, "written and read back as lines")

    let replayed = try replay(compacted)
    #expect(replayed.mismatchSeq == nil)
    #expect(replayed.document == original.document)
    #expect(replayed.lastAppliedSeq == original.lastAppliedSeq)

    let history = UndoHistory(entries: compacted)
    #expect(history.done == editor.history.done)
    #expect(history.undone == editor.history.undone)
    #expect(history.undoLabel == editor.history.undoLabel)
    #expect(history.redoLabel == editor.history.redoLabel)
    #expect(history.nextSeq == UndoHistory(entries: editor.entries).nextSeq)

    // Undoing everything and then redoing everything goes through the same documents, down to the create's.
    let walked = try walkThroughTheHistory(compacted)
    #expect(try walked == walkThroughTheHistory(editor.entries))
    #expect(walked.map(state).contains(SmallDocument.document))
}

@Test func compactionFusesConsecutiveSetsOnOnePath() throws {
    func padding(_ k: Int) -> Double { 0.08 + Double(k) / 100 }
    var history = UndoHistory(entries: [SmallDocument.create])
    var entries = [SmallDocument.create]
    for k in 0..<10 {
        let step = EditStep(
            label: .padding, target: "/style/padding",
            changes: [try set("/style/padding", padding(k), padding(k + 1))])
        let at = date + Double(k) / 10
        let entry = EditLogEntry.do(
            seq: history.nextSeq, group: history.groupForNext(step, at: at), label: step.label.rawValue, changes: step.changes,
            at: at.roundedToWholeSeconds)
        history.record(entry)
        entries.append(entry)
    }
    #expect(history.done == [2])
    let lastAt = (date + 0.9).roundedToWholeSeconds
    let burst = doLine(11, group: 2, try set("/style/padding", padding(0), padding(10)), at: lastAt)
    #expect(LogCompaction.compact(entries) == [SmallDocument.create, burst])

    // Only sets that follow each other on the same path are fused: one on another path in the middle keeps them apart,
    // and one on another path never joins, even where its before is the after of the one before it.
    let mixed: [EditLogEntry] = [
        SmallDocument.create,
        doLine(2, group: 2, try set("/style/padding", 0.08, 0.1), try set("/style/padding", 0.1, 0.12), label: .applyDefaultStyle),
        doLine(3, group: 2, try set("/style/shadow", 0, 0.3), try set("/style/padding", 0.12, 0.14), label: .applyDefaultStyle),
        doLine(4, group: 2, try set("/style/padding", 0.14, 0.16), label: .applyDefaultStyle),
        doLine(
            5, group: 5, try set("/style/padding", 0.16, 0.012), try set("/style/cornerRadius", 0.012, 0.05), label: .applyDefaultStyle),
    ]
    let fused = [
        SmallDocument.create,
        doLine(
            4, group: 2, try set("/style/padding", 0.08, 0.12), try set("/style/shadow", 0, 0.3), try set("/style/padding", 0.12, 0.16),
            label: .applyDefaultStyle),
        doLine(
            5, group: 5, try set("/style/padding", 0.16, 0.012), try set("/style/cornerRadius", 0.012, 0.05), label: .applyDefaultStyle),
    ]
    #expect(LogCompaction.compact(mixed) == fused)
    #expect(try replay(fused).document == replay(mixed).document)
}

@Test func twoUndoneGroupsCompactInOrder() throws {
    // Plan decision 4: the do lines of the undone groups in the order they were done, then their undo lines in reverse.
    // Written as "each do followed by its undo", the before of the second would not match.
    let entries: [EditLogEntry] = [
        SmallDocument.create,
        doLine(3, group: 3, try set("/style/padding", 0.08, 0.09)),
        doLine(4, group: 3, try set("/style/padding", 0.09, 0.1)),
        doLine(5, group: 5, try set("/style/padding", 0.1, 0.2)),
        .undo(seq: 6, group: 5),
        .redo(seq: 7, group: 5),
        .undo(seq: 8, group: 5),
        .undo(seq: 9, group: 3),
    ]
    let compacted = LogCompaction.compact(entries)
    #expect(compacted == [
        SmallDocument.create,
        doLine(6, group: 3, try set("/style/padding", 0.08, 0.1)),
        doLine(7, group: 5, try set("/style/padding", 0.1, 0.2)),
        .undo(seq: 8, group: 5),
        .undo(seq: 9, group: 3),
    ])
    let replayed = try replay(compacted)
    #expect(replayed.mismatchSeq == nil)
    #expect(try replayed.document == replay(entries).document)

    let history = UndoHistory(entries: compacted)
    #expect(history.done == [])
    #expect(history.undone == [5, 3])
    #expect(history.undone.last == 3, "the next redo is g3")
    let redone = try replay(compacted + [.redo(seq: 10, group: 3), .redo(seq: 11, group: 5)])
    #expect(redone.mismatchSeq == nil)
    #expect(redone.document.style.padding == 0.2)
}

@Test func logsTheCompactionCannotKeepEquivalentAreLeftAsTheyAre() throws {
    // Each of these replays (or is refused by the replay) differently from any log of stacks, so nothing is dropped.
    let padding = doLine(2, group: 2, try set("/style/padding", 0.08, 0.1))
    let shadow = doLine(3, group: 3, try set("/style/shadow", 0, 0.1))
    let logs: [(String, [EditLogEntry])] = [
        ("no create first", [padding, shadow]),
        ("an undo of a group under the top", [SmallDocument.create, padding, shadow, .undo(seq: 4, group: 2)]),
        ("a redo of a group under the top",
         [SmallDocument.create, padding, shadow, .undo(seq: 4, group: 3), .undo(seq: 5, group: 2), .redo(seq: 6, group: 3)]),
        ("a do of an old group after another one",
         [SmallDocument.create, padding, shadow, doLine(4, group: 2, try set("/style/padding", 0.1, 0.2))]),
        ("a do of a group after its undo",
         [SmallDocument.create, padding, .undo(seq: 3, group: 2), doLine(4, group: 2, try set("/style/padding", 0.08, 0.2))]),
        ("a migrate that does not follow", [SmallDocument.create, padding, .migrate(seq: 3, from: 1, to: 1), shadow.renumbered(4)]),
        ("a second create", [SmallDocument.create, padding, SmallDocument.create.renumbered(3)]),
    ]
    for (name, entries) in logs {
        #expect(LogCompaction.compact(entries) == entries, "\(name)")
    }
    // A log of only its create has nothing to compact.
    #expect(LogCompaction.compact([SmallDocument.create]) == [SmallDocument.create])
}

@Test func thresholdsArePassedIn() {
    #expect(LogCompaction.isNeeded(bytes: 100, entries: 11, maxBytes: .max, maxEntries: 10))
    #expect(LogCompaction.isNeeded(bytes: 101, entries: 1, maxBytes: 100, maxEntries: .max))
    #expect(!LogCompaction.isNeeded(bytes: 100, entries: 10, maxBytes: 100, maxEntries: 10))
    #expect(!LogCompaction.isNeeded(bytes: 100, entries: 11))
    #expect(LogCompaction.maxBytes == 8 * 1_048_576)
    #expect(LogCompaction.maxEntries == 20_000)
    // Past either default, it is needed.
    #expect(LogCompaction.isNeeded(bytes: LogCompaction.maxBytes + 1, entries: 1))
    #expect(LogCompaction.isNeeded(bytes: 1, entries: LogCompaction.maxEntries + 1))
}

// MARK: - Helpers

/// An editor over `UndoHistory` the way the session uses it: a step gets its group from `groupForNext`, every line takes
/// `nextSeq`, undo and redo take the tops of the stacks, and the document follows each line.
private struct Editor {
    var history: UndoHistory
    private(set) var entries: [EditLogEntry]
    private(set) var document: EditDocument
    /// How many times a new group was started while something could be redone.
    private(set) var clearedRedos = 0
    private var groups: [Int: [EditChange]] = [:]

    init(_ document: EditDocument) {
        let create = EditLogEntry.create(seq: 1, document: document, app: app)
        history = UndoHistory(entries: [create])
        entries = [create]
        self.document = document
    }

    mutating func perform(_ step: EditStep, at: Date) throws {
        let group = history.groupForNext(step, at: at)
        if groups[group] == nil, !history.undone.isEmpty { clearedRedos += 1 }
        document = try document.applying(step.changes)
        groups[group, default: []] += step.changes
        append(.do(seq: history.nextSeq, group: group, label: step.label.rawValue, changes: step.changes, at: at.roundedToWholeSeconds))
    }

    mutating func undo() throws {
        guard let group = history.done.last else { return }
        document = try document.applying(groups[group, default: []].reversed().map(\.inverse))
        append(.undo(seq: history.nextSeq, group: group))
    }

    mutating func redo() throws {
        guard let group = history.undone.last else { return }
        document = try document.applying(groups[group, default: []])
        append(.redo(seq: history.nextSeq, group: group))
    }

    private mutating func append(_ entry: EditLogEntry) {
        history.record(entry)
        entries.append(entry)
    }
}

/// A step on `document` of one of the kinds the editor writes: sets, bursts of them, an insert, a remove, a replace and a
/// step of several changes; `nil` if the one picked would change nothing.
private func randomStep(_ document: EditDocument, using generator: inout SplitMix64) -> EditStep? {
    let level = Double(Int.random(in: 0...20, using: &generator)) / 100
    switch Int.random(in: 0..<7, using: &generator) {
    case 0, 1:
        return document.setChange("/style/padding", level).map { EditStep(label: .padding, target: "/style/padding", changes: [$0]) }
    case 2:
        return document.setChange("/style/cornerRadius", level).map {
            EditStep(label: .cornerRadius, target: "/style/cornerRadius", changes: [$0])
        }
    case 3:
        let index = Int.random(in: 0...document.zoom.suppressed.count, using: &generator)
        let start = UInt64.random(in: 1_000...8_000, using: &generator)
        let range = SourceRange(take: "take-001", start: HostTime(nanoseconds: start), end: HostTime(nanoseconds: start + 500))
        let change = document.insertChange(.zoomSuppressed, at: index, range)
        return EditStep(label: .zoomDelete, target: "/zoom/suppressed", changes: [change])
    case 4:
        guard !document.zoom.suppressed.isEmpty else { return nil }
        let index = Int.random(in: 0..<document.zoom.suppressed.count, using: &generator)
        return document.removeChange(.zoomSuppressed, at: index).map {
            EditStep(label: .zoomAdd, target: "/zoom/suppressed", changes: [$0])
        }
    case 5:
        var clip = document.sequence[0]
        clip.speed = [0.5, 1, 2, 4].randomElement(using: &generator) ?? 1
        return document.replaceChange(.sequence, id: clip.id, with: clip).map { EditStep(label: .speed, target: clip.id, changes: [$0]) }
    default:
        let changes = [document.setChange("/style/padding", level), document.setChange("/style/shadow", 1 - level)].compactMap { $0 }
        return changes.isEmpty ? nil : EditStep(label: .applyDefaultStyle, target: "", changes: changes)
    }
}

/// The documents met undoing every group of `entries` and then redoing every one, each from a line appended to the log
/// and replayed (from the document before it, so each replay applies one line).
private func walkThroughTheHistory(_ entries: [EditLogEntry]) throws -> [EditDocument] {
    var entries = entries
    var history = UndoHistory(entries: entries)
    var document = try replay(entries).document
    var documents = [document]
    func append(_ line: EditLogEntry) throws {
        entries.append(line)
        history.record(line)
        let replayed = try #require(EditReplay.replay(snapshot: document, entries: entries))
        #expect(replayed.mismatchSeq == nil, "line \(line.seq)")
        document = replayed.document
        documents.append(document)
    }
    while let group = history.done.last {
        try append(.undo(seq: history.nextSeq, group: group))
    }
    while let group = history.undone.last {
        try append(.redo(seq: history.nextSeq, group: group))
    }
    return documents
}

extension EditLogEntry {
    /// This entry with another `seq`.
    func renumbered(_ seq: Int) -> EditLogEntry {
        switch self {
        case let .create(_, document, app): .create(seq: seq, document: document, app: app)
        case let .do(_, group, label, changes, at): .do(seq: seq, group: group, label: label, changes: changes, at: at)
        case let .undo(_, group): .undo(seq: seq, group: group)
        case let .redo(_, group): .redo(seq: seq, group: group)
        case let .migrate(_, from, to): .migrate(seq: seq, from: from, to: to)
        }
    }
}

/// SplitMix64 (Steele, Lea and Flood): a seeded generator, so a failure can be run again.
private struct SplitMix64: RandomNumberGenerator {
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
