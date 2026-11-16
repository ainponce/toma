// SPDX-License-Identifier: GPL-3.0-or-later
import Analysis
import Editing
import ProjectFormat

/// What the Camera tab's layout controls edit (design §5.6, "Se edita:").
public enum LayoutEditTarget: Equatable, Sendable {
    /// The block `id`, which starts at output nanosecond `output`.
    case block(id: String, output: Int64)
    /// The project's layout, which rules outside the blocks.
    case project
}

/// What the Camera tab's bubble controls (shape, size and place) edit.
public enum BubbleEditTarget: Equatable, Sendable {
    /// The style of the Bubble block `id`, which starts at output nanosecond `output`.
    case block(id: String, output: Int64)
    /// The take's initial style (1b).
    case initial
    /// The change `id` that rules at the playhead, shown at output nanosecond `output` (1b).
    case change(id: String, output: Int64)
}

/// The blank of each group of controls, as pure functions of the document, the selection and the playhead.
public enum CameraTabTargets {
    /// The layout controls edit the selected block, if it is shown on the track, and the project's layout if not.
    public static func layout(_ doc: EditDocument, selectedBlock: String?, timeMap: TimeMap) -> LayoutEditTarget {
        guard let selectedBlock, let output = blockStart(doc, id: selectedBlock, timeMap: timeMap) else { return .project }
        return .block(id: selectedBlock, output: output)
    }

    /// The bubble controls edit the style of the selected block if it is a Bubble, or else of the Bubble block under the
    /// playhead (with no selected block); outside those, what 1b edits (`CameraChangeList.editing`).
    public static func bubble(_ doc: EditDocument, selectedBlock: String?, atOutput: Int64, timeMap: TimeMap) -> BubbleEditTarget {
        if let selectedBlock {
            if let block = doc.camera.layouts.first(where: { $0.id == selectedBlock }), block.kind == .bubble,
                let output = blockStart(doc, id: selectedBlock, timeMap: timeMap)
            {
                return .block(id: selectedBlock, output: output)
            }
        } else if let block = LayoutCommands.block(atOutput: atOutput, in: doc, timeMap: timeMap), block.kind == .bubble,
            let output = blockStart(doc, id: block.id, timeMap: timeMap)
        {
            return .block(id: block.id, output: output)
        }
        switch CameraChangeList.editing(doc, atOutput: atOutput, timeMap: timeMap) {
        case .initial: return .initial
        case let .change(id, output): return .change(id: id, output: output)
        }
    }

    private static func blockStart(_ doc: EditDocument, id: String, timeMap: TimeMap) -> Int64? {
        guard let k = doc.camera.layouts.firstIndex(where: { $0.id == id }) else { return nil }
        return LayoutTimeline.blockOutputs(of: doc, timeMap: timeMap)[k]?.lowerBound
    }
}
