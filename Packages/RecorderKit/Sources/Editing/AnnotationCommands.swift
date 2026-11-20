// SPDX-License-Identifier: GPL-3.0-or-later
import Analysis
import Foundation
import ProjectFormat
import simd

/// The commands of the annotations (phase 3 plan 3a, decisions 7 and 8; design §5.1 and §5.5), as pure functions of the
/// document, in the manner of `PrivacyCommands`: each gives the step that does it, or `nil` when there is nothing to do.
///
/// - An annotation anchored to the take is kept in source time and edited in output time (`OutputBlockTrack`); as a
///   privacy block it may overlap the others, so a move or a trim never stops at another. One of the output is edited in
///   output nanoseconds, held to `[0, D]`; one of the whole video neither moves nor trims.
/// - Every change of one annotation is a single `.replace` of the whole annotation. What a command writes is held to what
///   the document allows (sizes, widths, curve, opacity, rotation, `.draw` only on an arrow or a shape) and a command
///   gives `nil` rather than a document `DocumentRules` refuses or a value that is not a number.
/// - The `target` of a step is the id of the annotation (several, in the order of the document, joined by commas).
public enum AnnotationCommands {
    /// The shortest annotation made or trimmed by hand: 0.3 s of output.
    public static let minimumDuration: Int64 = 300_000_000
    /// An annotation made from the playhead: 3 s of output.
    public static let defaultDuration: Int64 = 3_000_000_000
    /// How far a duplicate is moved, in x and in y, in fractions of its space.
    public static let duplicateOffset = 0.02

    public enum LayerMove: Sendable { case forward, backward, front, back }
    public enum AnchorChoice: Sendable { case recording, output, whole }

    // MARK: Add, duplicate, delete

    /// Makes an annotation of `kind` over `rect` (held where its anchor lets it be) from output instant `atOutput`,
    /// `duration` long (3 s; a clip, its file's length at most), cut where the output ends. At the playhead over a stretch
    /// of a take it is anchored to the take, cut where that take's run of clips stops or a clip with content starts (as a
    /// privacy block); anywhere else, and always a clip, to the output. Its id is `makeID("a-")`, its `layer` one more than
    /// the highest of its group. `nil` with less than `minimumDuration` left there or a value that is not a number.
    public static func add(
        _ doc: EditDocument, _ kind: AnnotationKind, atOutput: Int64, rect: NormalizedRect, duration: Int64? = nil,
        makeID: (String) -> String
    ) -> EditStep? {
        let map = TimeMap(sequence: doc.sequence)
        let start = max(atOutput, 0)
        guard start < map.duration, let shown = map.source(atOutput: start), doc.sequence.indices.contains(shown.clip) else { return nil }
        var length = duration ?? defaultDuration
        var isClip = false
        if case let .clip(clip) = kind {
            guard clip.end > clip.start, clip.end &- clip.start > 0 else { return nil }
            length = min(duration ?? (clip.end - clip.start), clip.end - clip.start)
            isClip = true
        }
        guard length > 0 else { return nil }
        let (sum, overflow) = start.addingReportingOverflow(length)
        var end = min(overflow ? .max : sum, map.duration)
        var anchor = AnnotationAnchor.output(start: start, end: end)
        if !isClip, doc.sequence[shown.clip].content == nil {
            let take = doc.sequence[shown.clip].take
            var last = shown.clip
            while last + 1 < doc.sequence.count, doc.sequence[last + 1].take == take, doc.sequence[last + 1].content == nil { last += 1 }
            let takeEnd = last + 1 < map.clipOutputStarts.count ? map.clipOutputStarts[last + 1] : map.duration
            end = min(end, takeEnd)
            guard end - start >= minimumDuration, let source = track(doc, outputs: []).source(of: start..<end) else { return nil }
            anchor = .content(take: source.take, start: source.start, end: source.end)
        }
        guard end - start >= minimumDuration else { return nil }
        var ids = Set(doc.annotations.items.map(\.id))
        let group = groupIndex(anchor)
        let top = doc.annotations.items.filter { groupIndex($0.anchor) == group }.map(\.layer).max() ?? 0
        let annotation = Annotation(
            id: DocumentIDs.new("a-", makeID, avoiding: &ids), anchor: anchor, layer: top + 1, kind: kind,
            rect: held(rect, anchor))
        guard [rect.x, rect.y, rect.width, rect.height].allSatisfy(\.isFinite), let clean = sanitized(annotation) else { return nil }
        var changes = DocumentChanges()
        changes.insert(clean, into: .annotations, at: doc.annotations.items.count)
        return finish(doc, changes, label: .annotationAdd, target: clean.id)
    }

