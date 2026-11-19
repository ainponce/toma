// SPDX-License-Identifier: GPL-3.0-or-later
import ProjectFormat

/// The commands of the camera's picture (phase 2 design §6.1 to §6.3): the background, the framing and the colour look, as
/// pure functions of the document. Each gives the step that does it (`EditStep`), or `nil` when nothing changes. The
/// target of each step is the pointer of what it sets, so a burst on one control is one undo group.
public enum CameraPictureCommands {
    /// What is behind the person.
    public static func setBackground(_ doc: EditDocument, _ value: CameraBackground) -> EditStep? {
        var changes = DocumentChanges()
        changes.set(["camera", "background"], from: doc.camera.background, to: value)
        return changes.step(label: .cameraBackground, target: "/camera/background")
    }

    /// How the picture is framed. "Follow the Face" over a framing not zoomed (zoom 1) starts at `CameraFraming.faceZoom`,
    /// in the same step.
    public static func setFramingMode(_ doc: EditDocument, _ mode: CameraFramingMode) -> EditStep? {
        var changes = DocumentChanges()
        changes.set(["camera", "framing", "mode"], from: doc.camera.framing.mode, to: mode)
        if mode == .face, doc.camera.framing.zoom <= 1 {
            changes.set(["camera", "framing", "zoom"], from: doc.camera.framing.zoom, to: CameraFraming.faceZoom)
        }
        return changes.step(label: .cameraFraming, target: "/camera/framing/mode")
    }

    /// The center of the manual framing, each coordinate kept within 0 to 1. `nil` if one is not a number.
    public static func setFramingCenter(_ doc: EditDocument, _ center: NormalizedPoint) -> EditStep? {
        guard center.x.isFinite, center.y.isFinite else { return nil }
        var changes = DocumentChanges()
        changes.set(
            ["camera", "framing", "center"], from: doc.camera.framing.center,
            to: NormalizedPoint(x: unit(center.x), y: unit(center.y)))
        return changes.step(label: .cameraFraming, target: "/camera/framing/center")
    }

    /// The framing's zoom, kept within `CameraFraming.zoomRange`. `nil` if it is not a number.
    public static func setFramingZoom(_ doc: EditDocument, _ zoom: Double) -> EditStep? {
        guard !zoom.isNaN else { return nil }
        let range = CameraFraming.zoomRange
        var changes = DocumentChanges()
        changes.set(
            ["camera", "framing", "zoom"], from: doc.camera.framing.zoom,
            to: min(max(zoom, range.lowerBound), range.upperBound))
        return changes.step(label: .cameraFraming, target: "/camera/framing/zoom")
    }

    /// The colour preset. `custom` without a `.cube` in the document is refused (`setCustomLook` sets both).
    public static func setLookPreset(_ doc: EditDocument, _ preset: CameraColorPreset) -> EditStep? {
        if preset == .custom, doc.camera.look.lut == nil { return nil }
        var changes = DocumentChanges()
        changes.set(["camera", "look", "preset"], from: doc.camera.look.preset, to: preset)
        return changes.step(label: .cameraLook, target: "/camera/look/preset")
    }

    /// How much of the look is mixed over the original, kept within 0 to 1. `nil` if it is not a number.
    public static func setLookIntensity(_ doc: EditDocument, _ value: Double) -> EditStep? {
        guard !value.isNaN else { return nil }
        var changes = DocumentChanges()
        changes.set(["camera", "look", "intensity"], from: doc.camera.look.intensity, to: unit(value))
        return changes.step(label: .cameraLook, target: "/camera/look/intensity")
    }

    /// The user's `.cube` (`file`: its path from the package root, as `AssetImport` gives it) as the look, in one step: the
    /// preset becomes `custom` and the file is kept. `nil` for an empty path or when it is so already.
    public static func setCustomLook(_ doc: EditDocument, file: String) -> EditStep? {
        guard !file.isEmpty else { return nil }
        var look = doc.camera.look
        look.preset = .custom
        look.lut = file
        var changes = DocumentChanges()
        changes.set(["camera", "look"], from: doc.camera.look, to: look)
        return changes.step(label: .cameraLook, target: "/camera/look")
    }

    private static func unit(_ value: Double) -> Double { min(max(value, 0), 1) }
}
