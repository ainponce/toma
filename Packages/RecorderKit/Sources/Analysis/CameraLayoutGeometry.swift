// SPDX-License-Identifier: GPL-3.0-or-later
import ProjectFormat

/// How the two cards of a split sit: it comes from the output's format and is never chosen (1c design §5.2).
public enum SplitOrientation: Sendable {
    /// Side by side, in an output wider than it is tall.
    case beside
    /// One above the other, in a square or tall output.
    case stacked
}

/// Where a layout draws the screen, in output pixels (origin at the top left, like every `Rect`).
public struct ScreenCard: Equatable, Sendable {
    public var rect: Rect
    public var cornerRadius: Double
    /// 1 shown, 0 hidden.
    public var opacity: Double

    public init(rect: Rect, cornerRadius: Double, opacity: Double) {
        self.rect = rect
        self.cornerRadius = cornerRadius
        self.opacity = opacity
    }
}

/// Where a layout draws the camera, in output pixels (origin at the top left, like every `Rect`).
public struct CameraCard: Equatable, Sendable {
    public var rect: Rect
    public var cornerRadius: Double
    /// 1 shown, 0 hidden.
    public var opacity: Double
    /// How much of the document's camera border (`CameraPlan.border`) is drawn: 1, or 0 in Camera full screen.
    public var borderWeight: Double
    /// How much of the document's camera shadow (`CameraPlan.shadow`) is drawn: 1, or 0 in Camera full screen.
    public var shadowWeight: Double

    public init(rect: Rect, cornerRadius: Double, opacity: Double, borderWeight: Double, shadowWeight: Double) {
        self.rect = rect
        self.cornerRadius = cornerRadius
        self.opacity = opacity
        self.borderWeight = borderWeight
        self.shadowWeight = shadowWeight
    }
}

/// Where the zoom acts, and whether the background moves with it (1c design §5.4).
public enum ScreenMode: Equatable, Sendable {
    /// Over the whole stage, background included, as in 1b: Bubble and Screen only.
    case stage
    /// Inside the screen's card, with the background still: a split, and the camera layouts, whose screen is hidden (no
    /// zoom is seen under them).
    case card
}

/// What a layout shows at an instant: the screen's card, the camera's, and where the zoom acts (1c design §5.3). The zoom's
/// transforms of the screen's contents and of the background are not here: the layouts' timeline blends them.
public struct LayoutGeometry: Equatable, Sendable {
    public var screen: ScreenCard
    public var camera: CameraCard
    public var mode: ScreenMode

    public init(screen: ScreenCard, camera: CameraCard, mode: ScreenMode) {
        self.screen = screen
        self.camera = camera
        self.mode = mode
    }

    /// `a` at `p` = 0 and `b` at 1, exactly: every number blended as `a·(1 − p) + b·p`, as `CameraStyleTimeline` blends the
    /// bubble, and `b`'s mode as soon as `p > 0`.
    public static func mix(_ a: LayoutGeometry, _ b: LayoutGeometry, _ p: Double) -> LayoutGeometry {
        func mix(_ x: Double, _ y: Double) -> Double { x * (1 - p) + y * p }
        func mix(_ x: Rect, _ y: Rect) -> Rect {
            Rect(x: mix(x.x, y.x), y: mix(x.y, y.y), width: mix(x.width, y.width), height: mix(x.height, y.height))
        }
        return LayoutGeometry(
            screen: ScreenCard(
                rect: mix(a.screen.rect, b.screen.rect), cornerRadius: mix(a.screen.cornerRadius, b.screen.cornerRadius),
                opacity: mix(a.screen.opacity, b.screen.opacity)),
            camera: CameraCard(
                rect: mix(a.camera.rect, b.camera.rect), cornerRadius: mix(a.camera.cornerRadius, b.camera.cornerRadius),
                opacity: mix(a.camera.opacity, b.camera.opacity), borderWeight: mix(a.camera.borderWeight, b.camera.borderWeight),
                shadowWeight: mix(a.camera.shadowWeight, b.camera.shadowWeight)),
            mode: p > 0 ? b.mode : a.mode)
    }
}

