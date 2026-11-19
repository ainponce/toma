// SPDX-License-Identifier: GPL-3.0-or-later
import ProjectFormat

/// The camera's colour (phase 2 design §6.3) as a frame draws it, in the camera's shader (§11, step 4). Empty in the
/// base: milestone 2b gives it what it draws.
public struct CameraLookLayer: Equatable, Sendable {
    public init() {}
}

/// What is behind the person in the camera (phase 2 design §6.1, blurred or removed) as a frame draws it, with the
/// person's mask of the analysis caches. Empty in the base: milestone 2b gives it what it draws.
public struct CameraBackgroundLayer: Equatable, Sendable {
    public init() {}
}

/// The camera's picture of a document (`EditDocument.camera`'s `background`, `framing` and `look`) as the frames draw it,
/// with what the analysis caches hold (`AnalysisInputs`: the masks, the faces), worked out once for the scene
/// (`FrameEvaluator.init`).
///
/// The base of phase 2 leaves it empty: `apply` changes nothing, so the legacy camera (original background, centred
/// framing at 1×, natural colour) draws as in phase 1. Milestone 2b fills it here.
struct CameraLookScene: Sendable {
    init(document: EditDocument, take: TakeRecord, analysis: AnalysisInputs) {}

    /// Puts the framing's crop (`CameraLayer.crop`), the colour (`look`) and the background (`background`) of the camera
    /// at source instant `t` and output time `output` onto `layer`. Nothing in the base.
    func apply(to layer: inout CameraLayer, atSource t: HostTime, output: Int64) {}
}