    /// Duplicates the annotations `ids`, in one step: each moved `duplicateOffset` in x and y (held where its anchor lets
    /// it be), with the same time and a new id (`makeID("a-")`), above all of its group, those of one group in the order
    /// they had. `nil` with none.
    public static func duplicate(_ doc: EditDocument, ids: Set<String>, makeID: (String) -> String) -> EditStep? {
        var taken = Set(doc.annotations.items.map(\.id))
        var tops = [Int?](repeating: nil, count: 2)
        for item in doc.annotations.items {
            let g = groupIndex(item.anchor)
            tops[g] = max(tops[g] ?? item.layer, item.layer)
        }
        let chosen = doc.annotations.items.enumerated().filter { ids.contains($0.element.id) }
            .sorted { ($0.element.layer, $0.offset) < ($1.element.layer, $1.offset) }
        var copies: [(offset: Int, annotation: Annotation)] = []
        for (offset, item) in chosen {
            let g = groupIndex(item.anchor)
            var copy = item
            copy.id = DocumentIDs.new("a-", makeID, avoiding: &taken)
            copy.layer = (tops[g] ?? 0) + 1
            tops[g] = copy.layer
            guard let moved = shifted(copy, dx: duplicateOffset, dy: duplicateOffset), let clean = sanitized(moved) else { return nil }
            copies.append((offset, clean))
        }
        guard !copies.isEmpty else { return nil }
        var changes = DocumentChanges()
        for (n, entry) in copies.enumerated() { changes.insert(entry.annotation, into: .annotations, at: doc.annotations.items.count + n) }
        let ordered = copies.sorted { $0.offset < $1.offset }.map(\.annotation.id)
        return finish(doc, changes, label: .annotationAdd, target: ordered.joined(separator: ","))
    }

    /// Deletes the annotations with the ids `ids`; ids of none are left out, `nil` with none.
    public static func delete(_ doc: EditDocument, ids: Set<String>) -> EditStep? {
        var changes = DocumentChanges()
        var removed: [String] = []
        for (k, item) in doc.annotations.items.enumerated() where ids.contains(item.id) {
            changes.remove(item, from: .annotations, at: k - removed.count)
            removed.append(item.id)
        }
        return changes.step(label: .annotationDelete, target: removed.joined(separator: ","))
    }

    // MARK: Time

    /// Moves annotation `id` so its output range starts at `toOutputStart`, its length kept: one of the take through the
    /// source (it crosses a cut, never stops at another annotation), one of the output held to `[0, D]`. `nil` if it stays
    /// where it is, if it shows nothing, for the whole video, or if there is no such annotation.
    public static func move(_ doc: EditDocument, id: String, toOutputStart: Int64) -> EditStep? {
        guard let k = doc.annotations.items.firstIndex(where: { $0.id == id }) else { return nil }
        var item = doc.annotations.items[k]
        let map = TimeMap(sequence: doc.sequence)
        switch item.anchor {
        case .whole:
            return nil
        case let .output(start, end):
            let length = end - start
            guard length > 0 else { return nil }
            let latest = max(map.duration - length, 0)
            let to = min(max(toOutputStart, 0), latest)
            guard to != start else { return nil }
            item.anchor = .output(start: to, end: to + length)
        case .content:
            guard let output = AnnotationTiming.outputRange(of: item, document: doc, timeMap: map), !output.isEmpty,
                let source = track(doc, outputs: [output]).moved(0, toOutputStart: toOutputStart)
            else { return nil }
            item.anchor = .content(take: source.take, start: source.start, end: source.end)
        }
        return replace(doc, k, item, label: .annotationMove)
    }

