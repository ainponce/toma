// SPDX-License-Identifier: GPL-3.0-or-later
import ProjectFormat

/// A row of the timeline's audio.
public enum AudioRowID: Hashable, Sendable {
    /// An audio track by `TrackRecord.id`, in every take.
    case track(String)
    case importedClips
    case music
}

/// Solo (phase 3 design §7.2, plan 3c decision 11): which rows the preview lets be heard, several at once. An aid of the
/// preview only: it is not saved and the export never sees it.
public struct AudioSolo: Equatable, Sendable {
    public var rows: Set<AudioRowID>

    public init(rows: Set<AudioRowID> = []) {
        self.rows = rows
    }

    public var isEmpty: Bool { rows.isEmpty }

    /// `doc` as the preview's mix hears it with this solo: the same document when `isEmpty`; otherwise everything not in
    /// `rows` is silenced without touching what the ducking reads (a track's `muted` and `gain`, `music.ducking`):
    /// - each audio track of a take the sequence shows gets a stretch at −∞ over its whole take (replacing its own stretches,
    ///   which the ducking does not read), keeping its gain, whether it is muted and its cleanup,
    /// - each piece of music goes to −∞ dB,
    /// - each imported clip of the sequence goes to −∞ dB and each clip annotation is muted.
    public func applied(to doc: EditDocument, takes: [TakeRecord]) -> EditDocument {
        guard !rows.isEmpty else { return doc }
        var result = doc
        var seen: Set<String> = []
        let shown = doc.sequence.compactMap { seen.insert($0.take).inserted ? $0.take : nil }
        var number = 0
        for take in takes where seen.contains(take.id) {
            for track in take.tracks where !track.kind.isVideo && !track.segments.isEmpty && !rows.contains(.track(track.id)) {
                let key = AudioPlan.key(take: take.id, track: track.id)
                var held = doc.audio.tracks[key] ?? doc.audio.trackGain(take: take.id, track: track.id, takes: shown)
                    ?? TrackGain(gain: 1, muted: false)
                number += 1
                held.ranges = [
                    GainRange(
                        id: "g-" + String(repeating: "0", count: 8 - String(number, radix: 16).count) + String(number, radix: 16),
                        take: take.id, start: HostTime(nanoseconds: 0), end: HostTime(nanoseconds: .max), gain: GainRange.silence)
                ]
                result.audio.tracks[key] = held
            }
        }
        if !rows.contains(.music) {
            for k in result.music.items.indices { result.music.items[k].gain = GainRange.silence }
        }
        if !rows.contains(.importedClips) {
            for k in result.sequence.indices {
                guard case var .media(media) = result.sequence[k].content else { continue }
                media.volume = GainRange.silence
                result.sequence[k].content = .media(media)
            }
            for k in result.annotations.items.indices {
                guard case var .clip(clip) = result.annotations.items[k].kind else { continue }
                clip.muted = true
                result.annotations.items[k].kind = .clip(clip)
            }
        }
        return result
    }
}
