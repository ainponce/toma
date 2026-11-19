// SPDX-License-Identifier: GPL-3.0-or-later
import ProjectFormat

/// The camera's sync against the sound (phase 2 design §5.9, `EditDocument.camera.syncOffset`): which frame of the camera
/// a frame draws (§11, step 4, "tomada en `t − syncOffset`"), worked out once for the scene (`FrameEvaluator.init`).
///
/// The base of phase 2 leaves it as the identity, as an offset of 0 is: the camera's frame of the same instant, as in
/// phase 1. Milestone 2a fills it here.
struct CameraSyncScene: Sendable {
    init(document: EditDocument, take: TakeRecord) {}

    /// The source instant of the camera's frame drawn where the frame shows the camera at source instant `t`: `t` in the
    /// base.
    func cameraTime(atSource t: HostTime) -> HostTime {
        t
    }
}