/// The geometry of the camera layouts in every output format, part of `cameraLayout-1` (1c design §5.2): a look defined in
/// code, frozen under `CameraLayoutRules.id`. Lengths are output pixels, origin at the top left. The useful area `A` is the
/// output less the document's padding on every side (`padding × W`, as in 1b), and the split's gap `g` is `gapFraction` of
/// the output's shorter side.
public enum CameraLayoutGeometry {
    /// The gap between a split's cards, as a fraction of the output's shorter side.
    public static let gapFraction = 0.025
    /// The bounds of the camera's automatic part of a split side by side.
    public static let besideShare: ClosedRange<Double> = 0.30...0.50
    /// The bounds of the camera's automatic part of a split one above the other.
    public static let stackedShare: ClosedRange<Double> = 0.30...0.60
    /// The aspects, width over height, a camera card is kept in: 9:16 to 16:9.
    public static let cameraAspectRange: ClosedRange<Double> = (9.0 / 16)...(16.0 / 9)
    /// What a layout does not show stays where the Bubble layout has it, at this fraction of its size around its centre, its
    /// corners too, with opacity 0.
    public static let hiddenScale = 0.9

    /// Side by side in an output wider than tall; one above the other in a square or tall one.
    public static func orientation(output: SIMD2<Double>) -> SplitOrientation {
        output.x > output.y ? .beside : .stacked
    }

    /// The camera's part of a split without a block's `share`: what a screen of `screenAspect` leaves when it is shown whole
    /// across the useful area, `1 − C·aₛ / L` side by side and `1 − (C / aₛ) / L` one above the other (`L` the length along
    /// the split less the gap, `C` the length across it), kept in `besideShare` or `stackedShare`. The bound's lower end
    /// when the area leaves nothing to share.
    public static func automaticShare(output: SIMD2<Double>, padding: Double, screenAspect: Double) -> Double {
        SplitSpace(output: output, padding: padding).automaticShare(screenAspect: screenAspect)
    }

