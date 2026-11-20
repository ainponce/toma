// SPDX-License-Identifier: GPL-3.0-or-later
import Analysis
import Foundation
import ProjectFormat

/// What accepting chapters did (milestone 5b, plan decision 10).
public struct ChapterAddition: Equatable, Sendable {
    public let step: EditStep
    /// New markers (`origin: .added`).
    public let added: Int
    /// Markers without a name that took the chapter's name.
    public let named: Int
    /// Chapters on a marker with a name, second on a frame, or where the output shows nothing.
    public let skipped: Int

    public init(step: EditStep, added: Int, named: Int, skipped: Int) {
        self.step = step
        self.added = added
        self.named = named
        self.skipped = skipped
    }
}

/// The chapters the user accepted, as markers in one undoable step `marker.chapters` whose target is the id of the first
/// marker it touches (so two additions in a row are two undos).
public enum ChapterCommands {
    /// A chapter on the frame of a marker without a name gives it the name (its entry, made if it had none); on one with a
    /// name it is skipped; two on a frame, the first; where the output shows nothing, skipped. The rest are `added`
    /// markers with ids `makeID("m-")`. `nil` if nothing changes.
    public static func add(
        _ doc: EditDocument, _ chapters: [Chapter], timeMap: TimeMap, recorded: MarkerList.Recorded,
        makeID: (String) -> String
    ) -> ChapterAddition? {
        let frameRate = doc.frameRate, frameCount = timeMap.frameCount(frameRate: frameRate)
        var shown = MarkerList.visible(document: doc, recorded: recorded, timeMap: timeMap)
        var ids = Set(doc.markers.items.map(\.id))
        var count = doc.markers.items.count
        var changes = DocumentChanges()
        var target: String?
        var added = 0, named = 0, skipped = 0

        for chapter in chapters.enumerated().sorted(by: { ($0.element.start, $0.offset) < ($1.element.start, $1.offset) }).map(\.element) {
            let name = MarkerCommands.normalized(chapter.title)
            guard !name.isEmpty, chapter.start >= 0, chapter.start < timeMap.duration, let (clip, t) = timeMap.source(atOutput: chapter.start),
                doc.sequence.indices.contains(clip),
                let output = MarkerList.output(take: doc.sequence[clip].take, t: t, sequence: doc.sequence, timeMap: timeMap)
            else {
                skipped += 1
                continue
            }
            let take = doc.sequence[clip].take
            let frame = frameOf(output, frameRate: frameRate, frameCount: frameCount)
            let there = shown.enumerated().filter {
                frameOf($0.element.output, frameRate: frameRate, frameCount: frameCount) == frame
            }
            if there.contains(where: { !$0.element.name.isEmpty }) {
                skipped += 1
                continue
            }
            if let (index, marker) = there.first.map({ ($0.offset, $0.element) }) {
                let id: String
                if let entryID = marker.entryID, let at = doc.markers.items.firstIndex(where: { $0.id == entryID }) {
                    var entry = doc.markers.items[at]
                    entry.name = name
                    changes.replace(doc.markers.items[at], with: entry, in: .markers, id: entryID)
                    id = entryID
                } else {
                    id = DocumentIDs.new("m-", makeID, avoiding: &ids)
                    changes.insert(
                        Marker(id: id, take: marker.take, t: marker.t, name: name, origin: .recorded), into: .markers, at: count)
                    count += 1
                }
                shown[index] = VisibleMarker(
                    id: id, entryID: id, take: marker.take, t: marker.t, name: name, origin: marker.origin, output: marker.output)
                target = target ?? id
                named += 1
            } else {
                let id = DocumentIDs.new("m-", makeID, avoiding: &ids)
                changes.insert(Marker(id: id, take: take, t: t, name: name, origin: .added), into: .markers, at: count)
                count += 1
                shown.append(VisibleMarker(id: id, entryID: id, take: take, t: t, name: name, origin: .added, output: output))
                target = target ?? id
                added += 1
            }
        }
        guard let target, let step = changes.step(label: .markerChapters, target: target) else { return nil }
        return ChapterAddition(step: step, added: added, named: named, skipped: skipped)
    }

    private static func frameOf(_ output: Int64, frameRate: Int, frameCount: Int) -> Int {
        let n = Int((Double(output) / 1e9 * Double(frameRate)).rounded())
        return min(max(n, 0), max(frameCount - 1, 0))
    }
}
