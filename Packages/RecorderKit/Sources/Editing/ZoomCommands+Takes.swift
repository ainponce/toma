// SPDX-License-Identifier: GPL-3.0-or-later
import Analysis
import ProjectFormat

/// The automatic zoom of every take the sequence shows (phase 3 design §8.1, 3d plan decision 17): each take's blocks
/// are planned from its own events (`AutoZoomPlanner`), and none of them throws away another's. Every take's stage is
/// the output's (design §9): a take that is not the one of the first clip is planned with the ratio `auto` follows, that
/// of the first clip's take (`StageLayout.contentRatio(project:document:)`), its screens fitted inside it. With one take,
/// what `regenerate(_:take:events:settings:)` and `replanned(_:take:events:)` do.
extension ZoomCommands {
    /// "Regenerate Zooms" over every take of `takes`, the takes the sequence shows with their events
    /// (`LoadedProject.takesShown(by:)`, in that order): one step, `/zoom/auto` set to `settings` and the untouched
    /// automatic blocks of each take planned again (`replanned(_:takes:)`), the user's blocks, the suppressed ranges and
    /// the blocks of a take not in `takes` left alone; with `enabled` off, those of every take of `takes` go. Without
    /// anything to change, the step has no changes. With one take, `regenerate(_:take:events:settings:)`'s step.
    public static func regenerate(
        _ doc: EditDocument, takes: [(TakeRecord, [InputEvent])], settings: AutoZoomSettings
    ) -> EditStep {
        var planned = doc
        planned.zoom.auto = settings
        var changes = DocumentChanges()
        changes.set(["zoom", "auto"], from: doc.zoom.auto, to: settings)
        changes.edit(.zoomRegions, from: doc.zoom.regions, to: replanned(planned, takes: takes), id: \.id)
        return changes.stepEvenIfEmpty(label: .zoomRegenerate, target: "/zoom/auto")
    }

    /// The blocks of `doc` with the untouched automatic ones of each of `takes` planned again: `replanned(_:take:events:)`
    /// of each in turn (a take listed twice, once), each over the blocks the ones before it left, the first clip's take
    /// on its own stage and every other one with the ratio of that take's (`.some(nil)`, 16:9, when `takes` does not
    /// have it). What `regenerate(_:takes:settings:)` and `StyleCommands`' versions of every take write.
    static func replanned(_ doc: EditDocument, takes: [(TakeRecord, [InputEvent])]) -> [ZoomRegion] {
        let first = doc.sequence.first?.take
        // Worked out once a take other than the first clip's needs it.
        var ratio: Double??
        var planned = doc
        var done: Set<String> = []
        for (take, events) in takes where done.insert(take.id).inserted {
            if take.id != first, ratio == nil {
                let shown = takes.first { $0.0.id == first }
                ratio = .some(shown.flatMap { StageLayout.contentRatio(take: $0.0, document: doc, events: $0.1) })
            }
            planned.zoom.regions = replanned(planned, take: take, events: events, contentRatio: take.id == first ? nil : ratio)
        }
        return planned.zoom.regions
    }
}
