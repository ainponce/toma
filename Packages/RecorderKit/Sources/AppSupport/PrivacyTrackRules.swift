// SPDX-License-Identifier: GPL-3.0-or-later
import Editing
import ProjectFormat

/// What the timeline's Privacy track shows (phase 2 design §7.1, plan 2c decision 4): each privacy block where the output
/// shows it (`PrivacyCommands.outputRange`, the cuts inside it closed; one all in a cut is not there). The blocks may
/// overlap, so they are drawn one over another, the longest at the bottom: the one under the pointer is then the shortest
/// there, the last `TimelineHitTest` finds.
public enum PrivacyTrackRules {
    /// The blocks of `doc` the output shows, on `.privacy`, the longest first (of the same length, in the document's
    /// order): the order they are drawn in, bottom to top, and pointed at.
    public static func items(_ doc: EditDocument) -> [TimelineItem] {
        let shown = doc.privacy.blocks.enumerated().compactMap { k, block -> (k: Int, item: TimelineItem)? in
            guard let output = PrivacyCommands.outputRange(of: block, in: doc), !output.isEmpty else { return nil }
            return (k, TimelineItem(id: block.id, track: .privacy, output: output))
        }
        return shown.sorted { a, b in
            let (la, lb) = (a.item.output.upperBound - a.item.output.lowerBound, b.item.output.upperBound - b.item.output.lowerBound)
            return la != lb ? la > lb : a.k < b.k
        }.map(\.item)
    }
}