    /// Moves `edge` of annotation `id` to output instant `toOutput`, leaving it at least `minimumDuration` long (a shorter
    /// one only grows); the other edge keeps its instant. One of the take is kept in the source; a clip is not stretched
    /// past its file, and trimming its start keeps each of its frames at the same output instant. `nil` if the edge stays,
    /// for the whole video, if it shows nothing or if there is no such annotation.
    public static func trim(_ doc: EditDocument, id: String, edge: ClipEdge, toOutput: Int64) -> EditStep? {
        guard let k = doc.annotations.items.firstIndex(where: { $0.id == id }) else { return nil }
        var item = doc.annotations.items[k]
        let map = TimeMap(sequence: doc.sequence)
        switch item.anchor {
        case .whole:
            return nil
        case let .output(start, end):
            guard end > start else { return nil }
            var clip: ClipAnnotation?
            if case let .clip(c) = item.kind { clip = c }
            switch edge {
            case .start:
                let latest = max(end - minimumDuration, start)
                var earliest: Int64 = 0
                if let clip { earliest = max(0, start - max(clip.start, 0)) }
                let lower = min(max(toOutput, min(earliest, latest)), latest)
                guard lower != start else { return nil }
                item.anchor = .output(start: lower, end: end)
                if var moved = clip {
                    moved.start += lower - start
                    item.kind = .clip(moved)
                }
            case .end:
                let earliest = min(start + minimumDuration, end)
                var latest = map.duration
                if let clip { latest = min(latest, start + (clip.end - clip.start)) }
                let upper = max(min(toOutput, latest), earliest)
                guard upper != end else { return nil }
                item.anchor = .output(start: start, end: upper)
            }
        case let .content(take, start, end):
            guard let output = AnnotationTiming.outputRange(of: item, document: doc, timeMap: map), !output.isEmpty,
                let trimmed = track(doc, outputs: [output]).trimmed(
                    0, SourceRange(take: take, start: start, end: end), edge: edge, toOutput: toOutput, minimum: minimumDuration)
            else { return nil }
            item.anchor = .content(take: take, start: trimmed.start, end: trimmed.end)
        }
        return replace(doc, k, item, label: .annotationTrim)
    }

    // MARK: Look and place

    /// Changes annotation `id` as `edit` does, held to what the document allows (size 0.01…0.5, widths 0.001…0.1, `curve`
    /// −1…1, opacity 0…1, rotation −180…180°, corners 0…0.5, a rect where its anchor lets it be; `.draw` only on an arrow
    /// or a shape, else `.fade`). Its id and its anchor are not changed here (`setAnchor`, `move`, `trim`). `nil` if
    /// nothing changes, if a value is not a number, if there is no such annotation or the result is not a valid one.
    public static func change(_ doc: EditDocument, id: String, _ edit: (inout Annotation) -> Void) -> EditStep? {
        guard let k = doc.annotations.items.firstIndex(where: { $0.id == id }) else { return nil }
        let old = doc.annotations.items[k]
        var item = old
        edit(&item)
        (item.id, item.anchor) = (old.id, old.anchor)
        return replace(doc, k, item, label: .annotationChange)
    }

    /// Puts annotation `id` at `rect` (held where its anchor lets it be) with the points and size it is given: `from` and
    /// `to` of an arrow (its rect then comes from them, `AnnotationGeometry.arrowRect`; with neither, the arrow moves with
    /// the rect), `target` of a speech bubble and `size` of a text or a speech bubble's text. `label` says whether it was
    /// the body that moved (`.annotationMove`) or a handle (`.annotationChange`). `nil` if nothing changes, if a value is
    /// not a number or if there is no such annotation.
    public static func place(
        _ doc: EditDocument, id: String, rect: NormalizedRect, from: NormalizedPoint? = nil, to: NormalizedPoint? = nil,
        target: NormalizedPoint? = nil, size: Double? = nil, label: EditLabel
    ) -> EditStep? {
        guard let k = doc.annotations.items.firstIndex(where: { $0.id == id }) else { return nil }
        let old = doc.annotations.items[k]
        guard let item = placed(old, rect: rect, from: from, to: to, target: target, size: size) else { return nil }
        return replace(doc, k, item, label: label)
    }

    /// Moves the annotations of `deltas` (by id, in fractions of their space, x and y) in one step, each held where its
    /// anchor lets it be, with what it points at (an arrow's ends, a speech bubble's point) by what its rect really moved.
    /// `nil` if nothing moves or a delta is not a number.
    public static func nudge(_ doc: EditDocument, by deltas: [String: SIMD2<Double>]) -> EditStep? {
        var changes = DocumentChanges()
        var targets: [String] = []
        for old in doc.annotations.items {
            guard let delta = deltas[old.id] else { continue }
            guard delta.x.isFinite, delta.y.isFinite else { return nil }
            guard let item = shifted(old, dx: delta.x, dy: delta.y), let clean = sanitized(item) else { return nil }
            guard clean != old else { continue }
            changes.replace(old, with: clean, in: .annotations, id: old.id)
            targets.append(old.id)
        }
        return finish(doc, changes, label: .annotationMove, target: targets.joined(separator: ","))
    }

