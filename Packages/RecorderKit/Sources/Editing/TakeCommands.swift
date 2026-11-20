// SPDX-License-Identifier: GPL-3.0-or-later
import Analysis
import Foundation
import ProjectFormat

/// One take of the package as the Takes menu lists it (phase 3 design §8.1, 3d plan decision 6).
public struct TakeInfo: Equatable, Sendable {
    public let id: String
    /// Its place in the manifest, from 1: "Take 2".
    public let number: Int
    public let startedAt: Date
    /// Nanoseconds of its recorded spans (`TakeTimeline.recordedSpans`): its pauses are left out.
    public let duration: Int64
    /// Whether a clip of the sequence (one with content too) is of it.
    public let inUse: Bool
    /// Whether it recorded no span: the menu shows it disabled, "empty".
    public let isEmpty: Bool

    public init(id: String, number: Int, startedAt: Date, duration: Int64, inUse: Bool, isEmpty: Bool) {
        self.id = id
        self.number = number
        self.startedAt = startedAt
        self.duration = duration
        self.inUse = inUse
        self.isEmpty = isEmpty
    }
}

/// The takes of the package in the editor (phase 3 design §8.1 and §8.2, 3d plan decisions 6 and 7): the list of the
/// Takes menu, and "Use from Here", "Add to End" and the step that "Re-record from Here" applies once the new take is
/// recorded, as pure functions of the document. `take` is the project focused on that take (`LoadedProject.focused(on:)`).
///
/// Each command is one step that does this, and that never joins the one before it in an undo group, however soon after
/// it comes: its `target` is the ids of the clips it adds, in order, joined by commas (as `SequenceCommands` aims a step
/// at its clips), never ones a step before it added, so each "Use from Here", "Add to End" and re-record undoes alone:
/// 1. **The cut.** The sequence is cut at the output instant `τ` (clamped to the output), as `SequenceCommands.split`
///    cuts it: the clip shown there ends at the source instant shown there and every clip after it goes, and so does a
///    clip with content at `τ`, whole (it is never cut). A clip a cut would leave a piece of less than a frame of is not
///    cut: it goes when its piece before `τ` is shorter than a frame (`τ` is at its start), and stays whole when only
///    its piece after `τ` is. On an edge, the clip that starts there goes.
/// 2. **What is added.** The take's recorded spans (`TakeTimeline.recordedSpans`, the pauses closed), each a new clip at
///    1× with the id `makeID("c-")` and its sound with its picture, from the last instant of the take that a clip left
///    before the cut shows (its end, or the point of a clip with content of it) on: the whole take when none is left
///    (design §8.1 says "that whole take"; from that instant on keeps the invariant of §9 when the sequence used the
///    take before the playhead, 3d plan decision 7). A piece shorter than a frame is left out. Nothing to add is `nil`.
/// 3. **A take new in the document** (no clip of it, and neither its screen nor its camera in the document) brings in
///    the same step what `NewDocument` gives a take: its screen and, with two or more screens, the changes of
///    `screenFollow-1` in the output the step leaves (and the planner's name, if the document had none); its camera as
///    it recorded it (`camera.initial`, and its `cameraStyle` events as changes `.recorded` with new `k-` ids, in time
///    order); with the automatic zoom on, its blocks of `autoZoom-1` (`ZoomCommands.replanned`); and, where it shows a
///    window, corners that cover the window's black ones (`NewDocument.windowCornerCover`), if the document's do not.
///    No key of the volume is written for it: the mix finds each of its tracks by its id (`AudioPlan.trackGain`). A take
///    the document knows already gets its clips alone, so what the user changed of it stays.
///
/// The commands read the take's events (`LoadedProject.events`), which come from the disk the first time any value
/// focused on it asks for them, as `takes(of:document:)` reads them: that first read is never made on the main thread.
///
/// Nothing of the document before `τ` changes but the clip cut there, and every take stays in order
/// (`SequenceRules.firstOutOfOrder(in:)` is `nil` for a document that was in order), the cut of the sound of the clip cut
/// held to its limits (`SequenceRules.audioShift(of:at:)`), so the step breaks no rule of the document
/// (`DocumentRules`). The whole step undoes as one.
public enum TakeCommands {
    /// One `TakeInfo` for each take of the manifest, in its order. Reads the events of each take (`events(ofTake:)`,
    /// from the disk the first time): never on the main thread.
    public static func takes(of project: LoadedProject, document: EditDocument) -> [TakeInfo] {
        let used = Set(document.sequence.map(\.take))
        return project.takes.enumerated().map { index, take in
            let spans = TakeTimeline.recordedSpans(take: take, events: project.events(ofTake: take.id))
            let duration = spans.reduce(Int64(0)) { sum, span in
                let (total, overflow) = sum.addingReportingOverflow(
                    Int64(clamping: span.upperBound.nanoseconds - span.lowerBound.nanoseconds))
                return overflow ? .max : total
            }
            return TakeInfo(
                id: take.id, number: index + 1, startedAt: take.startedAt, duration: duration, inUse: used.contains(take.id),
                isEmpty: spans.isEmpty)
        }
    }

