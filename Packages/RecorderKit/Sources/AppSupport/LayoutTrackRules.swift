// SPDX-License-Identifier: GPL-3.0-or-later
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
}
