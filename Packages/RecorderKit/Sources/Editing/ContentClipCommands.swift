// SPDX-License-Identifier: GPL-3.0-or-later
import ProjectFormat

/// The commands of the clips with content (phase 3 design §5.2–§5.4, §9; phase 3a plan decision 11): a frozen frame, a
/// title card or an imported clip put into the sequence, and their changes, as pure functions of the document. Each one
/// gives the step that does it (`EditStep`), or nothing when there is nothing to do.
///
/// - A clip with content is a point of a take (`start == end`) that lasts in the output (`ClipContent.outputDuration`).
///   One goes in where the place says, as a point that keeps every take in order (the invariant of design §9,
///   `SequenceRules`): inside a stretch of a take, the stretch is split at the source instant shown there
///   (`TimeMap.source(atOutput:)`) and the point goes between its two pieces, at that instant, all in one step that one
///   undo takes back; less than a frame from a clip's edge, nothing is split and the point goes at that edge, as a point
///   of the stretch of the take next to it (the end of the one before, the start of the one after; the one the playhead
///   is in first), or, between two clips with content or at the sequence's ends with one there, of that clip's point. In
///   a clip with content, nothing goes in: it is never cut.
/// - The rules of `SequenceCommands` hold: no clip shorter than a frame of output at the document's `frameRate`, a piece
///   of a split with the speed `ClipSpeed.clamped(_:)` reads and its sound starting with its picture (`audioShift` 0),
///   every cut of the sound the step leaves out of its limits held to them in the same step, the new ids made by
///   `makeID("c-")` and never ones in use, and the changes built from the clips they touch. No step breaks a rule of the
///   document (`DocumentRules`): an imported clip names a clip of `assets/` and lasts.
/// - Labels: `.clipFreeze`, `.clipCard` and `.clipMedia` for what goes in, `.clipContent` for every change of one; the
///   `target` is the id of the clip with content.
public enum ContentClipCommands {
    /// Where a clip with content goes in.
    public enum Place: Equatable, Sendable {
        /// At the playhead, at this output instant: inside a stretch of a take, splitting it there; less than a frame
        /// from an edge, at that edge; inside a clip with content, nowhere. Before the output's start, at its start;
        /// at or past its end, at its end.
        case output(Int64)
        /// Before the first clip, at its start (its point, for a clip with content) and in its take.
        case start
        /// After the last clip, at the end of its take's last clip (its point, for a clip with content).
        case end
    }

    /// The loudest and the softest an imported clip's sound can be set to, in dB (`MediaClip.volume`).
    public static let volumeRange: ClosedRange<Double> = -60...12

    /// "Freeze Frame" at the playhead at output instant `atOutput` (design §5.3): a frozen frame of the instant of the
    /// take shown there, of `ClipContent.freezeDuration` (2 s), with the id `makeID("c-")`, in the place `.output(atOutput)`
    /// says; the second piece of a split clip gets the next id. `nil` inside a clip with content or with nothing in the
    /// sequence. Labelled `.clipFreeze`.
    public static func freeze(_ doc: EditDocument, atOutput: Int64, makeID: (String) -> String) -> EditStep? {
        insert(.freeze(duration: ClipContent.freezeDuration), into: doc, at: .output(atOutput), label: .clipFreeze, makeID: makeID)
    }

    /// "Add Title Card" (design §5.2): a title card of `ClipContent.cardDuration` (3 s) with `title`, no subtitle, the
    /// centred style, the project's background and white text, with the id `makeID("c-")`, at `place`. `nil` where
    /// `place` puts nothing. Labelled `.clipCard`.
    public static func addCard(_ doc: EditDocument, at place: Place, title: String, makeID: (String) -> String) -> EditStep? {
        let card = TitleCard(title: title, subtitle: "", style: .centered, background: .stage, textColor: RGBA(1, 1, 1, 1))
        return insert(.card(card, duration: ClipContent.cardDuration), into: doc, at: place, label: .clipCard, makeID: makeID)
    }

