// SPDX-License-Identifier: GPL-3.0-or-later
import Analysis
import Foundation
import ProjectFormat

/// The part of the camera's picture its framing shows (phase 2 design §6.2, plan 2b decision 2): the crop that fills the
/// camera's shape, divided by `zoom` and centred at `center`, never outside the picture. The crop depends on the aspect
/// of the camera's frame, which only its texture knows, so the compositor works it out (`Compositor.cameraFill`).
public struct CameraFramingLayer: Equatable, Sendable {
    /// In fractions of the camera's frame (0, 0 its top-left corner), before the mirror.
    public var center: SIMD2<Double>
    /// Above 1 (`CameraFraming.zoomRange`).
    public var zoom: Double

    public init(center: SIMD2<Double>, zoom: Double) {
        self.center = center
        self.zoom = zoom
    }
}

/// The 3D LUT a camera's colour is drawn with (`cameraLook-1`).
public enum CameraLUTRef: Hashable, Sendable {
    /// One of the looks made in code; never `natural`, which draws no LUT.
    case preset(CameraColorPreset)
    /// The user's `.cube` copied into the package: its path from the package root (`CameraColor.lut`).
    case file(String)
}

/// The camera's framing and colour (phase 2 design §6.2 and §6.3) as a frame draws them, in the camera's fill and its
/// shader (§11, step 4). `nil` on `CameraLayer.look`, as in phase 1: the centred fill of the whole picture, natural.
public struct CameraLookLayer: Equatable, Sendable {
    /// `nil`: the picture fills the shape as in phase 1 (centred, not zoomed).
    public var framing: CameraFramingLayer?
    /// `nil`: no LUT (natural).
    public var lut: CameraLUTRef?
    /// 0 to 1: how much of the LUT's result is mixed over the picture.
    public var intensity: Float

    public init(framing: CameraFramingLayer?, lut: CameraLUTRef?, intensity: Float) {
        self.framing = framing
        self.lut = lut
        self.intensity = intensity
    }
}

/// The person's mask a camera's frame is drawn with (`personMask-1`): the frame of the mask's video (the analysis caches'
/// file `file`, of the camera's segment from `segmentStart` to `segmentEnd`) at the camera's own source instant `time`, read
/// like the camera by a reader of its own (`readerID`, which no track of a take has).
public struct PersonMaskSource: Hashable, Sendable {
    public var file: URL
    public var segmentStart: HostTime
    /// `nil` for a segment still open, as `SegmentRecord.end`.
    public var segmentEnd: HostTime?
    /// The camera's frame's source instant (`CameraLayer.sourceTime`).
    public var time: HostTime
    /// `"personMask:"` and the file's name.
    public var readerID: String

    public init(file: URL, segmentStart: HostTime, segmentEnd: HostTime?, time: HostTime, readerID: String) {
        self.file = file
        self.segmentStart = segmentStart
        self.segmentEnd = segmentEnd
        self.time = time
        self.readerID = readerID
    }
}

/// What is behind the person in the camera (phase 2 design §6.1, blurred or removed) as a frame draws it, with the
/// person's mask of the analysis caches. `nil` on `CameraLayer.background`, as in phase 1: the original.
public struct CameraBackgroundLayer: Equatable, Sendable {
    public enum Mode: Hashable, Sendable {
        /// The camera's own picture, blurred, behind the person.
        case blurred
        /// The person alone, over what is under the camera.
        case removed
    }

    public var mode: Mode
    public var mask: PersonMaskSource
    /// Removed in a Bubble (plan 2b decision 8): the person over the scene in the bubble's rect, without its shape, border
    /// or shadow. `false` in a card, which keeps its shape and border.
    public var overScene: Bool

    public init(mode: Mode, mask: PersonMaskSource, overScene: Bool) {
        self.mode = mode
        self.mask = mask
        self.overScene = overScene
    }
}

/// The camera's picture of a document (`EditDocument.camera`'s `background`, `framing` and `look`) as the frames draw it,
/// with what the analysis caches hold (`AnalysisInputs`: the masks, the faces) and the layouts the frames are laid out by
/// (the evaluator's `LayoutTimeline`, which says where the camera is a Bubble), worked out once for the scene
/// (`FrameEvaluator.init`).
///
/// Milestone 2b's seam leaves it empty: `apply` changes nothing, so the legacy camera (original background, centred
/// framing at 1×, natural colour) draws as in phase 1. Task I9 fills it here.
struct CameraLookScene: Sendable {
    /// The evaluator's layouts: the span that rules at a frame's output time (`LayoutTimeline.span(atOutput:)`).
    let layouts: LayoutTimeline

    init(document: EditDocument, take: TakeRecord, analysis: AnalysisInputs, layouts: LayoutTimeline) {
        self.layouts = layouts
    }

    /// Puts the camera's framing and colour (`CameraLayer.look`) and its background (`CameraLayer.background`) at source
    /// instant `t` and output time `output` onto `frame`'s camera, as `FrameEvaluator.finishLayers` hands it over (the
    /// camera's frame taken at its sync); a removed background changes the camera's shape, border and shadow, and a frame
    /// covered by the camera (`RenderFrame.coveredByCamera`) is no longer covered. Nothing in the seam.
    func apply(to frame: inout RenderFrame, atSource t: HostTime, output: Int64) {}
}
