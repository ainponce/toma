// SPDX-License-Identifier: GPL-3.0-or-later
import ProjectFormat

/// A marker as the editor shows it: the recorded ones (⌥⌘M, the island) and the ones added in the editor, minus the ones
/// hidden or cut (phase 3 plan 3d, decisions 1 and 2).
public struct VisibleMarker: Equatable, Sendable {
    /// The id of its entry in `markers.items`, or `rec-<take>-<ns>` for a recorded one without entry, which is not stored.
    public let id: String
    /// The id of its entry; `nil` for a recorded marker nobody has named, moved or hidden yet.
    public let entryID: String?
    public let take: String
    public let t: HostTime
    /// `""` has none.
    public let name: String
    public let origin: MarkerOrigin
    /// Where the output shows it, in ns.
    public let output: Int64

    public init(id: String, entryID: String?, take: String, t: HostTime, name: String, origin: MarkerOrigin, output: Int64) {
        self.id = id
        self.entryID = entryID
        self.take = take
        self.t = t
        self.name = name
        self.origin = origin
        self.output = output
    }
}

/// The list of markers the ruler, the Markers menu and the chapters read.
public enum MarkerList {
    /// The instants of the `marker` events of each take, by the take's id, in order.
    public typealias Recorded = [String: [HostTime]]

    /// The instants of the `marker` events of `events`, in order and without repeats.
    public static func recordedInstants(in events: [InputEvent]) -> [HostTime] {
        var seen = Set<HostTime>()
        return events.compactMap { event in
            guard case .marker = event.kind, seen.insert(event.t).inserted else { return nil }
            return event.t
        }
    }

    /// The id of a recorded marker that has no entry: `rec-<take>-<ns>`.
    public static func syntheticID(take: String, t: HostTime) -> String {
        "rec-\(take)-\(t.nanoseconds)"
    }

    /// The markers the output shows, by output time (ties by id): each recorded instant without an entry as a marker
    /// without a name; with an entry of origin `recorded` and the same take and `t`, that entry (nothing if it is
    /// hidden); and each added entry that is not hidden. Those whose instant is cut have no output and are left out.
    public static func visible(document: EditDocument, recorded: Recorded, timeMap: TimeMap) -> [VisibleMarker] {
        struct Key: Hashable {
            let take: String
            let t: HostTime
        }
        var recordedEntries: [Key: Marker] = [:]
        for entry in document.markers.items where entry.origin == .recorded {
            let key = Key(take: entry.take, t: entry.t)
            // The first entry of a place rules, so a document edited by hand never shows two.
            if recordedEntries[key] == nil { recordedEntries[key] = entry }
        }
        var result: [VisibleMarker] = []
        var shown = Set<String>()
        func show(_ id: String, entry: Marker?, take: String, t: HostTime, name: String, origin: MarkerOrigin) {
            guard let output = timeMap.output(atSource: t, take: take), shown.insert(id).inserted else { return }
            result.append(
                VisibleMarker(id: id, entryID: entry?.id, take: take, t: t, name: name, origin: origin, output: output))
        }
        for take in recorded.keys.sorted() {
            for t in recorded[take] ?? [] {
                if let entry = recordedEntries[Key(take: take, t: t)] {
                    if !entry.hidden { show(entry.id, entry: entry, take: take, t: t, name: entry.name, origin: .recorded) }
                } else {
                    show(syntheticID(take: take, t: t), entry: nil, take: take, t: t, name: "", origin: .recorded)
                }
            }
        }
        for entry in document.markers.items where !entry.hidden {
            // A recorded entry is shown through its instant above; one whose instant is not in `recorded` stands alone.
            if entry.origin == .recorded, recorded[entry.take]?.contains(entry.t) == true { continue }
            show(entry.id, entry: entry, take: entry.take, t: entry.t, name: entry.name, origin: entry.origin)
        }
        return result.sorted { ($0.output, $0.id) < ($1.output, $1.id) }
    }

    /// The nearest marker before (`forward` false) or after the frame `frame`, not the one under it: by the frame each
    /// is shown on, within `frameCount` frames at `frameRate`.
    public static func neighbor(
        of frame: Int, forward: Bool, in markers: [VisibleMarker], frameRate: Int, frameCount: Int
    ) -> VisibleMarker? {
        let framed = markers.map { (marker: $0, frame: Self.frame(of: $0, frameRate: frameRate, frameCount: frameCount)) }
        if forward {
            return framed.filter { $0.frame > frame }.min { ($0.frame, $0.marker.output) < ($1.frame, $1.marker.output) }?.marker
        }
        return framed.filter { $0.frame < frame }.max { ($0.frame, $0.marker.output) < ($1.frame, $1.marker.output) }?.marker
    }

    /// The marker shown on frame `frame` (the first, if two are on it); `nil` if none.
    public static func at(frame: Int, in markers: [VisibleMarker], frameRate: Int, frameCount: Int) -> VisibleMarker? {
        markers.first { Self.frame(of: $0, frameRate: frameRate, frameCount: frameCount) == frame }
    }

    /// The frame nearest the marker's output, held to the output's frames.
    static func frame(of marker: VisibleMarker, frameRate: Int, frameCount: Int) -> Int {
        let n = Int((Double(marker.output) / 1e9 * Double(frameRate)).rounded())
        return min(max(n, 0), max(frameCount - 1, 0))
    }
}