    /// "Use from Here": the sequence from output instant `τ` on replaced by `take`, from where the sequence left it before
    /// `τ` (the whole take if it did not use it there), as the type says. `.takeUse`.
    public static func useFromHere(
        _ doc: EditDocument, take: LoadedProject, atOutput τ: Int64, makeID: (String) -> String
    ) -> EditStep? {
        replacing(doc, from: τ, with: take, label: .takeUse, makeID: makeID)
    }

    /// "Add to End": what is left of `take` after the last instant of it the sequence shows (the whole take if it shows
    /// none) added after the last clip. `.takeUse`; `nil` when nothing is left.
    public static func appendToEnd(_ doc: EditDocument, take: LoadedProject, makeID: (String) -> String) -> EditStep? {
        replacing(doc, from: TimeMap(sequence: doc.sequence).duration, with: take, label: .takeUse, makeID: makeID)
    }

    /// The step of "Re-record from Here" once the new take `take` is recorded (design §8.2): the clip at output instant
    /// `τ` split there, the clips after it out and the new take added whole, as the type says. `.takeRerecord`.
    public static func rerecord(
        _ doc: EditDocument, take: LoadedProject, atOutput τ: Int64, makeID: (String) -> String
    ) -> EditStep? {
        replacing(doc, from: τ, with: take, label: .takeRerecord, makeID: makeID)
    }

    // MARK: - Private

    /// The step of each command: the cut at `τ` and `project`'s take added after it.
    private static func replacing(
        _ doc: EditDocument, from τ: Int64, with project: LoadedProject, label: EditLabel, makeID: (String) -> String
    ) -> EditStep? {
        let take = project.take
        let events = project.events
        let (kept, head) = cut(doc, at: τ)

        // The last instant of the take shown before the cut: the end of a stretch, the point of a clip with content.
        let left = (doc.sequence[..<kept] + (head.map { [$0] } ?? [])).filter { $0.take == take.id }
        let last = left.map { $0.content == nil ? max($0.start, $0.end) : $0.start }.max()
        let frame = SequenceCommands.oneFrame(of: doc)
        let pieces = TakeTimeline.recordedSpans(take: take, events: events).compactMap { span -> Clip? in
            let start = last.map { max(span.lowerBound, $0) } ?? span.lowerBound
            guard start < span.upperBound else { return nil }
            let clip = Clip(id: "", take: take.id, start: start, end: span.upperBound, speed: 1)
            return SequenceCommands.lasts(clip, frame) ? clip : nil
        }
        guard !pieces.isEmpty else { return nil }

        var ids = Set(doc.sequence.map(\.id))
        // The clip cut at `τ` keeps its start and its speed, and the take added starts its sound with its picture.
        var sequence = SequenceChanges(doc.sequence, takeBounds: nil)
        // What goes, at the index of the first clip after what stays.
        let firstGone = kept + (head == nil ? 0 : 1)
        if let head { sequence.replace(doc.sequence[kept], with: head) }
        for clip in doc.sequence[firstGone...] {
            sequence.remove(clip, at: firstGone)
        }
        var added: [String] = []
        for (offset, var piece) in pieces.enumerated() {
            piece.id = SequenceCommands.newID(makeID, avoiding: &ids)
            added.append(piece.id)
            sequence.insert(piece, at: firstGone + offset)
        }

        var changes = sequence.changes
        if isNew(take.id, in: doc) {
            guard let parts = newTakeParts(of: project, in: doc, sequence: sequence.sequence, label: label, makeID: makeID)
            else { return nil }
            changes += parts
        }
        // New clip ids, which no clip of the sequence has: never the target of the step before, whose clips are in it.
        return EditStep(label: label, target: added.joined(separator: ","), changes: changes)
    }