    /// Anchors annotation `id` as `choice` says, keeping its time and taking the geometry the app gives (where it is seen
    /// now, in the space of the new anchor): to the recording, the source of its output range, only if that falls in one run
    /// of one take (not over a clip with content or two takes); to the output, the output range it has now; to the whole
    /// video, `[0, D)`. A clip does not go to the recording. `nil` if it cannot, if nothing changes, if a value is not a
    /// number or if there is no such annotation.
    public static func setAnchor(
        _ doc: EditDocument, id: String, to choice: AnchorChoice, rect: NormalizedRect, from: NormalizedPoint? = nil,
        to: NormalizedPoint? = nil, target: NormalizedPoint? = nil
    ) -> EditStep? {
        guard let k = doc.annotations.items.firstIndex(where: { $0.id == id }) else { return nil }
        var item = doc.annotations.items[k]
        let map = TimeMap(sequence: doc.sequence)
        switch choice {
        case .whole:
            item.anchor = .whole
        case .output, .recording:
            guard let range = AnnotationTiming.outputRange(of: item, document: doc, timeMap: map), !range.isEmpty else { return nil }
            if choice == .output {
                item.anchor = .output(start: range.lowerBound, end: range.upperBound)
            } else {
                if case .clip = item.kind { return nil }
                if case .content = item.anchor {
                    break
                }
                guard singleRun(of: range, in: doc, map: map),
                    let source = track(doc, outputs: []).source(of: range)
                else { return nil }
                item.anchor = .content(take: source.take, start: source.start, end: source.end)
            }
        }
        guard let placed = placed(item, rect: rect, from: from, to: to, target: target, size: nil) else { return nil }
        return replace(doc, k, placed, label: .annotationChange)
    }

    // MARK: Layers

    /// Moves annotation `id` in the order of its group (the ones anchored to the take, or those of the output and the whole
    /// video; by `layer` and then by the order of the document): forward or backward, past the next or the previous of
    /// those that show at the same time as it (their output ranges meet); front or back, above or below all of the group.
    /// One step, a `.replace` for each annotation whose `layer` changes. `nil` if it is already there or if there is no
    /// such annotation.
    public static func reorder(_ doc: EditDocument, id: String, _ move: LayerMove) -> EditStep? {
        let items = doc.annotations.items
        guard let me = items.firstIndex(where: { $0.id == id }) else { return nil }
        let group = groupIndex(items[me].anchor)
        let order = items.indices.filter { groupIndex(items[$0].anchor) == group }.sorted { (items[$0].layer, $0) < (items[$1].layer, $1) }
        guard let position = order.firstIndex(of: me) else { return nil }
        var layers: [Int: Int] = [:]
        switch move {
        case .front:
            guard position != order.count - 1, let top = order.map({ items[$0].layer }).max() else { return nil }
            layers[me] = top == Int.max ? top : top + 1
        case .back:
            guard position != 0, let bottom = order.map({ items[$0].layer }).min() else { return nil }
            layers[me] = bottom == Int.min ? bottom : bottom - 1
        case .forward, .backward:
            let map = TimeMap(sequence: doc.sequence)
            let ranges = items.map { AnnotationTiming.outputRange(of: $0, document: doc, timeMap: map) }
            guard let mine = ranges[me], !mine.isEmpty else { return nil }
            func meets(_ j: Int) -> Bool {
                guard let other = ranges[j], !other.isEmpty else { return false }
                return other.overlaps(mine)
            }
            var arranged = order
            if move == .forward {
                guard let next = order[(position + 1)...].firstIndex(where: meets) else { return nil }
                arranged.remove(at: position)
                arranged.insert(me, at: next)
            } else {
                guard let previous = order[..<position].lastIndex(where: meets) else { return nil }
                arranged.remove(at: position)
                arranged.insert(me, at: previous)
            }
            // The layers the group had, in order, go to the new order; where two are the same and the document's order
            // would flip them, the later one goes one up (and what is above it with it).
            let pool = order.map { items[$0].layer }
            var previousSlot: (layer: Int, index: Int)?
            for (slot, j) in arranged.enumerated() {
                var layer = pool[slot]
                if let previousSlot, (layer, j) <= (previousSlot.layer, previousSlot.index) {
                    guard previousSlot.layer < Int.max else { return nil }
                    layer = j > previousSlot.index ? previousSlot.layer : previousSlot.layer + 1
                }
                if layer != items[j].layer { layers[j] = layer }
                previousSlot = (layer, j)
            }
        }
        var changes = DocumentChanges()
        for (j, layer) in layers.sorted(by: { $0.key < $1.key }) {
            var updated = items[j]
            updated.layer = layer
            changes.replace(items[j], with: updated, in: .annotations, id: items[j].id)
        }
        return finish(doc, changes, label: .annotationLayer, target: id)
    }

