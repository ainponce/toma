// SPDX-License-Identifier: GPL-3.0-or-later
import AppKit
import ProjectFormat

/// One track of system audio a take records: its id, the apps it takes, and the one app it is of, if it is an app's.
public struct SystemAudioTrackPlan: Equatable, Sendable {
    public var trackID: String
    public var scope: SystemAudioScope
    /// The app of a track of one app (`TrackRecord.appBundleID`); `nil` in a track of every app or of several.
    public var appBundleID: String?

    public init(trackID: String, scope: SystemAudioScope, appBundleID: String?) {
        self.trackID = trackID
        self.scope = scope
        self.appBundleID = appBundleID
    }
}

/// The tracks of system audio of a take (phase 3, design §7.1): By App records each chosen app in a track of its own,
/// with a tap of its own, so each can be muted and leveled in the editor.
public enum SystemAudioTracks {
    /// The most tracks of system audio a take records: the island lets 8 apps be chosen; a selection saved with more
    /// (phase 2 had no limit) gives 7 of their own and an eighth with the rest.
    public static let maximumTracks = 8

    /// The tracks `scope` records. All of the system is one track, `system-audio`, as in phase 2. By App, each app
    /// that can be recorded (neither `ownBundleIdentifier` nor an exclusion, each once, in the order chosen) has a
    /// track of its own, `TrackRecord.systemAudioTrackID` (letters, digits and `-`, with `-2`… when two sanitize
    /// alike), recording only that app (and its helpers): an app that is not open has its track from the start and
    /// records silence until it opens, so no track is ever added mid-take. With more than `maximumTracks` apps, the
    /// first 7 have their own and the rest share `system-audio`. With none, one `system-audio` track of silence.
    public static func plan(_ scope: SystemAudioScope, ownBundleIdentifier: String?) -> [SystemAudioTrackPlan] {
        let shared = "system-audio"
        guard case .applications(let chosen) = scope else {
            return [SystemAudioTrackPlan(trackID: shared, scope: .all, appBundleID: nil)]
        }
        var seen = Set<String>()
        let apps = chosen.filter { bundle in
            !bundle.isEmpty && bundle != ownBundleIdentifier && !SystemAudioExclusions.bundleIdentifiers.contains(bundle)
                && seen.insert(bundle).inserted
        }
        guard !apps.isEmpty else { return [SystemAudioTrackPlan(trackID: shared, scope: .applications([]), appBundleID: nil)] }
        let own = apps.count > maximumTracks ? Array(apps.prefix(maximumTracks - 1)) : apps
        var taken: Set<String> = [shared]
        var tracks = own.map { bundle in
            let id = TrackRecord.systemAudioTrackID(bundleID: bundle, taken: taken)
            taken.insert(id)
            return SystemAudioTrackPlan(trackID: id, scope: .applications([bundle]), appBundleID: bundle)
        }
        if apps.count > own.count {
            tracks.append(SystemAudioTrackPlan(trackID: shared, scope: .applications(Array(apps.dropFirst(own.count))), appBundleID: nil))
        }
        return tracks
    }

    /// What the manifest says of `source` before it records: its id, kind and `sourceInfo`, and, for the track of one
    /// app (system audio, an id that starts with `system-audio-`, only that app in `includedBundleIDs`), the app's
    /// bundle ID and name (`sourceInfo.name`) in `appBundleID` and `appName`. Any other track has neither.
    public static func trackRecord(of source: any CaptureSource) -> TrackRecord {
        let info = source.sourceInfo
        var record = TrackRecord(id: source.trackID, kind: source.kind, source: info, segments: [])
        if source.kind == .systemAudio, source.trackID.hasPrefix("system-audio-"), let apps = info.includedBundleIDs, apps.count == 1 {
            record.appBundleID = apps[0]
            record.appName = info.name
        }
        return record
    }

    /// The system audio `take` recorded, to record the same again ("Record from here", plan 3d): the apps of its tracks
    /// in track order (each app's, then those of a track of several, as phase 2's `includedBundleIDs`), or all of the
    /// system if a track recorded every app. `nil` if it recorded no system audio.
    public static func scope(of take: TakeRecord) -> SystemAudioScope? {
        let tracks = take.tracks.filter { $0.kind == .systemAudio }
        guard !tracks.isEmpty else { return nil }
        var apps: [String] = []
        for track in tracks {
            let recorded: [String]
            if let app = track.appBundleID {
                recorded = [app]
            } else if let included = track.source.includedBundleIDs {
                recorded = included
            } else {
                return .all
            }
            for app in recorded where !apps.contains(app) { apps.append(app) }
        }
        return .applications(apps)
    }

    /// The name the Finder shows for the app `bundleID` (as the island lists it), or `bundleID` if it is not installed.
    public static func installedAppName(bundleID: String) -> String {
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else { return bundleID }
        let name = FileManager.default.displayName(atPath: url.path)
        return name.isEmpty ? bundleID : name
    }
}
