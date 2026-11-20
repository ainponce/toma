// SPDX-License-Identifier: GPL-3.0-or-later
import Analysis
import AppSupport
import Editing
import ProjectFormat

/// What the editor does with the annotations from the timeline (phase 3 design §5.6, plan 3a Task A12): the selection,
/// Delete, Duplicate and the order of the layers (the Annotations track's menu and its keys). Each is one step of
/// `AnnotationCommands`.
extension EditorModel {
    /// Annotation `id` is the one selected; with `showingIt`, the playhead goes into it (a double click on the track), so
    /// the preview shows it: where it already is if the output shows the annotation there, else the first frame of the grid
    /// once it is all in (its entrance over, `AnnotationTiming.transition` or half of it if it is shorter), inside it.
    func selectAnnotation(_ id: String, showingIt: Bool) {
        selection = .annotations([id])
        guard showingIt, let document, let annotation = document.annotations.items.first(where: { $0.id == id }),
            let output = TimelineAnnotationItems.range(of: id, in: document)
        else { return }
        let map = TimeMap(sequence: document.sequence)
        let playhead = playheadNanoseconds
        if output.contains(playhead), AnnotationTiming.state(of: annotation, atOutput: playhead, document: document, timeMap: map) != nil {
            return
        }
        let rate = document.frameRate
        func firstFrame(atOrAfter τ: Int64) -> Int {
            var frame = Int((Double(τ) * Double(rate) / 1e9).rounded(.up))
            while Int64(TimeMap.frameTime(frame, frameRate: rate)) < τ { frame += 1 }
            return frame
        }
        let length = output.upperBound - output.lowerBound
        let shown = output.lowerBound + min(AnnotationTiming.transition, length / 2)
        var frame = firstFrame(atOrAfter: shown)
        if Int64(TimeMap.frameTime(frame, frameRate: rate)) >= output.upperBound { frame = firstFrame(atOrAfter: output.lowerBound) }
        seek(frame: frame)
    }

    /// Deletes the annotations selected, in one step (⌫ and the track's menu).
    func deleteSelectedAnnotations() {
        guard case .annotations? = selection else { return }
        deleteSelection()
    }

    /// Duplicates the annotations selected, in one step: the copies are the ones selected then.
    func duplicateSelectedAnnotations() {
        guard canEdit, let document, case let .annotations(ids)? = selection,
            let step = AnnotationCommands.duplicate(document, ids: ids, makeID: Self.newID), perform(step) != .refused
        else { return }
        selection = .annotations(Set(step.target.split(separator: ",").map(String.init)))
    }

    /// Moves the one annotation selected in the order of its group (Bring Forward, Send Backward, Bring to Front, Send to
    /// Back); nothing with none or several.
    func reorderSelectedAnnotation(_ move: AnnotationCommands.LayerMove) {
        guard canEdit, let document, case let .annotations(ids)? = selection, ids.count == 1, let id = ids.first,
            let step = AnnotationCommands.reorder(document, id: id, move)
        else { return }
        perform(step)
    }
}