    /// Where the sequence is cut at output instant `τ` (clamped to the output): the number of clips that stay whole, and
    /// the piece before `τ` of the next one, if it is cut (it keeps its id; its speed as a command writes it).
    private static func cut(_ doc: EditDocument, at τ: Int64) -> (kept: Int, head: Clip?) {
        let map = TimeMap(sequence: doc.sequence)
        let at = min(max(τ, 0), map.duration)
        guard at < map.duration, let shown = map.source(atOutput: at) else { return (doc.sequence.count, nil) }
        let k = shown.clip
        let clip = doc.sequence[k]
        // A clip with content at the cut, or one that starts there, goes whole.
        guard clip.content == nil, at > map.clipOutputStarts[k] else { return (k, nil) }
        let frame = SequenceCommands.oneFrame(of: doc)
        var (head, tail) = (SequenceCommands.written(clip), SequenceCommands.written(clip))
        head.end = shown.source
        tail.start = shown.source
        // The rule of the frame (`SequenceCommands.split`): a piece of less than a frame is not cut off.
        guard SequenceCommands.lasts(head, frame) else { return (k, nil) }
        guard SequenceCommands.lasts(tail, frame) else { return (k + 1, nil) }
        return (k, head)
    }

    /// Whether `take` is new in `doc`: no clip of it, and neither its screen nor its camera in the document.
    private static func isNew(_ take: String, in doc: EditDocument) -> Bool {
        !doc.sequence.contains { $0.take == take } && doc.screens.initial[take] == nil && doc.camera.initial[take] == nil
    }

    /// The changes that bring `project`'s take, new in `doc`, into the document whose sequence is `sequence`: its screen
    /// and its changes, its camera, the corners of its window and its automatic zooms, as the type says. `nil` if a value
    /// cannot be encoded.
    private static func newTakeParts(
        of project: LoadedProject, in doc: EditDocument, sequence: [Clip], label: EditLabel, makeID: (String) -> String
    ) -> [EditChange]? {
        let take = project.take
        let events = project.events
        var next = doc
        next.sequence = sequence
        var changes = DocumentChanges()

        // The screen, as `NewDocument` plans it, in the output the step leaves (only the take's clips count).
        let screens = ScreenFollowPlanner.plan(
            take: take, events: events, package: project.package, timeMap: TimeMap(sequence: next.sequence))
        if let initial = screens.initial {
            changes.set(["screens", "initial", take.id], from: String?.none, to: initial)
            next.screens.initial[take.id] = initial
        }
        if take.tracks.filter(\.kind.isScreen).count >= 2 {
            let taken = Set(next.screens.changes.map(\.id))
            for change in screens.changes where !taken.contains(change.id) {
                changes.insert(change, into: .screenChanges, at: next.screens.changes.count)
                next.screens.changes.append(change)
            }
            if next.screens.planner == nil {
                changes.set(["screens", "planner"], from: String?.none, to: ScreenFollowPlanner.id)
                next.screens.planner = ScreenFollowPlanner.id
            }
        }

        // The camera as the take recorded it (`EditDocument.legacy`), its changes with new ids.
        let initial = take.cameraStyle ?? .default
        changes.set(["camera", "initial", take.id], from: CameraStyle?.none, to: initial)
        next.camera.initial[take.id] = initial
        var cameraIDs = Set(next.camera.changes.map(\.id))
        for event in events.sortedByTime() {
            guard case let .cameraStyle(style) = event.kind else { continue }
            let id = DocumentIDs.new("k-", makeID, avoiding: &cameraIDs)
            let change = CameraChange(id: id, take: take.id, t: event.t, style: style, origin: .recorded)
            changes.insert(change, into: .cameraChanges, at: next.camera.changes.count)
            next.camera.changes.append(change)
        }

        // The corners that cover its window's black ones, where the document's do not.
        let cover = NewDocument.windowCornerCover(of: next, take: take, events: events)
        if cover > next.style.cornerRadius {
            changes.set(["style", "cornerRadius"], from: next.style.cornerRadius, to: cover)
            next.style.cornerRadius = cover
        }

        // Its automatic zooms, planned in the document so far.
        if next.zoom.auto.enabled {
            let regions = ZoomCommands.replanned(next, take: take, events: events)
            changes.edit(.zoomRegions, from: doc.zoom.regions, to: regions, id: \.id)
        }
        // Never empty: the camera's start is always set. `nil` only for a value that cannot be encoded.
        return changes.step(label: label, target: EditCollection.sequence.rawValue)?.changes
    }
}
