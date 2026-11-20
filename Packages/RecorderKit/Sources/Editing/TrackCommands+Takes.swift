// SPDX-License-Identifier: GPL-3.0-or-later
import Analysis
import ProjectFormat

/// "Follow the Cursor" over every take the sequence shows (phase 3 design §8.1, 3d plan decision 17).
extension TrackCommands {
    /// "Follow the Cursor" (design §5.5 and §8.7) for each of `projects`, the project focused on each take the sequence
    /// shows (`LoadedProject.takesShown(by:)`), in turn: each take's automatic screen changes planned again from its own
    /// events in the document's output, with its planner's initial screen, around its user's changes, as
    /// `followCursor(_:project:)` plans one take (a take listed twice, once); the changes of a take not in `projects`
    /// stay. The planner's name, with two or more screens in any of them. One `set` of `/screens`; without anything to
    /// change, the step has no changes. With one take, `followCursor(_:project:)`'s step. Reads each take's events (the
    /// disk, the first time): never on the main thread.
    public static func followCursor(_ doc: EditDocument, projects: [LoadedProject]) -> EditStep {
        let timeMap = TimeMap(sequence: doc.sequence)
        var screens = doc.screens
        var done: Set<String> = []
        for project in projects where done.insert(project.take.id).inserted {
            screens = followed(screens, project: project, timeMap: timeMap)
        }
        var changes = DocumentChanges()
        changes.set(["screens"], from: doc.screens, to: screens)
        return changes.stepEvenIfEmpty(label: .screen, target: "/screens")
    }
}
