// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation

/// The `manifest.json` of a saved Replay (fases 4 y 5 plan 5c, decision 8): a project of one take like one just
/// recorded, which the app of phase 3 reads.
public enum ReplayManifest {
    /// One take `takeID`, `complete`, with the tracks of `cut` (renumbered from 1, no `rotated`) and `cameraStyle` when
    /// it has a camera. `formatVersion` 3, or 4 when it saves a track of an iPhone or iPad or `events` has a key press.
    /// The take started `cut.end − cut.start` before `now`, and the project was created `now`, both in whole seconds.
    public static func make(
        cut: ReplayCut, events: [InputEvent], cameraStyle: CameraStyle?, takeID: String, app: AppInfo, now: Date,
        projectID: String
    ) -> Manifest {
        let hasCamera = cut.tracks.contains { $0.kind == .camera }
        let take = TakeRecord(
            id: takeID, status: .complete,
            startedAt: now.addingTimeInterval(-cut.end.seconds(since: cut.start)).roundedToWholeSeconds,
            tracks: cut.tracks, cameraStyle: hasCamera ? cameraStyle : nil)
        var manifest = Manifest(
            formatVersion: Manifest.currentFormatVersion, app: app, createdAt: now.roundedToWholeSeconds, takes: [take],
            projectID: projectID)
        if manifest.needsFormatVersion4 || events.contains(where: \.kind.requiresFormatVersion4) {
            manifest.formatVersion = 4
        }
        return manifest
    }
}
