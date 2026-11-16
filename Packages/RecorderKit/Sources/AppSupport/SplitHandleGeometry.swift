// SPDX-License-Identifier: GPL-3.0-or-later
import Analysis
import ProjectFormat

/// The handle over the preview that changes the camera's size in a split (1c design §5.7): where it is, how much of the way
/// along the split the pointer says the camera has, and how it is hit. Lengths are in the space the geometry is in (output
/// pixels, origin at the top left), except `hitWidth`, which is in points.
public enum SplitHandleGeometry {
    /// The least width, along the split, the handle can be pointed at, in points: the gap between the cards can be narrower.
    public static let hitWidth = 12.0

    /// The handle: the gap between the screen's card and the camera's, along the split, and as tall (or as wide, one card
    /// above the other) as the cards together across it.
    public static func handle(geometry: LayoutGeometry, orientation: SplitOrientation) -> Rect {
        let (screen, camera) = (geometry.screen.rect, geometry.camera.rect)
        switch orientation {
        case .beside:
            let (left, right) = screen.x <= camera.x ? (screen, camera) : (camera, screen)
            let top = min(screen.y, camera.y), bottom = max(screen.y + screen.height, camera.y + camera.height)
            let start = left.x + left.width
            return Rect(x: start, y: top, width: max(right.x - start, 0), height: bottom - top)
        case .stacked:
            let (upper, lower) = screen.y <= camera.y ? (screen, camera) : (camera, screen)
            let left = min(screen.x, camera.x), right = max(screen.x + screen.width, camera.x + camera.width)
            let start = upper.y + upper.height
            return Rect(x: left, y: start, width: right - left, height: max(lower.y - start, 0))
        }
    }

    /// `handle` made at least `hitWidth` points wide along the split, around its middle, where a point of the output is
    /// `pointsPerUnit` points of the view.
    public static func hitRect(of handle: Rect, orientation: SplitOrientation, pointsPerUnit: Double) -> Rect {
        guard pointsPerUnit > 0 else { return handle }
        let least = hitWidth / pointsPerUnit
        switch orientation {
        case .beside:
            let width = max(handle.width, least)
            return Rect(x: handle.x + (handle.width - width) / 2, y: handle.y, width: width, height: handle.height)
        case .stacked:
            let height = max(handle.height, least)
            return Rect(x: handle.x, y: handle.y + (handle.height - height) / 2, width: handle.width, height: height)
        }
    }

    /// The camera's part of the length along the split when the handle is at `pointer` (output pixels): the gap's middle
    /// follows the pointer 1:1, so the camera has what is between the pointer and the end of the useful area on its side,
    /// less half the gap, out of the length the cards share (`CameraLayoutGeometry`'s `L`); kept in `SplitLayout.shareRange`.
    public static func share(
        pointer: SIMD2<Double>, output: SIMD2<Double>, padding: Double, orientation: SplitOrientation, side: CameraSide
    ) -> Double {
        let area = StageLayout.screenRect(contentAspect: nil, padding: padding, outputSize: output)
        let gap = CameraLayoutGeometry.gapFraction * min(output.x, output.y)
        let (start, along, position) = orientation == .beside ? (area.x, area.width, pointer.x) : (area.y, area.height, pointer.y)
        let length = along - gap
        guard length > 0 else { return SplitLayout.shareRange.lowerBound }
        let camera = side == .end ? start + along - (position + gap / 2) : position - gap / 2 - start
        return min(max(camera / length, SplitLayout.shareRange.lowerBound), SplitLayout.shareRange.upperBound)
    }

    /// `rect` (output pixels) in stage units, the preview overlay's: the stage is 1 tall, so every length over the output's
    /// height. The zoom's box, in a split, is drawn over the screen's card.
    public static func stageUnits(_ rect: Rect, output: SIMD2<Double>) -> Rect {
        guard output.y > 0 else { return rect }
        return Rect(x: rect.x / output.y, y: rect.y / output.y, width: rect.width / output.y, height: rect.height / output.y)
    }

    /// The label of the handle while it is dragged: "34 %", the share in whole percent.
    public static func percent(_ share: Double) -> Int {
        Int((share * 100).rounded())
    }
}
