// SPDX-License-Identifier: GPL-3.0-or-later
import ProjectFormat

/// The commands of the camera's look (1c design §13.1, §18): mirror, border and shadow, and the deletion of every change
/// of the bubble, as pure functions of the document. Each gives the step that does it (`EditStep`), or `nil` when nothing
/// changes. The target of each step is the pointer of what it sets, so a burst on one control is one undo group.
public enum CameraLookCommands {
    /// The border's colours, in the order of the colour well (plan 1c decision 11): white, black, grey, and three of
    /// Toma's style: violet, turquoise and coral (sRGB, alpha 1).
    public static let borderSwatches: [RGBA] = [
        RGBA(1, 1, 1, 1), RGBA(0, 0, 0, 1), RGBA(0.5, 0.5, 0.5, 1),
        RGBA(127 / 255, 90 / 255, 240 / 255, 1), RGBA(44 / 255, 177 / 255, 188 / 255, 1), RGBA(1, 107 / 255, 107 / 255, 1),
    ]

    /// Whether the picture is flipped horizontally.
    public static func setMirror(_ doc: EditDocument, _ on: Bool) -> EditStep? {
        var changes = DocumentChanges()
        changes.set(["camera", "mirror"], from: doc.camera.mirror, to: on)
        return changes.step(label: .cameraMirror, target: "/camera/mirror")
    }

    /// The border's width, kept within 0 to 1. `nil` if it is a number that is not one.
    public static func setBorderWidth(_ doc: EditDocument, _ width: Double) -> EditStep? {
        guard !width.isNaN else { return nil }
        var changes = DocumentChanges()
        changes.set(["camera", "border", "width"], from: doc.camera.border.width, to: unit(width))
        return changes.step(label: .cameraBorder, target: "/camera/border/width")
    }

    /// The border's colour; each component is kept within 0 to 1. `nil` if one is not a number.
    public static func setBorderColor(_ doc: EditDocument, _ color: RGBA) -> EditStep? {
        guard ![color.r, color.g, color.b, color.a].contains(where: \.isNaN) else { return nil }
        let color = RGBA(unit(color.r), unit(color.g), unit(color.b), unit(color.a))
        var changes = DocumentChanges()
        changes.set(["camera", "border", "color"], from: doc.camera.border.color, to: color)
        return changes.step(label: .cameraBorder, target: "/camera/border/color")
    }

    /// The camera's shadow, kept within 0 to 1. `nil` if it is a number that is not one.
    public static func setShadow(_ doc: EditDocument, _ value: Double) -> EditStep? {
        guard !value.isNaN else { return nil }
        var changes = DocumentChanges()
        changes.set(["camera", "shadow"], from: doc.camera.shadow, to: unit(value))
        return changes.step(label: .cameraShadow, target: "/camera/shadow")
    }

    /// Removes every change of the bubble, those of the take and those of the user, in one step, from the last to the
    /// first (so undoing puts them back in the same order). `nil` without any.
    public static func deleteAllChanges(_ doc: EditDocument) -> EditStep? {
        var changes = DocumentChanges()
        for (k, change) in doc.camera.changes.enumerated().reversed() {
            changes.remove(change, from: .cameraChanges, at: k)
        }
        return changes.step(label: .cameraChangesDeleteAll, target: "/camera/changes")
    }

    private static func unit(_ value: Double) -> Double { min(max(value, 0), 1) }
}
