// SPDX-License-Identifier: GPL-3.0-or-later
import Analysis
import ProjectFormat

/// The document a saved Replay starts with (fases 4 y 5 design §10.3.4, plan 5c decision 6): the one of a take just
/// recorded, cut where the last N seconds start.
public enum ReplayDocument {
    /// `NewDocument.make` of the saved take, with the sequence from `cut`: the clips that end at or before it are left
    /// out, and the one across it starts there (`Clip.start`; its segment starts before, so stretching the clip back
    /// shows what the files hold); then the blocks of `autoZoom-1` are planned again over that sequence, so none is
    /// before the cut (a block of another origin is kept if it ends after the cut). Everything else is `NewDocument.make`'s, the corners that cover a window's included (worked out
    /// over the whole take: at least as round as the part from the cut needs). A sequence the cut would leave empty is
    /// kept as it was, so there is always a clip.
    public static func make(
        project: LoadedProject, cut: HostTime, defaultStyle: DefaultStyle, makeID: (String) -> String, cameraLook: CameraLook
    ) -> EditDocument {
        var document = NewDocument.make(project: project, defaultStyle: defaultStyle, makeID: makeID, cameraLook: cameraLook)
        let sequence = document.sequence.compactMap { clip -> Clip? in
            guard clip.end > cut else { return nil }
            var clip = clip
            clip.start = max(clip.start, cut)
            return clip
        }
        guard !sequence.isEmpty else { return document }
        document.sequence = sequence
        // `autoZoom-1`'s own blocks are planned again; any other (a new document has none today) stays if it ends after
        // the cut, and the planner makes room for it.
        let others = document.zoom.regions.filter { $0.origin != .auto && $0.end > cut }
        document.zoom.regions = others
        let planned = AutoZoomPlanner.plan(take: project.take, events: project.events, document: document)
        document.zoom.regions = (others + planned).sorted { ($0.start, $0.end) < ($1.start, $1.end) }
        return document
    }
}
