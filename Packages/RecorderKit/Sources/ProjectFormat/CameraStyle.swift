// SPDX-License-Identifier: GPL-3.0-or-later

/// The camera's shape, in the video and in the live bubble (notch design §5.6).
public enum CameraShape: String, Codable, Sendable, CaseIterable {
    case circle
    /// Its corners rounded by 26 % of its side.
    case roundedSquare
    /// 3:4.
    case portrait
    /// 16:9.
    case landscape

    /// Width over height.
    public var aspect: Double {
        switch self {
        case .circle, .roundedSquare: 1
        case .portrait: 3.0 / 4
        case .landscape: 16.0 / 9
        }
    }
}

/// Where the camera goes: one of the 8 places at the corners and the middles of the edges of what is
/// recorded, kept as a place and not as coordinates (notch design §5.3 and §5.6).
public enum CameraAnchor: String, Codable, Sendable, CaseIterable {
    case topLeading, top, topTrailing, leading, trailing, bottomLeading, bottom, bottomTrailing
}

/// Where the camera is drawn, and how round its corners are.
public struct CameraFrame: Equatable, Sendable {
    /// In the region's coordinates (y down, like every `Rect`).
    public var rect: Rect
    public var cornerRadius: Double

    public init(rect: Rect, cornerRadius: Double) {
        self.rect = rect
        self.cornerRadius = cornerRadius
    }
}

/// How the camera looks: its shape, its size and its place (notch design §5.6). The live bubble and the
/// render share its one geometry, `frame(in:)` (plan decision 25). Format version 2 keeps it in a project: a
/// take's initial style (`TakeRecord.cameraStyle`) and its changes while recording (`InputEvent.Kind.cameraStyle`).
/// The app also remembers it in its settings.
public struct CameraStyle: Codable, Equatable, Sendable {
    public var shape: CameraShape
    /// The side of the camera as a fraction of the region's height (and, in the video, of the output's), so it
    /// does not depend on the display: `small`, `medium` or `large`.
    public var size: Double
    public var anchor: CameraAnchor

    /// Small, Medium and Large: 130, 180 and 250 pt of side on the reference display, 1200 × 750 pt.
    public static let small = 0.17
    public static let medium = 0.24
    public static let large = 0.33
    /// The margin to the region's edges, as a fraction of its height: 24 pt on the reference display.
    public static let marginFraction = 0.032
    /// A medium circle at the bottom right.
    public static let `default` = CameraStyle(shape: .circle, size: medium, anchor: .bottomTrailing)

    public init(shape: CameraShape, size: Double, anchor: CameraAnchor) {
        self.shape = shape
        self.size = size
        self.anchor = anchor
    }

    /// The camera in `region` (decision 25): a box with the area of the square of side `size × height`
    /// (width `side·√aspect`, height `side/√aspect`), `marginFraction × height` from the edges its anchor is
    /// at and centered on the other axis, moved by the region's origin. The corners: half the shorter side
    /// for a circle, 26 % of the side for the rounded square, and 20 and 18 pt on the reference display's 750
    /// pt of height for the vertical and horizontal boxes.
    public func frame(in region: Rect) -> CameraFrame {
        let side = size * region.height
        let root = shape.aspect.squareRoot()
        let width = side * root
        let height = side / root
        let margin = Self.marginFraction * region.height
        let column = Self.position(along: anchor.column, length: width, in: region.width, margin: margin)
        let row = Self.position(along: anchor.row, length: height, in: region.height, margin: margin)
        let radius = switch shape {
        case .circle: min(width, height) / 2
        case .roundedSquare: 0.26 * side
        case .portrait: 20.0 / 750 * region.height
        case .landscape: 18.0 / 750 * region.height
        }
        return CameraFrame(
            rect: Rect(x: region.x + column, y: region.y + row, width: width, height: height), cornerRadius: radius)
    }

    /// Where a box of `length` starts along an axis of `total`: at the margin, centered, or at the margin
    /// from the end.
    private static func position(along place: CameraAnchor.Place, length: Double, in total: Double, margin: Double) -> Double {
        switch place {
        case .start: margin
        case .middle: (total - length) / 2
        case .end: total - length - margin
        }
    }
}

extension CameraAnchor {
    /// Where an anchor is along one axis.
    fileprivate enum Place {
        case start, middle, end
    }

    /// Left, center or right.
    fileprivate var column: Place {
        switch self {
        case .topLeading, .leading, .bottomLeading: .start
        case .top, .bottom: .middle
        case .topTrailing, .trailing, .bottomTrailing: .end
        }
    }

    /// Top, middle or bottom.
    fileprivate var row: Place {
        switch self {
        case .topLeading, .top, .topTrailing: .start
        case .leading, .trailing: .middle
        case .bottomLeading, .bottom, .bottomTrailing: .end
        }
    }
}
