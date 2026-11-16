// SPDX-License-Identifier: GPL-3.0-or-later
import Analysis
import Editing
import ProjectFormat

/// The rules of the Camera track that are not a command (1c design §5.5): where and what a new layout block is.
public enum LayoutTrackRules {
    /// The block a double click, the Layout menu or the shortcut makes. It starts at the click, or at the playhead without
    /// one, and lasts `LayoutCommands.defaultDuration` (`LayoutCommands.add(at:)` clips it to the free space); with a marked
    /// range (I and O, and no click) it takes that range, and `start` is its beginning. Its layout is the last one chosen
    /// for a block of the project, or `LayoutCommands.firstKind` the first time. `range` is `nil` when `start` is what counts.
    public static func newBlock(
        playhead: Int64, click: Int64?, marks: Range<Int64>?, lastKind: LayoutKind?
    ) -> (start: Int64, range: Range<Int64>?, kind: LayoutKind) {
        let kind = lastKind ?? LayoutCommands.firstKind
        if click == nil, let marks, !marks.isEmpty { return (marks.lowerBound, marks, kind) }
        return (click ?? playhead, nil, kind)
    }

    // MARK: - Drawing and dragging

    /// How much of its color a camera change's diamond keeps inside a block, where it is not seen while the block rules
    /// (design §5.5).
    public static let dimmedDiamondOpacity = 0.4

    /// The block a drag from output instant `a` to `b` in an empty place of the Camera track makes, in either direction,
    /// cut to the output; `nil` while it is shorter than `LayoutCommands.minimumDuration` (0.5 s).
    public static func creationRange(from a: Int64, to b: Int64, duration: Int64) -> Range<Int64>? {
        TimelineDragRules.creationRange(from: a, to: b, duration: duration, minimum: LayoutCommands.minimumDuration)
    }

    /// Where the camera is in a block's label (design §5.5, "Dividida · cámara a la derecha").
    public enum LabelSide: Equatable, Sendable {
        case left, right, top, bottom
    }

    /// The side of the camera a split block's label says: left and right side by side, top and bottom one above the other;
    /// `start` is the left or the top.
    public static func labelSide(_ side: CameraSide, orientation: SplitOrientation) -> LabelSide {
        switch (orientation, side) {
        case (.beside, .start): .left
        case (.beside, .end): .right
        case (.stacked, .start): .top
        case (.stacked, .end): .bottom
        }
    }

    /// The SF Symbol of a layout (plan decision 12); the split's is the one of how its cards sit.
    public static func symbol(_ kind: LayoutKind, orientation: SplitOrientation) -> String {
        switch kind {
        case .bubble: "pip"
        case .screenOnly: "rectangle"
        case .split: orientation == .beside ? "rectangle.split.2x1" : "rectangle.split.1x2"
        case .cameraOnly: "person.crop.rectangle"
        case .cameraFull: "person.crop.rectangle.fill"
        }
    }

    /// The camera of `take` can be read (plan decision 40): some camera track has a segment `availability` finds present.
    /// A take without a camera track has none to read.
    public static func cameraReadable(take: TakeRecord, availability: (SegmentRecord) -> SegmentAvailability) -> Bool {
        take.tracks.contains { $0.kind == .camera && $0.segments.contains { availability($0) == .present } }
    }
}