    /// An imported clip in the sequence (design §5.4): the whole of the file `asset` (`assets/<sha>.<mov|mp4|m4v>`, as
    /// `EditSession.importAsset` names it), of `fileDuration` ns, from 0 at 1× and 0 dB, with the id `makeID("c-")`, at
    /// `place`. `nil` where `place` puts nothing, for a path that is not a clip of `assets/` (`DocumentRules.isAssetPath`),
    /// or for a file that would last less than a frame of output. Labelled `.clipMedia`.
    public static func addMedia(
        _ doc: EditDocument, asset: String, fileDuration: Int64, at place: Place, makeID: (String) -> String
    ) -> EditStep? {
        let media = ClipContent.media(MediaClip(asset: asset, start: 0, end: fileDuration, speed: 1, volume: 0))
        guard DocumentRules.isAssetPath(asset, as: .video), media.outputDuration >= SequenceCommands.oneFrame(of: doc) else {
            return nil
        }
        return insert(media, into: doc, at: place, label: .clipMedia, makeID: makeID)
    }

    /// Where a file dropped on the Video track at output instant `nearOutput` goes: the nearer edge of the clip under it
    /// (its end at the middle), as `.output` of that edge, so nothing is split. Before the output, its start; past it,
    /// its end; `.output(0)` with no output.
    public static func insertionPoint(_ doc: EditDocument, nearOutput: Int64) -> Place {
        let map = TimeMap(sequence: doc.sequence)
        guard nearOutput > 0, nearOutput < map.duration, let shown = map.source(atOutput: nearOutput) else {
            return .output(nearOutput > 0 ? map.duration : 0)
        }
        let (start, end) = extent(shown.clip, in: map)
        return .output(nearOutput - start < end - nearOutput ? start : end)
    }

    /// The length of the frozen frame or the title card `clipID` in the output, `duration` held to
    /// `ClipContent.durationRange` (0.1 to 60 s), as its right edge on the Video track sets it. `nil` for an imported clip
    /// (its length is its file's), a stretch of a take, no such clip, or the length it has. Labelled `.clipContent`.
    public static func setDuration(_ doc: EditDocument, clipID: String, _ duration: Int64) -> EditStep? {
        let held = min(max(duration, ClipContent.durationRange.lowerBound), ClipContent.durationRange.upperBound)
        return change(doc, clipID: clipID) { content in
            switch content {
            case .freeze: content = .freeze(duration: held)
            case let .card(card, _): content = .card(card, duration: held)
            case .media: break
            }
        }
    }

    /// The title card `clipID` with `edit` made to it (its texts, style, background or text color), in one `replace`.
    /// `nil` if it is not a title card or `edit` changes nothing. Labelled `.clipContent`.
    public static func changeCard(_ doc: EditDocument, clipID: String, _ edit: (inout TitleCard) -> Void) -> EditStep? {
        change(doc, clipID: clipID) { content in
            guard case .card(var card, let duration) = content else { return }
            edit(&card)
            content = .card(card, duration: duration)
        }
    }

    /// Moves `edge` of the imported clip `clipID` to output instant `toOutput`, as a clip of a take is trimmed: the file
    /// time at that edge moves by `round((toOutput − edge) × v)` ns, the edge where the output shows it now and `v` its
    /// speed (`ClipSpeed.clamped(_:)`). Both ends are held to the file, `[0, fileDuration]`, and the clip to at least a
    /// frame of output. `nil` for a clip that is not an imported one, a file without a frame of output, or a clip that
    /// stays as it is. Labelled `.clipContent`.
    public static func trimMedia(
        _ doc: EditDocument, clipID: String, edge: ClipEdge, toOutput: Int64, fileDuration: Int64
    ) -> EditStep? {
        guard let k = doc.sequence.firstIndex(where: { $0.id == clipID }), case let .media(media)? = doc.sequence[k].content
        else { return nil }
        let speed = ClipSpeed.clamped(media.speed)
        let shortest = shortestMedia(lasting: SequenceCommands.oneFrame(of: doc), speed: speed)
        guard fileDuration >= shortest else { return nil }
        let (start, end) = extent(k, in: TimeMap(sequence: doc.sequence))
        // The file's times as the clip is held to the file, before the edge moves.
        var trimmed = media
        trimmed.end = min(max(media.end, shortest), fileDuration)
        trimmed.start = min(max(media.start, 0), trimmed.end - shortest)
        switch edge {
        case .start:
            let moved = adding(media.start, fileOffset(toOutput, from: start, speed: speed))
            trimmed.start = min(max(moved, 0), trimmed.end - shortest)
        case .end:
            let moved = adding(media.end, fileOffset(toOutput, from: end, speed: speed))
            trimmed.end = min(max(moved, trimmed.start + shortest), fileDuration)
        }
        return change(doc, clipID: clipID) { $0 = .media(trimmed) }
    }

