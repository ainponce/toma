// SPDX-License-Identifier: GPL-3.0-or-later
import CoreGraphics

/// The top of a screen as the island sees it, in AppKit coordinates (`NSScreen.frame`).
public struct ScreenTop: Equatable, Sendable {
    public var frame: CGRect
    /// The camera housing, on the built-in display of a MacBook with one.
    public var notch: CGRect?
    /// In points: the notch's height on a screen with one.
    public var menuBarHeight: Double

    public init(frame: CGRect, notch: CGRect? = nil, menuBarHeight: Double) {
        self.frame = frame
        self.notch = notch
        self.menuBarHeight = menuBarHeight
    }

    /// From `NSScreen`: `safeAreaInsets.top`, `auxiliaryTopLeftArea` and `auxiliaryTopRightArea`, the parts
    /// of the menu bar on each side of the notch. With an inset and both areas there is a notch between
    /// them, as high as the inset, which is also the menu bar's height; otherwise there is no notch and
    /// `menuBarHeight` is the one given (the app passes `frame.maxY − visibleFrame.maxY`, 24 at least).
    public static func make(
        frame: CGRect, safeAreaTop: Double, auxiliaryTopLeft: CGRect?, auxiliaryTopRight: CGRect?, menuBarHeight: Double
    ) -> ScreenTop {
        guard safeAreaTop > 0, let left = auxiliaryTopLeft, let right = auxiliaryTopRight else {
            return ScreenTop(frame: frame, notch: nil, menuBarHeight: menuBarHeight)
        }
        // The areas run from the screen's edges to the notch. Measured by their widths, the notch is the same
        // whether AppKit gives the areas in global or in screen coordinates.
        let width = Double(frame.width - left.width - right.width)
        guard width > 0 else { return ScreenTop(frame: frame, notch: nil, menuBarHeight: menuBarHeight) }
        let notch = CGRect(x: frame.minX + left.width, y: frame.maxY - safeAreaTop, width: width, height: safeAreaTop)
        return ScreenTop(frame: frame, notch: notch, menuBarHeight: safeAreaTop)
    }
}

/// The island's outline: its size and the radius of its bottom corners; its top corners are square
/// under the notch and as round as the bottom ones on a pill.
public struct IslandShape: Equatable, Sendable {
    public var width: Double
    public var height: Double
    public var bottomRadius: Double
    public var roundsTopCorners: Bool

    public init(width: Double, height: Double, bottomRadius: Double, roundsTopCorners: Bool) {
        self.width = width
        self.height = height
        self.bottomRadius = bottomRadius
        self.roundsTopCorners = roundsTopCorners
    }
}

/// Where the island is and how big, for each state (notch design §5.1, sizes and radii from the
/// prototype). Under a notch it grows down from it; on a screen without one it is a pill
/// `pillTopInset` below the top.
public enum IslandGeometry {
    public static let pillTopInset = 38.0
    /// The width of each recording wing beside the notch: the time on the left, the microphone on the right.
    public static let wingWidth = 84.0
    /// Under a notch, the peek's band below the menu bar: room for its row with 9 pt above and below.
    public static let peekBand = 36.0
    /// Under a notch, the peek is never narrower than this, so its row has 24 pt on each side.
    public static let peekMinWidth = 248.0
    /// The hover zone at the top center of a screen without a notch.
    public static let hoverZoneSize = CGSize(width: 60, height: 8)

    public static func shape(_ state: IslandState, on top: ScreenTop) -> IslandShape {
        // Under a notch.
        let notchWidth = top.notch.map { Double($0.width) } ?? 0
        let (width, height, radius): (Double, Double, Double) =
            switch state {
            case .rest: (notchWidth, top.menuBarHeight, 13)
            // A band of `peekBand` under the notch, wide enough for its row whatever the notch's width.
            case .peek: (max(notchWidth + 64, peekMinWidth), top.menuBarHeight + peekBand, 18)
            case .open: (700, 400, 34)
            case .choosing: (560, 48, 24)
            case .countdown: (236, 214, 62)
            // A wing at each side of the notch, whatever its width.
            case .recording: (notchWidth + 2 * wingWidth, top.menuBarHeight, 13)
            case .recordingOpen: (640, 226, 34)
            // 40 pt under the menu bar: no more than the area below the notch.
            case .notice: (360, top.menuBarHeight + 40, 20)
            case .saving, .saved: (490, 140, 32)
            }
        guard top.notch == nil else {
            return IslandShape(width: width, height: height, bottomRadius: radius, roundsTopCorners: false)
        }
        // A pill: the states that grow out of the notch have a size of their own, the others keep theirs,
        // and every corner is round.
        let (pillWidth, pillHeight): (Double, Double) =
            switch state {
            case .rest: (132, 34)
            case .peek: (262, 38)
            case .recording: (300, 36)
            case .open, .choosing, .countdown, .recordingOpen, .notice, .saving, .saved: (width, height)
            }
        return IslandShape(width: pillWidth, height: pillHeight, bottomRadius: min(radius + 4, pillHeight / 2), roundsTopCorners: true)
    }

    /// Centered on the screen, with its top edge at the top of the screen (under a notch) or
    /// `pillTopInset` below it (a pill). AppKit coordinates.
    public static func frame(_ shape: IslandShape, on top: ScreenTop) -> CGRect {
        let topEdge = Double(top.frame.maxY) - (top.notch == nil ? pillTopInset : 0)
        return CGRect(
            x: Double(top.frame.midX) - shape.width / 2, y: topEdge - shape.height, width: shape.width, height: shape.height)
    }

    /// Where the pointer makes the island peek: the notch, or `hoverZoneSize` at the top center.
    public static func hoverZone(on top: ScreenTop) -> CGRect {
        if let notch = top.notch { return notch }
        return CGRect(
            x: top.frame.midX - hoverZoneSize.width / 2, y: top.frame.maxY - hoverZoneSize.height,
            width: hoverZoneSize.width, height: hoverZoneSize.height)
    }

    /// The spring the island's outline takes toward `state`.
    public static func spring(to state: IslandState) -> Spring {
        switch state {
        case .open, .choosing, .countdown, .recordingOpen, .notice, .saving, .saved: Motion.islandExpand
        case .peek: Motion.islandPeek
        case .rest, .recording: Motion.islandCollapse
        }
    }
}
