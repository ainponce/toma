// SPDX-License-Identifier: GPL-3.0-or-later
import ProjectFormat

/// How much of the voice isolated from the noise goes into the mix (phase 2 design §5.6): the three levels the Audio tab
/// offers. `rawValue` is what `TrackGain.cleanup` holds.
public enum CleanupLevel: Double, CaseIterable, Sendable {
    case off = 0
    case gentle = 0.6
    case strong = 1

    /// The level nearest to `cleanup`; the lower one at a tie, `.off` for a number that is not one.
    public init(cleanup: Double) {
        var best = CleanupLevel.off
        guard !cleanup.isNaN else { self = best; return }
        for level in Self.allCases where abs(level.rawValue - cleanup) < abs(best.rawValue - cleanup) { best = level }
        self = best
    }
}

/// The commands of the voice features that are one value of the document (phase 2 design §5.5 to §5.9): whether the
/// captions show and how they look, the cleanup and loudness of the sound, and the camera's sync, as pure functions of
/// the document. Each gives the step that does it (`EditStep`), or `nil` when nothing changes. The `target` of a step is
/// the pointer of what it sets, so a burst on one control is one undo group.
public enum VoiceCommands {
    /// The camera's sync offset, in milliseconds.
    public static let syncRange: ClosedRange<Int> = -300...300
    /// The sync offset moves in steps of this many milliseconds.
    public static let syncStep = 10

    /// Whether the captions show.
    public static func setCaptionsShow(_ doc: EditDocument, _ show: Bool) -> EditStep? {
        var changes = DocumentChanges()
        changes.set(["captions", "show"], from: doc.captions.show, to: show)
        return changes.step(label: .captionsShow, target: "/captions/show")
    }

    /// The captions' style, whole.
    public static func setCaptionStyle(_ doc: EditDocument, _ style: CaptionStyle) -> EditStep? {
        var changes = DocumentChanges()
        changes.set(["captions", "style"], from: doc.captions.style, to: style)
        return changes.step(label: .captionsStyle, target: "/captions/style")
    }

    /// The captions' preset; the spoken word's highlight goes with it: on in Bold, off in the others (one step).
    public static func setCaptionPreset(_ doc: EditDocument, _ preset: CaptionPreset) -> EditStep? {
        var style = doc.captions.style
        style.preset = preset
        style.highlight = preset == .bold
        var changes = DocumentChanges()
        changes.set(["captions", "style", "preset"], from: doc.captions.style.preset, to: style.preset)
        changes.set(["captions", "style", "highlight"], from: doc.captions.style.highlight, to: style.highlight)
        return changes.step(label: .captionsStyle, target: "/captions/style/preset")
    }

    /// How much cleanup the track `key` (`AudioPlan.key(take:track:)`) gets. A track `audio.tracks` does not name is added
    /// with a gain of 1, not muted (a `set` cannot add a key, so its parent is set); that is nothing for `.off`.
    public static func setCleanup(_ doc: EditDocument, track key: String, _ level: CleanupLevel) -> EditStep? {
        var changes = DocumentChanges()
        if let gain = doc.audio.tracks[key] {
            changes.set(["audio", "tracks", key, "cleanup"], from: gain.cleanup, to: level.rawValue)
        } else {
            guard level != .off else { return nil }
            var tracks = doc.audio.tracks
            tracks[key] = TrackGain(gain: 1, muted: false, cleanup: level.rawValue)
            changes.set(["audio", "tracks"], from: doc.audio.tracks, to: tracks)
        }
        return changes.step(label: .audioCleanup, target: JSONPointer(components: ["audio", "tracks", key, "cleanup"]).string)
    }

    /// Whether every track is brought to its target loudness.
    public static func setNormalize(_ doc: EditDocument, _ on: Bool) -> EditStep? {
        var changes = DocumentChanges()
        changes.set(["audio", "normalize"], from: doc.audio.normalize, to: on)
        return changes.step(label: .audioNormalize, target: "/audio/normalize")
    }

    /// The camera's sync offset: `milliseconds` rounded to `syncStep` and kept within `syncRange`, written in ns.
    public static func setSyncOffset(_ doc: EditDocument, milliseconds: Int) -> EditStep? {
        let stepped = Int((Double(milliseconds) / Double(syncStep)).rounded()) * syncStep
        let clamped = min(max(stepped, syncRange.lowerBound), syncRange.upperBound)
        var changes = DocumentChanges()
        changes.set(["camera", "syncOffset"], from: doc.camera.syncOffset, to: Int64(clamped) * 1_000_000)
        return changes.step(label: .cameraSync, target: "/camera/syncOffset")
    }
}