    /// The speed and the volume of the imported clip `clipID`, each one given: the speed held to `ClipSpeed.range`
    /// (`ClipSpeed.clamped(_:)`: one that is not a number is 1), the volume to `volumeRange` (−60 to +12 dB; one that is
    /// not a number leaves it). `nil` for a clip that is not an imported one, if nothing changes, or if the clip would
    /// last less than a frame of output. Labelled `.clipContent`.
    public static func setMedia(_ doc: EditDocument, clipID: String, speed: Double? = nil, volume: Double? = nil) -> EditStep? {
        let frame = SequenceCommands.oneFrame(of: doc)
        return change(doc, clipID: clipID) { content in
            guard case var .media(media) = content else { return }
            if let speed { media.speed = ClipSpeed.clamped(speed) }
            if let volume, !volume.isNaN { media.volume = min(max(volume, volumeRange.lowerBound), volumeRange.upperBound) }
            guard ClipContent.media(media).outputDuration >= frame else { return }
            content = .media(media)
        }
    }

    // MARK: - Private

    /// Where a clip with content goes in the sequence: between two clips at `index`, as a point of `take` at `point`, or
    /// between the two pieces of clip `split` split at the source instant `point`.
    private struct Insertion {
        var index: Int
        var take: String
        var point: HostTime
        /// The clip split at `point`, at `index − 1`; `nil` when nothing is split.
        var split: Int?
    }

    /// Which neighbour of an edge the playhead is in.
    private enum Side {
        case before, after
    }

    /// `content` put into `doc` at `place` as a new clip, in one step labelled `label` whose target is its id.
    private static func insert(
        _ content: ClipContent, into doc: EditDocument, at place: Place, label: EditLabel, makeID: (String) -> String
    ) -> EditStep? {
        guard let at = insertion(in: doc, at: place) else { return nil }
        var ids = Set(doc.sequence.map(\.id))
        var changes = SequenceChanges(doc.sequence)
        let clip = Clip(
            id: SequenceCommands.newID(makeID, avoiding: &ids), take: at.take, start: at.point, end: at.point, speed: 1,
            content: content)
        if let k = at.split {
            let original = doc.sequence[k]
            var (head, tail) = (SequenceCommands.written(original), SequenceCommands.written(original))
            head.end = at.point
            tail.start = at.point
            tail.id = SequenceCommands.newID(makeID, avoiding: &ids)
            tail.audioShift = 0
            changes.replace(original, with: head)
            changes.insert(clip, at: k + 1)
            changes.insert(tail, at: k + 2)
        } else {
            changes.insert(clip, at: at.index)
        }
        return EditStep(label: label, target: clip.id, changes: changes.changes)
    }

    /// Where `place` puts a clip with content in `doc`; `nil` inside a clip with content, or with no clip.
    private static func insertion(in doc: EditDocument, at place: Place) -> Insertion? {
        let sequence = doc.sequence
        guard !sequence.isEmpty else { return nil }
        switch place {
        case .start:
            return edge(0, in: sequence, playhead: .after)
        case .end:
            return edge(sequence.count, in: sequence, playhead: .before)
        case let .output(τ):
            let map = TimeMap(sequence: sequence)
            guard τ > 0 else { return edge(0, in: sequence, playhead: .after) }
            guard τ < map.duration, let shown = map.source(atOutput: τ) else {
                return edge(sequence.count, in: sequence, playhead: .before)
            }
            let (k, x) = (shown.clip, shown.source)
            let frame = SequenceCommands.oneFrame(of: doc)
            let (start, end) = extent(k, in: map)
            // Less than a frame from an edge: at the nearer one, without a split.
            if τ - start < frame || end - τ < frame {
                return τ - start <= end - τ ? edge(k, in: sequence, playhead: .after) : edge(k + 1, in: sequence, playhead: .before)
            }
            let original = sequence[k]
            guard original.content == nil else { return nil }
            var (head, tail) = (SequenceCommands.written(original), SequenceCommands.written(original))
            head.end = x
            tail.start = x
            // The source the output rounds to can leave a piece of less than a frame a frame from an edge.
            guard SequenceCommands.lasts(head, frame) else { return edge(k, in: sequence, playhead: .after) }
            guard SequenceCommands.lasts(tail, frame) else { return edge(k + 1, in: sequence, playhead: .before) }
            return Insertion(index: k + 1, take: original.take, point: x, split: k)
        }
    }

