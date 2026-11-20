// SPDX-License-Identifier: GPL-3.0-or-later
import Analysis
import Foundation
import ProjectFormat

/// The commands of the markers (phase 3 plan 3d, decisions 1 to 3): each is one undoable step of `/markers/items`, with
/// its label and the id of its marker as the target, and `nil` if nothing changes. They never touch `events.jsonl`.
public enum MarkerCommands {
    public static let maximumNameLength = 100

    /// A marker without a name at the output time `τ` of the clip shown there (the point of the take of a clip with content),
    /// as `added`; it shows where `MarkerList.output(take:t:sequence:timeMap:)` places it: at `τ`, or where the clip with
    /// content starts. `nil` if the output has no clip, or another marker is on the frame it would show on (a marker is
    /// not added in the middle of another's frame, nor a second one on a title card).
    public static func add(
        _ doc: EditDocument, atOutput τ: Int64, timeMap: TimeMap, recorded: MarkerList.Recorded, makeID: (String) -> String
    ) -> EditStep? {
        guard let place = place(atOutput: τ, doc: doc, timeMap: timeMap),
            let output = MarkerList.output(take: place.take, t: place.t, sequence: doc.sequence, timeMap: timeMap)
        else { return nil }
        let frameRate = doc.frameRate, frameCount = timeMap.frameCount(frameRate: frameRate)
        let frame = frameOf(output, frameRate: frameRate, frameCount: frameCount)
        let shown = MarkerList.visible(document: doc, recorded: recorded, timeMap: timeMap)
        guard MarkerList.at(frame: frame, in: shown, frameRate: frameRate, frameCount: frameCount) == nil else { return nil }
        var ids = Set(doc.markers.items.map(\.id))
        let id = DocumentIDs.new("m-", makeID, avoiding: &ids)
        var changes = DocumentChanges()
        changes.insert(
            Marker(id: id, take: place.take, t: place.t, origin: .added), into: .markers, at: doc.markers.items.count)
        return changes.step(label: .markerAdd, target: id)
    }

    /// `marker` with the name `name`, trimmed and held to `maximumNameLength` characters. A recorded marker without an
    /// entry gets its entry (`recorded`, the same take and `t`); an empty name on it is nothing.
    public static func rename(
        _ doc: EditDocument, _ marker: VisibleMarker, to name: String, makeID: (String) -> String
    ) -> EditStep? {
        let name = normalized(name)
        var changes = DocumentChanges()
        if let index = entryIndex(of: marker, in: doc) {
            var entry = doc.markers.items[index]
            entry.name = name
            changes.replace(doc.markers.items[index], with: entry, in: .markers, id: entry.id)
            return changes.step(label: .markerRename, target: entry.id)
        }
        guard !name.isEmpty else { return nil }
        var ids = Set(doc.markers.items.map(\.id))
        let id = DocumentIDs.new("m-", makeID, avoiding: &ids)
        changes.insert(
            Marker(id: id, take: marker.take, t: marker.t, name: name, origin: .recorded), into: .markers,
            at: doc.markers.items.count)
        return changes.step(label: .markerRename, target: id)
    }

    /// `marker` at the output time `τ`. An added one changes its `take` and `t`; a recorded one is hidden (its entry, made
    /// if it had none) and an `added` with its name takes its place at `τ`, in one step. `nil` where it already is, or
    /// where `τ` shows nothing.
    public static func move(
        _ doc: EditDocument, _ marker: VisibleMarker, toOutput τ: Int64, timeMap: TimeMap, makeID: (String) -> String
    ) -> EditStep? {
        guard let place = place(atOutput: τ, doc: doc, timeMap: timeMap),
            place.take != marker.take || place.t != marker.t
        else { return nil }
        var changes = DocumentChanges()
        var count = doc.markers.items.count
        if marker.origin == .added {
            guard let index = entryIndex(of: marker, in: doc) else { return nil }
            var entry = doc.markers.items[index]
            (entry.take, entry.t) = (place.take, place.t)
            changes.replace(doc.markers.items[index], with: entry, in: .markers, id: entry.id)
            return changes.step(label: .markerMove, target: entry.id)
        }
        var ids = Set(doc.markers.items.map(\.id))
        hide(marker, in: doc, into: &changes, count: &count, makeID: makeID, ids: &ids)
        let id = DocumentIDs.new("m-", makeID, avoiding: &ids)
        changes.insert(
            Marker(id: id, take: place.take, t: place.t, name: marker.name, origin: .added), into: .markers, at: count)
        return changes.step(label: .markerMove, target: id)
    }

    /// Deleting `marker`: a recorded one is hidden (its entry, made if it had none), an added one is taken out.
    public static func delete(_ doc: EditDocument, _ marker: VisibleMarker, makeID: (String) -> String) -> EditStep? {
        var changes = DocumentChanges()
        if marker.origin == .added {
            guard let index = entryIndex(of: marker, in: doc) else { return nil }
            changes.remove(doc.markers.items[index], from: .markers, at: index)
            return changes.step(label: .markerDelete, target: marker.id)
        }
        var count = doc.markers.items.count
        var ids = Set(doc.markers.items.map(\.id))
        hide(marker, in: doc, into: &changes, count: &count, makeID: makeID, ids: &ids)
        return changes.step(label: .markerDelete, target: marker.id)
    }

    /// `name` without spaces and line breaks at its ends, at most `maximumNameLength` characters.
    public static func normalized(_ name: String) -> String {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        return String(trimmed.prefix(maximumNameLength))
    }

    // MARK: - Shared

    /// The change that hides a recorded marker: its entry hidden, or a new hidden one (`count` grows by it).
    private static func hide(
        _ marker: VisibleMarker, in doc: EditDocument, into changes: inout DocumentChanges, count: inout Int,
        makeID: (String) -> String, ids: inout Set<String>
    ) {
        if let index = entryIndex(of: marker, in: doc) {
            var entry = doc.markers.items[index]
            entry.hidden = true
            changes.replace(doc.markers.items[index], with: entry, in: .markers, id: entry.id)
        } else {
            let id = DocumentIDs.new("m-", makeID, avoiding: &ids)
            changes.insert(
                Marker(id: id, take: marker.take, t: marker.t, origin: .recorded, hidden: true), into: .markers, at: count)
            count += 1
        }
    }

    private static func entryIndex(of marker: VisibleMarker, in doc: EditDocument) -> Int? {
        guard let id = marker.entryID else { return nil }
        return doc.markers.items.firstIndex { $0.id == id }
    }

    /// The take and the source instant shown at output `τ`: the clip's take and the instant (its point, in a clip with
    /// content).
    private static func place(atOutput τ: Int64, doc: EditDocument, timeMap: TimeMap) -> (take: String, t: HostTime)? {
        guard let (clip, t) = timeMap.source(atOutput: τ), doc.sequence.indices.contains(clip) else { return nil }
        return (doc.sequence[clip].take, t)
    }

    private static func frameOf(_ output: Int64, frameRate: Int, frameCount: Int) -> Int {
        let n = Int((Double(output) / 1e9 * Double(frameRate)).rounded())
        return min(max(n, 0), max(frameCount - 1, 0))
    }
}