    // MARK: Reading

    /// The annotations the output shows at output instant `atOutput` (`AnnotationTiming.state` is not `nil`), the topmost
    /// first: those of the output and the whole video above those of the take, each by `layer` and then by the order of
    /// the document, the later first.
    public static func shown(atOutput: Int64, in doc: EditDocument) -> [Annotation] {
        let map = TimeMap(sequence: doc.sequence)
        let visible = doc.annotations.items.enumerated().filter {
            AnnotationTiming.state(of: $0.element, atOutput: atOutput, document: doc, timeMap: map) != nil
        }
        return visible.sorted {
            let (a, b) = ($0.element, $1.element)
            let (ga, gb) = (groupIndex(a.anchor), groupIndex(b.anchor))
            if ga != gb { return ga > gb }
            return (a.layer, $0.offset) > (b.layer, $1.offset)
        }.map(\.element)
    }

    // MARK: Private

    /// `rect` where `anchor` lets it be (`AnnotationGeometry.clamped`), the same rect when it already is (the centring of an
    /// output rect would otherwise change its last bits each time).
    private static func held(_ rect: NormalizedRect, _ anchor: AnnotationAnchor) -> NormalizedRect {
        let clamped = AnnotationGeometry.clamped(rect, anchor: anchor)
        let close =
            abs(clamped.x - rect.x) < 1e-12 && abs(clamped.y - rect.y) < 1e-12 && abs(clamped.width - rect.width) < 1e-12
            && abs(clamped.height - rect.height) < 1e-12
        return close ? rect : clamped
    }

    /// 0 for the annotations anchored to the take, 1 for the others.
    private static func groupIndex(_ anchor: AnnotationAnchor) -> Int {
        if case .content = anchor { return 0 }
        return 1
    }

    /// Whether every clip of the output over `range` is of one take and has no content.
    private static func singleRun(of range: Range<Int64>, in doc: EditDocument, map: TimeMap) -> Bool {
        var take: String?
        for (k, clip) in doc.sequence.enumerated() where k < map.clipOutputStarts.count {
            let start = map.clipOutputStarts[k]
            let end = k + 1 < map.clipOutputStarts.count ? map.clipOutputStarts[k + 1] : map.duration
            guard start < range.upperBound, end > range.lowerBound else { continue }
            guard clip.content == nil, take == nil || take == clip.take else { return false }
            take = clip.take
        }
        return take != nil
    }

    private static func track(_ doc: EditDocument, outputs: [Range<Int64>?]) -> OutputBlockTrack {
        OutputBlockTrack(sequence: doc.sequence, map: TimeMap(sequence: doc.sequence), outputs: outputs)
    }

    private static func replace(_ doc: EditDocument, _ k: Int, _ item: Annotation, label: EditLabel) -> EditStep? {
        let old = doc.annotations.items[k]
        guard let clean = sanitized(item) else { return nil }
        var changes = DocumentChanges()
        changes.replace(old, with: clean, in: .annotations, id: old.id)
        return finish(doc, changes, label: label, target: old.id)
    }

    /// The step of `changes`, if what it makes is a document no worse than the one before by `DocumentRules`.
    private static func finish(_ doc: EditDocument, _ changes: DocumentChanges, label: EditLabel, target: String) -> EditStep? {
        guard let step = changes.step(label: label, target: target),
            let after: EditDocument = try? doc.applying(step.changes),
            DocumentRules.problems(in: after).count <= DocumentRules.problems(in: doc).count
        else { return nil }
        return step
    }