    /// What layout `kind` shows in an output `output` big (1c design §5.2):
    /// - Bubble: the screen where 1b has it (`StageLayout.screenRect` of `screenAspect` inside the padding, with the
    ///   style's corners, `cornerRadius × W`) and the camera in `bubble`, the bubble the Bubble layout shows at that
    ///   instant. Screen only: the same, with the camera hidden.
    /// - Split (`split`, or the default one without it): the screen in the largest card of its aspect in its part
    ///   (`1 − k`) of the length along the split, never cropped, and the camera in the rest (`k`), as long across as the
    ///   screen's card, shrunk on its longer side when its aspect falls outside `cameraAspectRange`; `k` is the block's
    ///   `share`, kept in `SplitLayout.shareRange`, or `automaticShare` (its lower bound without the screen's aspect, whose
    ///   card is then all of its part). The group, card, gap and card, is centred in `A`, each card centred across it; the
    ///   camera first (on the left, or above) with `side` `.start`. Both cards have the style's corners.
    /// - Camera only: the camera in `A`, shrunk on its longer side into `cameraAspectRange` and centred, with the style's
    ///   corners; the screen hidden.
    /// - Camera full screen: the camera over the whole output, without corners, border or shadow; the screen hidden.
    ///
    /// What a layout does not show stays where the Bubble layout has it, at `hiddenScale` around its centre, with opacity 0;
    /// without `bubble`, the camera of Bubble and Screen only is an empty rect at the output's centre, with opacity 0. The
    /// camera's border and shadow weigh 1 everywhere but in Camera full screen. Bubble and Screen only are in `.stage`
    /// mode; Split, Camera only and Camera full screen in `.card`, with the background still (§5.4).
    public static func geometry(
        kind: LayoutKind, split: SplitLayout?, bubble: CameraFrame?, output: SIMD2<Double>, padding: Double,
        cornerRadius: Double, screenAspect: Double?
    ) -> LayoutGeometry {
        let corners = cornerRadius * output.x
        let stage = ScreenCard(
            rect: StageLayout.screenRect(contentAspect: screenAspect, padding: padding, outputSize: output), cornerRadius: corners,
            opacity: 1)
        let bubbleCamera = bubble.map {
            CameraCard(rect: $0.rect, cornerRadius: $0.cornerRadius, opacity: 1, borderWeight: 1, shadowWeight: 1)
        } ?? CameraCard(
            rect: Rect(x: output.x / 2, y: output.y / 2, width: 0, height: 0), cornerRadius: 0, opacity: 0, borderWeight: 1,
            shadowWeight: 1)
        func card(_ rect: Rect) -> CameraCard {
            CameraCard(rect: rect, cornerRadius: corners, opacity: 1, borderWeight: 1, shadowWeight: 1)
        }
        switch kind {
        case .bubble:
            return LayoutGeometry(screen: stage, camera: bubbleCamera, mode: .stage)
        case .screenOnly:
            return LayoutGeometry(screen: stage, camera: hidden(bubbleCamera), mode: .stage)
        case .split:
            let cards = SplitSpace(output: output, padding: padding).cards(split ?? SplitLayout(), screenAspect: screenAspect)
            return LayoutGeometry(
                screen: ScreenCard(rect: cards.screen, cornerRadius: corners, opacity: 1), camera: card(cards.camera), mode: .card)
        case .cameraOnly:
            let area = StageLayout.screenRect(contentAspect: nil, padding: padding, outputSize: output)
            let camera = centred(keptInCameraAspects(SIMD2(area.width, area.height)), in: area)
            return LayoutGeometry(screen: hidden(stage), camera: card(camera), mode: .card)
        case .cameraFull:
            let camera = CameraCard(
                rect: Rect(x: 0, y: 0, width: output.x, height: output.y), cornerRadius: 0, opacity: 1, borderWeight: 0,
                shadowWeight: 0)
            return LayoutGeometry(screen: hidden(stage), camera: camera, mode: .card)
        }
    }

    /// `size` shrunk on its longer side, when it must be, into `cameraAspectRange`; an empty size as it is.
    fileprivate static func keptInCameraAspects(_ size: SIMD2<Double>) -> SIMD2<Double> {
        guard size.x > 0, size.y > 0 else { return size }
        let aspect = size.x / size.y
        if aspect > cameraAspectRange.upperBound { return SIMD2(size.y * cameraAspectRange.upperBound, size.y) }
        if aspect < cameraAspectRange.lowerBound { return SIMD2(size.x, size.x / cameraAspectRange.lowerBound) }
        return size
    }

    /// A box of `size` centred in `area`.
    private static func centred(_ size: SIMD2<Double>, in area: Rect) -> Rect {
        Rect(x: area.x + (area.width - size.x) / 2, y: area.y + (area.height - size.y) / 2, width: size.x, height: size.y)
    }

    private static func hidden(_ screen: ScreenCard) -> ScreenCard {
        ScreenCard(rect: shrunk(screen.rect), cornerRadius: screen.cornerRadius * hiddenScale, opacity: 0)
    }

    private static func hidden(_ camera: CameraCard) -> CameraCard {
        CameraCard(
            rect: shrunk(camera.rect), cornerRadius: camera.cornerRadius * hiddenScale, opacity: 0,
            borderWeight: camera.borderWeight, shadowWeight: camera.shadowWeight)
    }

    /// `rect` at `hiddenScale` of its size around its centre.
    private static func shrunk(_ rect: Rect) -> Rect {
        let width = rect.width * hiddenScale, height = rect.height * hiddenScale
        return Rect(x: rect.x + (rect.width - width) / 2, y: rect.y + (rect.height - height) / 2, width: width, height: height)
    }
}

