// SPDX-License-Identifier: GPL-3.0-or-later
import Analysis
import ProjectFormat

/// The ratio "Like the Recording" (`Aspect.auto`) follows, for every place the app sizes the stage by the format
/// (design §6.4): the preview, the export sheet, the overlay, the camera and timeline tabs.
extension EditorModel {
    /// The ratio of the content of the take of `document`'s first clip (`StageLayout.contentRatio(project:document:)`, the
    /// one rule of the preview, the MP4 and the GIF: the region of its initial screen at the start of its first segment,
    /// Area crop included), from the takes' screens read once (`TakeScreens.contentRatio(of:takes:ownTake:screens:)`);
    /// `nil` without one, and while the editor has not read them yet.
    func contentRatio(of document: EditDocument) -> Double? {
        guard let project = panelSession?.project else { return nil }
        return TakeScreens.contentRatio(of: document, takes: project.takes, ownTake: project.take.id, screens: screensByTake)
    }

    /// Width over height of the preview: the document's format, and for "Like the Recording" the content's.
    var previewRatio: Double {
        guard let document else { return previewAspect.ratio }
        return document.aspect.ratio(contentRatio: contentRatio(of: document))
    }
}