    /// `old` at `rect` with the given points and size, or `nil` if a value is not a number.
    private static func placed(
        _ old: Annotation, rect: NormalizedRect, from: NormalizedPoint?, to: NormalizedPoint?, target: NormalizedPoint?, size: Double?
    ) -> Annotation? {
        var item = old
        item.rect = held(rect, old.anchor)
        guard [rect.x, rect.y, rect.width, rect.height].allSatisfy(\.isFinite) else { return nil }
        switch item.kind {
        case var .arrow(arrow):
            if from == nil, to == nil, case let .arrow(previous) = old.kind {
                let (dx, dy) = (item.rect.x - old.rect.x, item.rect.y - old.rect.y)
                arrow.from = NormalizedPoint(x: previous.from.x + dx, y: previous.from.y + dy)
                arrow.to = NormalizedPoint(x: previous.to.x + dx, y: previous.to.y + dy)
            }
            if let from { arrow.from = from }
            if let to { arrow.to = to }
            item.kind = .arrow(arrow)
        case var .callout(callout):
            if let target { callout.target = target }
            if let size { callout.text.size = size }
            item.kind = .callout(callout)
        case var .text(text):
            if let size { text.size = size }
            item.kind = .text(text)
        default:
            break
        }
        guard var clean = sanitized(item) else { return nil }
        if case let .arrow(arrow) = clean.kind { clean.rect = AnnotationGeometry.arrowRect(arrow) }
        return clean
    }

    /// `item` moved by (`dx`, `dy`), its rect held where its anchor lets it be and what it points at moved by what the rect
    /// really moved; `nil` if a value is not a number.
    private static func shifted(_ item: Annotation, dx: Double, dy: Double) -> Annotation? {
        guard dx.isFinite, dy.isFinite else { return nil }
        var rect = item.rect
        rect.x += dx
        rect.y += dy
        let kept = held(rect, item.anchor)
        let (mx, my) = (kept.x - item.rect.x, kept.y - item.rect.y)
        var moved = item
        moved.rect = kept
        switch item.kind {
        case var .arrow(arrow):
            arrow.from = NormalizedPoint(x: arrow.from.x + mx, y: arrow.from.y + my)
            arrow.to = NormalizedPoint(x: arrow.to.x + mx, y: arrow.to.y + my)
            moved.kind = .arrow(arrow)
            moved.rect = AnnotationGeometry.arrowRect(arrow)
        case var .callout(callout):
            callout.target = NormalizedPoint(x: callout.target.x + mx, y: callout.target.y + my)
            moved.kind = .callout(callout)
        default:
            break
        }
        return moved
    }

    /// `item` with every number held to what the document allows; `nil` if one is not a number (or a clip has no length).
    private static func sanitized(_ item: Annotation) -> Annotation? {
        func finite(_ values: Double...) -> Bool { values.allSatisfy(\.isFinite) }
        func color(_ c: RGBA?) -> Bool { c.map { finite($0.r, $0.g, $0.b, $0.a) } ?? true }
        func clamp(_ v: Double, _ range: ClosedRange<Double>) -> Double { min(max(v, range.lowerBound), range.upperBound) }
        func text(_ t: TextAnnotation) -> TextAnnotation? {
            guard finite(t.size), color(t.color), color(t.fill) else { return nil }
            var t = t
            t.size = clamp(t.size, 0.01...0.5)
            return t
        }
        guard finite(item.rect.x, item.rect.y, item.rect.width, item.rect.height, item.rotation, item.opacity) else { return nil }
        var out = item
        out.rect = held(item.rect, item.anchor)
        out.rotation = clamp(item.rotation, -180...180)
        out.opacity = clamp(item.opacity, 0...1)
        switch item.kind {
        case let .text(value):
            guard let clean = text(value) else { return nil }
            out.kind = .text(clean)
        case let .arrow(value):
            guard finite(value.from.x, value.from.y, value.to.x, value.to.y, value.curve, value.width), color(value.color) else { return nil }
            var v = value
            v.curve = clamp(v.curve, -1...1)
            v.width = clamp(v.width, 0.001...0.1)
            out.kind = .arrow(v)
        case let .shape(value):
            guard finite(value.width), color(value.stroke), color(value.fill) else { return nil }
            var v = value
            v.width = clamp(v.width, 0.001...0.1)
            out.kind = .shape(v)
        case let .callout(value):
            guard finite(value.target.x, value.target.y), let clean = text(value.text) else { return nil }
            out.kind = .callout(CalloutAnnotation(text: clean, target: value.target))
        case let .step(value):
            guard color(value.color) else { return nil }
        case let .image(value):
            guard finite(value.corner) else { return nil }
            var v = value
            v.corner = clamp(v.corner, 0...0.5)
            out.kind = .image(v)
        case let .clip(value):
            guard finite(value.volume, value.corner), value.start >= 0, value.end > value.start else { return nil }
            var v = value
            v.corner = clamp(v.corner, 0...0.5)
            out.kind = .clip(v)
        }
        if out.enter == .draw {
            switch out.kind {
            case .arrow, .shape: break
            default: out.enter = .fade
            }
        }
        return out
    }
}