/// A split's useful area and the lengths it shares out (1c design §5.2).
private struct SplitSpace {
    let orientation: SplitOrientation
    /// `A`: the output less the padding on every side.
    let area: Rect
    /// `g`.
    let gap: Double
    /// `L`: `A`'s side along the split, less the gap.
    let length: Double
    /// `C`: `A`'s side across the split.
    let across: Double

    init(output: SIMD2<Double>, padding: Double) {
        orientation = CameraLayoutGeometry.orientation(output: output)
        area = StageLayout.screenRect(contentAspect: nil, padding: padding, outputSize: output)
        gap = CameraLayoutGeometry.gapFraction * min(output.x, output.y)
        let (along, across) = orientation == .beside ? (area.width, area.height) : (area.height, area.width)
        length = max(along - gap, 0)
        self.across = across
    }

    /// The bounds of the automatic part in this orientation.
    private var automaticRange: ClosedRange<Double> {
        orientation == .beside ? CameraLayoutGeometry.besideShare : CameraLayoutGeometry.stackedShare
    }

    func automaticShare(screenAspect: Double) -> Double {
        guard length > 0, across > 0 else { return automaticRange.lowerBound }
        // The length the screen needs along the split to be shown whole across the area.
        let needed = orientation == .beside ? across * screenAspect : across / screenAspect
        return Self.clamp(1 - needed / length, automaticRange)
    }

    /// The screen's card and the camera's.
    func cards(_ split: SplitLayout, screenAspect: Double?) -> (screen: Rect, camera: Rect) {
        let share = split.share.map { Self.clamp($0, SplitLayout.shareRange) }
            ?? screenAspect.map { automaticShare(screenAspect: $0) } ?? automaticRange.lowerBound
        let screen = Self.fitted(screenAspect, in: size(along: (1 - share) * length, across: across))
        let camera = CameraLayoutGeometry.keptInCameraAspects(size(along: share * length, across: acrossSide(screen)))
        let (first, second) = split.side == .start ? (camera, screen) : (screen, camera)
        let group = alongSide(first) + gap + alongSide(second)
        let start = alongSide(SIMD2(area.x, area.y)) + (alongSide(SIMD2(area.width, area.height)) - group) / 2
        let firstRect = place(first, at: start)
        let secondRect = place(second, at: start + alongSide(first) + gap)
        return split.side == .start ? (secondRect, firstRect) : (firstRect, secondRect)
    }

    /// A card of `size` starting at `offset` along the split, centred across `A`.
    private func place(_ size: SIMD2<Double>, at offset: Double) -> Rect {
        switch orientation {
        case .beside: Rect(x: offset, y: area.y + (area.height - size.y) / 2, width: size.x, height: size.y)
        case .stacked: Rect(x: area.x + (area.width - size.x) / 2, y: offset, width: size.x, height: size.y)
        }
    }

    /// A width and a height from a length along the split and one across it.
    private func size(along: Double, across: Double) -> SIMD2<Double> {
        orientation == .beside ? SIMD2(along, across) : SIMD2(across, along)
    }

    /// The component of `vector` along the split.
    private func alongSide(_ vector: SIMD2<Double>) -> Double {
        orientation == .beside ? vector.x : vector.y
    }

    /// The component of `vector` across the split.
    private func acrossSide(_ vector: SIMD2<Double>) -> Double {
        orientation == .beside ? vector.y : vector.x
    }

    /// The largest box of `aspect` inside `box`, as `StageLayout.screenRect` fits the screen; all of `box` without an aspect
    /// or with an empty one.
    private static func fitted(_ aspect: Double?, in box: SIMD2<Double>) -> SIMD2<Double> {
        guard let aspect, box.x > 0, box.y > 0 else { return box }
        return box.x / box.y > aspect ? SIMD2(box.y * aspect, box.y) : SIMD2(box.x, box.x / aspect)
    }

    private static func clamp(_ value: Double, _ range: ClosedRange<Double>) -> Double {
        min(max(value, range.lowerBound), range.upperBound)
    }
}
