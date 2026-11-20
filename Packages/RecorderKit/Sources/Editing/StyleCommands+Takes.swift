// SPDX-License-Identifier: GPL-3.0-or-later
import Analysis
import ProjectFormat

/// "Apply Default Style" and "Apply" a named style over every take the sequence shows (phase 3 design §8.1 and §9, 3d
/// plan decision 17): the style is the project's, so the values are the ones a style of one take writes; what depends
/// on the takes is worked out from all of them. With one take, the step of `applyDefaultStyle(_:_:take:events:)` and
/// `applyStyle(_:_:take:events:)`.
///
/// - The cursor is drawn from the recorded images (`CursorLook.system`) if any of the takes recorded them: a take
///   without them draws Toma's arrow either way.
/// - The untouched automatic blocks of every take are planned again for the document so styled
///   (`ZoomCommands.replanned(_:takes:)`, each take on the output's stage).
/// - The corners are the style's, as with one take (1c design §8: "Apply" copies the style's values): they never grow to
///   cover a window's black ones, which only a new document and a take new in it do (`NewDocument`, `TakeCommands`).
extension StyleCommands {
    /// "Apply Default Style" over `takes`, the takes the sequence shows with their events (`LoadedProject.takesShown(by:)`),
    /// as the type says: `.applyDefaultStyle`, `/style`. `nil` if the document has all of it already, or a value cannot
    /// be encoded.
    public static func applyDefaultStyle(
        _ doc: EditDocument, _ style: DefaultStyle, takes: [(TakeRecord, [InputEvent])]
    ) -> EditStep? {
        changes(doc, look: style, camera: nil, takes: takes).step(label: .applyDefaultStyle, target: "/style")
    }

    /// "Apply" the named style `style` over `takes`, as the type says: `.styleApply`, the style's id. `nil` if the document
    /// has all of it already, or a value cannot be encoded.
    public static func applyStyle(_ doc: EditDocument, _ style: NamedStyle, takes: [(TakeRecord, [InputEvent])]) -> EditStep? {
        changes(doc, look: style.look, camera: style.camera, takes: takes).step(label: .styleApply, target: style.id)
    }

    private static func changes(
        _ doc: EditDocument, look: DefaultStyle, camera: CameraLook?, takes: [(TakeRecord, [InputEvent])]
    ) -> DocumentChanges {
        changes(doc, look: look, camera: camera, recordedImages: takes.contains { hasCursorImages($0.1) }) { styled in
            ZoomCommands.replanned(styled, takes: takes)
        }
    }
}
