// SPDX-License-Identifier: GPL-3.0-or-later
import CoreGraphics
import ProjectFormat

/// The proportion an area is drawn with (the area bar's Free · 16:9 · 9:16 · 1:1 · 4:3).
public enum AspectLock: String, Codable, Sendable, CaseIterable {
    case free, wide16x9, tall9x16, square, classic4x3

    /// Width over height; `nil` when free.
    public var ratio: Double? {
        switch self {
        case .free: nil
        case .wide16x9: 16.0 / 9
        case .tall9x16: 9.0 / 16
        case .square: 1
        case .classic4x3: 4.0 / 3
        }
    }

    /// The proportion `rect` has, as `AreaDrag` draws it (its height is its width over the ratio, rounded to the
    /// nearest point); `.free` when it has none of them.
    public static func matching(_ rect: Rect) -> AspectLock {
        allCases.first { lock in
            guard let ratio = lock.ratio else { return false }
            return (rect.width / ratio).rounded() == rect.height
        } ?? .free
    }
}

/// Drawing and moving an area on the screen (Area mode, "Draw on Screen"), in whole global points.
public enum AreaDrag {
    /// No side of an area is shorter.
    public static let minimumSide = 64.0

    /// The area of a drag from `start` to `current` (global points) on `display`: anchored at `start`, growing
    /// toward the drag. With a proportion the width leads and the height is rounded to the nearest point. What does
    /// not fit on the display is cut: with a proportion both sides shrink, without one each side stops at the edge.
    /// No side is shorter than `minimumSide` (with a proportion, the shorter one); when that does not fit from the
    /// anchor, the area moves inside the display.
    public static func rect(from start: CGPoint, to current: CGPoint, within display: Rect, lock: AspectLock) -> Rect {
        let bounds = Bounds(display)
        let anchorX = min(max(Double(start.x).rounded(), bounds.minX), bounds.maxX)
        let anchorY = min(max(Double(start.y).rounded(), bounds.minY), bounds.maxY)
        let pointerX = Double(current.x).rounded()
        let pointerY = Double(current.y).rounded()
        let growsRight = pointerX >= anchorX
        let growsDown = pointerY >= anchorY
        let roomX = growsRight ? bounds.maxX - anchorX : anchorX - bounds.minX
        let roomY = growsDown ? bounds.maxY - anchorY : anchorY - bounds.minY

        var width = abs(pointerX - anchorX)
        var height = abs(pointerY - anchorY)
        if let ratio = lock.ratio {
            width = min(width, roomX)
            height = (width / ratio).rounded()
            if height > roomY {
                // Rounded down, so the height it gives is never more than the room.
                width = (roomY * ratio).rounded(.down)
                height = (width / ratio).rounded()
            }
            let smallest = smallestSize(ratio: ratio)
            if width < smallest.width || height < smallest.height { (width, height) = smallest }
        } else {
            width = max(min(width, roomX), minimumSide)
            height = max(min(height, roomY), minimumSide)
        }
        width = min(width, bounds.maxX - bounds.minX)
        height = min(height, bounds.maxY - bounds.minY)
        let x = growsRight ? anchorX : anchorX - width
        let y = growsDown ? anchorY : anchorY - height
        return bounds.inside(Rect(x: x, y: y, width: width, height: height))
    }

    /// `area` moved by `offset` (rounded to whole points), kept inside `display`.
    public static func moved(_ area: Rect, by offset: CGVector, within display: Rect) -> Rect {
        let moved = Rect(
            x: (area.x + Double(offset.dx)).rounded(), y: (area.y + Double(offset.dy)).rounded(), width: area.width, height: area.height)
        return Bounds(display).inside(moved)
    }

    /// The smallest area of `ratio`: `minimumSide` on its shorter side.
    private static func smallestSize(ratio: Double) -> (width: Double, height: Double) {
        let width = max(minimumSide, (minimumSide * ratio).rounded(.up))
        return (width, (width / ratio).rounded())
    }

    /// A display's edges, in whole points.
    private struct Bounds {
        let minX, minY, maxX, maxY: Double

        init(_ display: Rect) {
            minX = display.x.rounded(.up)
            minY = display.y.rounded(.up)
            maxX = max((display.x + display.width).rounded(.down), minX)
            maxY = max((display.y + display.height).rounded(.down), minY)
        }

        /// `rect` moved, not resized, so as much of it as can be is inside: its top left edge when it is larger.
        func inside(_ rect: Rect) -> Rect {
            var rect = rect
            rect.x = max(min(rect.x, maxX - rect.width), minX)
            rect.y = max(min(rect.y, maxY - rect.height), minY)
            return rect
        }
    }
}
