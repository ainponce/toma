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
/// (`FrameEvaluator.init`); `resized(to:)` keeps it, as nothing of it depends on the output's size.
///
/// - **Framing** (`CameraLookLayer.framing`, design §6.2): Centred at 1× (a zoom read by `CameraFramingGeometry
///   .clampedZoom`) is none, the camera of phase 1; Centred above 1× is the middle of the picture; Manual, the document's
///   centre; Follow the Face, the centre of `faceFraming-1` (`FaceFramingPath`, built here once) at the frame's output
///   time, or the middle while the face tracks are not in the caches. Each at the document's zoom.
/// - **Colour** (`CameraLookLayer.lut`, design §6.3): none for Natural, for an intensity at 0 or below (or not a number),
///   and for Personalised without its `.cube`; the user's `.cube` by its path in the package; the look made in code for
///   the others. The intensity is read up to 1; without a LUT it is 0. No framing and no LUT is no look (`nil`).
/// - **Background** (`CameraLayer.background`, design §6.1): none for Original. Blurred or Removed read the person's mask
///   of the camera's segment whose frame is drawn (the last segment of the camera's track that starts at or before the
///   camera's frame's source instant, which `TrackFrameReader` shows, its last frame held after its end), at that same
///   instant; without that segment's mask in the caches the camera is the original, with nothing else changed (never a
///   gap). Removed in a Bubble (plan 2b decision 8) is the person over the scene in the bubble's rect: no corners, no
///   border, no shadow. Removed in a card (Split, Camera only, Camera full screen) keeps the card's shape and border,
///   without its shadow, and a frame that the camera covered is no longer covered: what is under the person is drawn.
///   The span that rules at the frame's output time (`LayoutTimeline.span(atOutput:)`) says which: Bubble is a bubble; a
///   Screen only span shows only the camera leaving the span before it (or coming into the next one, which then rules),
///   so it is what that span was, a bubble when none was before it (1b's path, which only ever draws a bubble).
struct CameraLookScene: Sendable {
    /// The evaluator's layouts: the span that rules at a frame's output time (`LayoutTimeline.span(atOutput:)`).
    let layouts: LayoutTimeline
    /// The framing of every frame but Follow the Face's.
    private let framing: Framing
    /// The colour of every frame; `nil` without a LUT.
    private let lut: CameraLUTRef?
    private let intensity: Float
    /// `nil` for Original.
    private let background: CameraBackgroundLayer.Mode?
    /// The segments of each camera track that has a mask in the caches, with their masks: empty for Original.
    private let maskedTracks: [String: [MaskedSegment]]
    /// For each of `layouts.spans`, whether the camera seen in it is a bubble (see the type's notes).
    private let showsABubble: [Bool]

    private enum Framing: Sendable {
        case none
        case fixed(CameraFramingLayer)
        /// Follow the Face at `zoom`: the path's centre, or the middle without one.
        case face(FaceFramingPath?, zoom: Double)
    }

    /// A segment of a camera track, in the order of their starts, with its mask (`nil` without one).
    private struct MaskedSegment: Sendable {
        var start: HostTime
        var end: HostTime?
        var mask: URL?
    }

