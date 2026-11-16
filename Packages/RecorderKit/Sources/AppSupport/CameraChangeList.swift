// SPDX-License-Identifier: GPL-3.0-or-later
import Editing
import ProjectFormat

/// One line of the Camera tab's list of changes (design §5.4): the change, where it falls in the output, and the style it
/// switches to. The app words it ("0:42 · Circle, medium, top left").
public struct CameraChangeRow: Equatable, Sendable {
    public var id: String
    /// Output nanoseconds.
    public var output: Int64
    public var style: CameraStyle

    public init(id: String, output: Int64, style: CameraStyle) {
        self.id = id
        self.output = output
        self.style = style
    }
}

/// What the Camera tab edits at the playhead: the take's initial style, or the change that rules there.
public enum CameraEditTarget: Equatable, Sendable {
    case initial
    /// The change `id`, which falls at output nanosecond `output` (where the list shows it).
    case change(id: String, output: Int64)
}

/// The Camera tab's list and what it edits (design §5.4), as pure functions of the document.
public enum CameraChangeList {
    /// The changes that are seen, in output order (those in a cut are not in the list; two at one instant keep the order
    /// of the document).
    public static func rows(_ doc: EditDocument, timeMap: TimeMap) -> [CameraChangeRow] {
        doc.camera.changes.enumerated().compactMap { index, change -> (Int, CameraChangeRow)? in
            timeMap.output(atSource: change.t, take: change.take).map { (index, CameraChangeRow(id: change.id, output: $0, style: change.style)) }
        }
        .sorted { ($0.1.output, $0.0) < ($1.1.output, $1.0) }
        .map(\.1)
    }

    /// What the panel edits with the playhead at `atOutput`: the style that rules there (`TrackCommands.rulingCameraStyle`).
    /// A change that rules from a cut shows at the first instant kept after it.
    public static func editing(_ doc: EditDocument, atOutput: Int64, timeMap: TimeMap) -> CameraEditTarget {
        guard let id = TrackCommands.rulingCameraStyle(doc, atOutput: atOutput, timeMap: timeMap).changeID,
            let change = doc.camera.changes.first(where: { $0.id == id })
        else { return .initial }
        return .change(id: id, output: timeMap.output(ofChangeAt: change.t, take: change.take) ?? 0)
    }
}

/// The Camera tab's 3×3 grid of places (design §5.4): the 8 anchors around a centre that is not one.
public enum CameraAnchorGrid {
    /// The anchors by row, top to bottom, and in each row left to right; `nil` is the centre.
    public static let rows: [[CameraAnchor?]] = [
        [.topLeading, .top, .topTrailing],
        [.leading, nil, .trailing],
        [.bottomLeading, .bottom, .bottomTrailing],
    ]

    /// The anchor that an arrow key takes the bubble to from `anchor`: one step along `dx` (-1 left, 1 right) and `dy` (-1
    /// up, 1 down), over the centre if that is where it lands; `anchor` itself at the edge of the grid.
    public static func neighbor(of anchor: CameraAnchor, dx: Int, dy: Int) -> CameraAnchor {
        guard let row = rows.firstIndex(where: { $0.contains(anchor) }), let column = rows[row].firstIndex(of: anchor) else { return anchor }
        var (r, c) = (row + dy, column + dx)
        while rows.indices.contains(r), rows[r].indices.contains(c) {
            if let found = rows[r][c] { return found }
            (r, c) = (r + dy, c + dx)
        }
        return anchor
    }
}
