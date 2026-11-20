// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import ProjectFormat

/// The commands of the project's title and summary (`EditDocument.info`, fases 4 y 5 design §4.1): each is one undoable
/// step that sets `/info` whole, with its label and `/info` as the target, so typing in one field is one undo group.
/// Each text is trimmed of spaces and line breaks at both ends and held to its limit (`ProjectInfo.titleLimit`,
/// `summaryLimit`), so a step never leaves a `DocumentProblem`. An empty title and an empty summary take `info` away,
/// back to the legacy document's `nil`. `nil` if nothing changes.
public enum InfoCommands {
    /// The project's title set to `title`, its summary kept.
    public static func setTitle(_ doc: EditDocument, _ title: String) -> EditStep? {
        let title = normalized(title, limit: ProjectInfo.titleLimit)
        return step(doc, ProjectInfo(title: title, summary: doc.info?.summary ?? ""), label: .projectTitle)
    }

    /// The project's summary set to `summary`, its title kept.
    public static func setSummary(_ doc: EditDocument, _ summary: String) -> EditStep? {
        let summary = normalized(summary, limit: ProjectInfo.summaryLimit)
        return step(doc, ProjectInfo(title: doc.info?.title ?? "", summary: summary), label: .projectSummary)
    }

    /// `text` without spaces and line breaks at its ends, and at most `limit` characters.
    private static func normalized(_ text: String, limit: Int) -> String {
        String(text.trimmingCharacters(in: .whitespacesAndNewlines).prefix(limit))
    }

    private static let target = "/info"

    /// The step that makes `doc`'s `info` be `info`, or `nil` when both its texts are empty; `nil` if that is what it is.
    private static func step(_ doc: EditDocument, _ info: ProjectInfo, label: EditLabel) -> EditStep? {
        let next: ProjectInfo? = info.title.isEmpty && info.summary.isEmpty ? nil : info
        guard next != doc.info, let change = doc.setChange(target, next) else { return nil }
        return EditStep(label: label, target: target, changes: [change])
    }
}
