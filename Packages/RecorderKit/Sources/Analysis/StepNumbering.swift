// SPDX-License-Identifier: GPL-3.0-or-later
import ProjectFormat

/// The numbers of the step annotations (phase 3 plan 3a, decision 9): 1, 2, 3… in the order of the sequence.
public enum StepNumbering {
    /// The number of each step by its annotation's id: by where the output first shows it, ties by `layer` and then by the
    /// order of `document.annotations.items`. A step that is cut away whole, empty or after the end of the output has no
    /// number and does not count.
    public static func numbers(in document: EditDocument, timeMap: TimeMap) -> [String: Int] {
        var steps: [(start: Int64, layer: Int, order: Int, id: String)] = []
        for (order, annotation) in document.annotations.items.enumerated() {
            guard case .step = annotation.kind,
                let range = AnnotationTiming.outputRange(of: annotation, document: document, timeMap: timeMap),
                !range.isEmpty, range.lowerBound < timeMap.duration
            else { continue }
            steps.append((range.lowerBound, annotation.layer, order, annotation.id))
        }
        steps.sort { ($0.start, $0.layer, $0.order) < ($1.start, $1.layer, $1.order) }
        var numbers: [String: Int] = [:]
        for (index, step) in steps.enumerated() where numbers[step.id] == nil { numbers[step.id] = index + 1 }
        return numbers
    }
}
