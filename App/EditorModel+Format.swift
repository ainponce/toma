// SPDX-License-Identifier: GPL-3.0-or-later
import Analysis
import ProjectFormat

/// The ratio "Like the Recording" (`Aspect.auto`) follows, for every place the app sizes the stage by the format
/// (design §6.4): the preview, the export sheet, the overlay, the camera and timeline tabs.
extension EditorModel {
    /// The ratio of the content of `document`'s take (`StageLayout.contentRatio`: the region of its initial screen at the
    /// start of its first segment, Area crop included), from the take's screens read once; `nil` without one, and while
    /// the editor has not read them yet.
    func contentRatio(of document: EditDocument) -> Double? {
        guard let take = panelSession?.project.take, let screens = takeScreens else { return nil }
        return screens.contentRatio(take: take, document: document)
    }

    /// Width over height of the preview: the document's format, and for "Like the Recording" the content's.
    var previewRatio: Double {
        guard let document else { return previewAspect.ratio }
        return document.aspect.ratio(contentRatio: contentRatio(of: document))
    }
}