    /// A point at the edge before clip `index` of `sequence` (after the last one at its count), with the playhead in the
    /// clip on `playhead`'s side of it: of the stretch of a take on that side (the start of the one after, the end of the
    /// one before), or else on the other side; with clips with content on both sides, or one at an end, of that clip's
    /// point, on the playhead's side first. Each keeps the take in order: a stretch's start is at or after the end of
    /// every clip of its take before it, and its end at or before the start of every one after it.
    private static func edge(_ index: Int, in sequence: [Clip], playhead: Side) -> Insertion? {
        let before = index > 0 ? sequence[index - 1] : nil
        let after = index < sequence.count ? sequence[index] : nil
        let near = playhead == .after ? [(after, Side.after), (before, .before)] : [(before, .before), (after, .after)]
        let sides = near.compactMap { clip, side in clip.map { ($0, side) } }
        let (clip, side) = sides.first { $0.0.content == nil } ?? sides[0]
        // A stretch read as `TimeMap` reads it: an end before its start is its start; a clip with content is its point.
        let point = side == .before && clip.content == nil ? max(clip.start, clip.end) : clip.start
        return Insertion(index: index, take: clip.take, point: point, split: nil)
    }

    /// The output clip `k` of `map` takes, `[O_k, O_k + D_k)`.
    private static func extent(_ k: Int, in map: TimeMap) -> (start: Int64, end: Int64) {
        let start = map.clipOutputStarts[k]
        return (start, k + 1 < map.clipOutputStarts.count ? map.clipOutputStarts[k + 1] : map.duration)
    }

    /// The step that replaces the content of clip `clipID` with what `edit` makes of it, labelled `.clipContent`; `nil`
    /// for no such clip, a stretch of a take, or content `edit` leaves as it is.
    private static func change(_ doc: EditDocument, clipID: String, _ edit: (inout ClipContent) -> Void) -> EditStep? {
        guard let original = doc.sequence.first(where: { $0.id == clipID }), var content = original.content else { return nil }
        edit(&content)
        guard content != original.content else { return nil }
        var clip = original
        clip.content = content
        var changes = SequenceChanges(doc.sequence)
        changes.replace(original, with: clip)
        return EditStep(label: .clipContent, target: clipID, changes: changes.changes)
    }

    /// `round((to − from) × speed)`: the ns of the file a move of the output from `from` to `to` is, saturating.
    private static func fileOffset(_ to: Int64, from: Int64, speed: Double) -> Int64 {
        let moved = ((Double(to) - Double(from)) * speed).rounded()
        // `Double(Int64.max)` is 2⁶³, one past it.
        if moved >= Double(Int64.max) { return .max }
        if moved <= Double(Int64.min) { return .min }
        return Int64(moved)
    }

    /// `a + b`, saturating.
    private static func adding(_ a: Int64, _ b: Int64) -> Int64 {
        let (sum, overflow) = a.addingReportingOverflow(b)
        return overflow ? (b < 0 ? .min : .max) : sum
    }

    /// The fewest ns of a file that last at least `frame` of output at `speed`, as `ClipContent.outputDuration` rounds
    /// them.
    private static func shortestMedia(lasting frame: Int64, speed: Double) -> Int64 {
        func lasts(_ length: Int64) -> Bool {
            ClipContent.media(MediaClip(asset: "", start: 0, end: length, speed: speed)).outputDuration >= frame
        }
        // `round(L / v) ≥ frame` from `L ≥ (frame − ½) × v` on; the steps only correct the `Double`'s rounding.
        var length = max(1, Int64(((Double(frame) - 0.5) * speed).rounded(.up)))
        while !lasts(length) { length += 1 }
        while length > 1, lasts(length - 1) { length -= 1 }
        return length
    }
}