    init(document: EditDocument, take: TakeRecord, analysis: AnalysisInputs, layouts: LayoutTimeline) {
        self.layouts = layouts
        let camera = document.camera

        let zoom = CameraFramingGeometry.clampedZoom(camera.framing.zoom)
        let middle = SIMD2<Double>(0.5, 0.5)
        switch camera.framing.mode {
        case .center:
            framing = zoom > CameraFraming.zoomRange.lowerBound ? .fixed(CameraFramingLayer(center: middle, zoom: zoom)) : .none
        case .manual:
            let center = SIMD2(camera.framing.center.x, camera.framing.center.y)
            framing = .fixed(CameraFramingLayer(center: center, zoom: zoom))
        case .face:
            let path = FaceFramingPath(
                document: document, take: take, timeMap: TimeMap(sequence: document.sequence), faces: analysis.faceTracks)
            framing = .face(path, zoom: zoom)
        }

        let color = camera.look
        let amount = color.intensity.isNaN ? 0 : min(color.intensity, 1)
        if amount <= 0 {
            lut = nil
        } else {
            switch color.preset {
            case .natural: lut = nil
            case .custom: lut = color.lut.flatMap { $0.isEmpty ? nil : .file($0) }
            case .warm, .cool, .vivid, .soft, .mono: lut = .preset(color.preset)
            }
        }
        intensity = lut == nil ? 0 : Float(amount)

        switch camera.background {
        case .original: background = nil
        case .blurred: background = .blurred
        case .removed: background = .removed
        }
        var maskedTracks: [String: [MaskedSegment]] = [:]
        if background != nil, !analysis.personMasks.isEmpty {
            for track in take.tracks where track.kind == .camera {
                let segments = track.segments.sorted { $0.startHostTime < $1.startHostTime }.map { segment in
                    MaskedSegment(
                        start: segment.startHostTime, end: segment.endHostTime,
                        mask: analysis.personMasks[CameraSegment(take: take.id, track: track.id, segment: segment.index)])
                }
                if segments.contains(where: { $0.mask != nil }) { maskedTracks[track.id] = segments }
            }
        }
        self.maskedTracks = maskedTracks

        var showsABubble: [Bool] = []
        for span in layouts.spans {
            showsABubble.append(span.kind == .screenOnly ? showsABubble.last ?? true : span.kind == .bubble)
        }
        self.showsABubble = showsABubble
    }

    /// Puts the camera's framing and colour (`CameraLayer.look`) and its background (`CameraLayer.background`) at source
    /// instant `t` and output time `output` onto `frame`'s camera, as `FrameEvaluator.finishLayers` hands it over (the
    /// camera's frame taken at its sync, `CameraLayer.sourceTime`); a removed background changes the camera's shape,
    /// border and shadow, and a frame covered by the camera (`RenderFrame.coveredByCamera`) is no longer covered (see the
    /// type's notes). Nothing without a camera.
    func apply(to frame: inout RenderFrame, atSource t: HostTime, output: Int64) {
        guard var camera = frame.camera else { return }
        let framing: CameraFramingLayer?
        switch self.framing {
        case .none:
            framing = nil
        case .fixed(let layer):
            framing = layer
        case .face(let path, let zoom):
            framing = CameraFramingLayer(center: path?.center(atOutput: output) ?? SIMD2(0.5, 0.5), zoom: zoom)
        }
        if framing != nil || lut != nil {
            camera.look = CameraLookLayer(framing: framing, lut: lut, intensity: intensity)
        }
        if let mode = background, let mask = mask(of: camera) {
            let bubble = mode == .removed && showsABubble(atOutput: output)
            camera.background = CameraBackgroundLayer(mode: mode, mask: mask, overScene: bubble)
            if mode == .removed {
                camera.shadow = nil
                if bubble {
                    camera.cornerRadius = 0
                    camera.border = nil
                } else {
                    frame.coveredByCamera = false
                }
            }
        }
        frame.camera = camera
    }

    /// The person's mask of the frame `camera` draws: of the segment of its track that shows its source instant, at that
    /// instant; `nil` when that segment has none in the caches, and before the track's first segment.
    private func mask(of camera: CameraLayer) -> PersonMaskSource? {
        guard let segments = maskedTracks[camera.trackID] else { return nil }
        let time = camera.sourceTime
        // The last segment starting at or before `time`.
        var (low, high) = (0, segments.count)
        while low < high {
            let middle = low + (high - low) / 2
            if segments[middle].start <= time { low = middle + 1 } else { high = middle }
        }
        guard low > 0, let file = segments[low - 1].mask else { return nil }
        let segment = segments[low - 1]
        return PersonMaskSource(
            file: file, segmentStart: segment.start, segmentEnd: segment.end, time: time,
            readerID: "personMask:" + file.lastPathComponent)
    }

    /// Whether the camera seen at output time `τ` is a bubble: that of the span that rules then, found as
    /// `LayoutTimeline.span(atOutput:)` finds it (the last span starting at or before `τ`, the first before the output).
    private func showsABubble(atOutput τ: Int64) -> Bool {
        let spans = layouts.spans
        var (low, high) = (0, spans.count)
        while low < high {
            let middle = low + (high - low) / 2
            if spans[middle].output.lowerBound <= τ { low = middle + 1 } else { high = middle }
        }
        return showsABubble.isEmpty ? true : showsABubble[max(low - 1, 0)]
    }
}
