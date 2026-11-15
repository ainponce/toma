// SPDX-License-Identifier: GPL-3.0-or-later
import CoreGraphics
import ProjectFormat

/// Where something thrown with a velocity comes to rest (the function of *Designing Fluid Interfaces*).
public enum Momentum {
    /// `UIScrollView.DecelerationRate.normal`.
    public static let decelerationRate = 0.992

    /// How far, in points, something moving at `velocity` points per second travels before it stops:
    /// `(v / 1000) × d / (1 − d)`.
    public static func project(velocity: Double, decelerationRate: Double = decelerationRate) -> Double {
        (velocity / 1000) * decelerationRate / (1 - decelerationRate)
    }
}

/// The live camera bubble (notch design §5.3 and §5.6): its region, its 8 places, where it lands when let
/// go and when it is seen. Everything in global coordinates (y down, like `DisplayInfo.frame`).
public enum CameraBubbleLayout {
    /// Where the pointer was at a moment of a drag (`time` in seconds, on any monotonic clock).
    public struct DragSample: Equatable, Sendable {
        public var time: Double
        public var point: CGPoint

        public init(time: Double, point: CGPoint) {
            self.time = time
            self.point = point
        }
    }

    /// The span of a drag the release velocity is measured over.
    public static let releaseVelocitySpan = 0.1

    /// The bubble of `style` at each of the 8 places of `region`, in `CameraAnchor.allCases` order.
    public static func anchorFrames(style: CameraStyle, region: Rect) -> [(anchor: CameraAnchor, rect: Rect)] {
        CameraAnchor.allCases.map { anchor in
            var anchored = style
            anchored.anchor = anchor
            return (anchor: anchor, rect: anchored.frame(in: region).rect)
        }
    }

    /// Where the bubble goes when it is let go at `origin` (its top left) moving at `velocity` (points per
    /// second): the place whose origin is nearest to where it would come to rest, `origin` plus its momentum
    /// on each axis (`Momentum.project`).
    public static func releaseAnchor(origin: CGPoint, velocity: CGVector, style: CameraStyle, region: Rect) -> CameraAnchor {
        let x = Double(origin.x) + Momentum.project(velocity: Double(velocity.dx))
        let y = Double(origin.y) + Momentum.project(velocity: Double(velocity.dy))
        func distance(_ rect: Rect) -> Double { ((rect.x - x) * (rect.x - x) + (rect.y - y) * (rect.y - y)).squareRoot() }
        let places = anchorFrames(style: style, region: region)
        return places.min { distance($0.rect) < distance($1.rect) }?.anchor ?? style.anchor
    }

    /// The velocity of a drag as it is let go at `time`, in points per second: how far it went over the last
    /// `releaseVelocitySpan`, from the first sample in that span to the last (the position at `time`
    /// included). Zero with fewer than two samples there: it was held still before being let go.
    public static func releaseVelocity(samples: [DragSample], at time: Double) -> CGVector {
        let recent = samples.filter { $0.time >= time - releaseVelocitySpan && $0.time <= time }
        guard let first = recent.first, let last = recent.last, last.time > first.time else { return .zero }
        // At least a frame at 60 Hz: two samples a moment apart say little about the speed.
        let seconds = max(last.time - first.time, 1.0 / 60)
        return CGVector(dx: (last.point.x - first.point.x) / seconds, dy: (last.point.y - first.point.y) / seconds)
    }

    /// What the bubble's places are relative to (notch design §5.6): in Display mode, the chosen display that
    /// has `pointer`, otherwise the first chosen (the take's first cursor's, plan decision 2); in Area mode,
    /// the area; in Window mode, the window's frame. `nil` when there is none (no display chosen or
    /// connected, no area, no window).
    public static func region(for selection: CaptureSelection, displays: [DisplayInfo], pointer: CGPoint?, windowFrame: Rect?) -> Rect? {
        switch selection.mode {
        case .display:
            let chosen = selection.displayIDs.compactMap { id in displays.first { $0.id == id } }
            if let pointer, let under = chosen.first(where: { CursorGeometry.contains(pointer, $0.frame) }) { return under.frame }
            return chosen.first?.frame
        case .area:
            return selection.area?.rect
        case .window:
            return windowFrame
        }
    }

    /// The bubble is seen while the camera is on and the island is in use: open, choosing, counting down,
    /// recording (also open, or with a notice). Not at rest, peeking, saving or saved.
    public static func isVisible(cameraOn: Bool, island: IslandState) -> Bool {
        guard cameraOn else { return false }
        switch island {
        case .open, .choosing, .countdown, .recording, .recordingOpen, .notice: return true
        case .rest, .peek, .saving, .saved: return false
        }
    }
}
