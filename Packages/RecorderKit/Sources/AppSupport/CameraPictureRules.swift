// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import ProjectFormat

/// What the camera's analysis line of the Camera tab says (phase 2 design §6.1 and §6.2): "Preparing the cutout… 30 %" or
/// "Looking for the face… 40 %" while it runs, its reason once a part of it made nothing, and nothing otherwise.
public enum CameraAnalysisStatus: Equatable, Sendable {
    /// Nothing to say: the document needs none of it, or all of it is there.
    case none
    /// Under way, at this whole percentage: 0 to 99, never 100 while a part is still running.
    case preparing(percent: Int)
    /// A part of it failed or cannot be done on this Mac: the tab says why.
    case failed
}

/// The rules of the Camera tab's Background, Framing and Color (phase 2 design §6.1 to §6.3); the view only draws them.
public enum CameraPictureRules {
    /// The looks made in code, in the order of their tiles; Custom comes after them, with its file.
    public static let presets: [CameraColorPreset] = [.natural, .warm, .cool, .vivid, .soft, .mono]
    /// The step of the framing's zoom bar: 1.0×, 1.1× … 2.5×.
    public static let zoomStep = 0.1

    /// What a click on a Color tile does.
    public enum LookAction: Equatable, Sendable {
        /// The document's preset becomes this one.
        case setPreset(CameraColorPreset)
        /// "Custom…" without a `.cube` in the document: the open panel for one.
        case chooseFile
    }

    /// The line for an analysis at `progress` (`EditorImage.cameraProgress`: 0 to 1, `nil` when the document needs none)
    /// of which a part `failed` (`EditorImage.problem`). A progress that is not a number is a start.
    public static func status(progress: Double?, failed: Bool) -> CameraAnalysisStatus {
        if failed { return .failed }
        guard let progress else { return .none }
        guard progress.isFinite else { return .preparing(percent: 0) }
        guard progress < 1 else { return .none }
        return .preparing(percent: min(max(Int((progress * 100).rounded(.down)), 0), 99))
    }

    /// The tile chosen for `look`: its preset, and Natural for Custom without its `.cube`, which the render draws as
    /// Natural.
    public static func selectedLook(_ look: CameraColor) -> CameraColorPreset {
        look.preset == .custom && look.lut == nil ? .natural : look.preset
    }

    /// Whether Intensity changes what is drawn: only with a look other than Natural.
    public static func intensityApplies(_ look: CameraColor) -> Bool {
        selectedLook(look) != .natural
    }

    /// What choosing the tile of `preset` does to `look`: Custom without a `.cube` in the document asks for one; with
    /// one (brought in before, then another look chosen), it is used again.
    public static func action(choosing preset: CameraColorPreset, in look: CameraColor) -> LookAction {
        preset == .custom && look.lut == nil ? .chooseFile : .setPreset(preset)
    }

    /// `zoom` on the bar's steps (`zoomStep`), within `CameraFraming.zoomRange`; 1 when it is not a number.
    public static func snappedZoom(_ zoom: Double) -> Double {
        guard !zoom.isNaN else { return CameraFraming.zoomRange.lowerBound }
        // In whole steps per unit (10), so a step's value is the decimal written: 1.4, not 1.4000000000000001.
        let steps = (1 / zoomStep).rounded()
        let snapped = (zoom * steps).rounded() / steps
        return min(max(snapped, CameraFraming.zoomRange.lowerBound), CameraFraming.zoomRange.upperBound)
    }

    /// A fraction (a coordinate of the framing's centre) as the whole percentage VoiceOver reads: within 0 to 100, the
    /// middle when it is not a number.
    public static func percent(_ fraction: Double) -> Int {
        guard !fraction.isNaN else { return 50 }
        return Int((min(max(fraction, 0), 1) * 100).rounded())
    }
}
