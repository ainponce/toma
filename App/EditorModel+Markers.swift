// SPDX-License-Identifier: GPL-3.0-or-later
import AppKit
import Analysis
import AppSupport
import Editing
import ProjectFormat

/// The markers in the editor (phase 3 design §8.3, 3d plan decisions 1 to 4): the recorded ones (⌥⌘M, the island) of
/// every take and the ones added here, as the output shows them (`MarkerList.visible`: a marker whose instant is cut is
/// not there); M adds one at the playhead, ⌥← and ⌥→ go to the one before and after it, the ruler's flags and the
/// Markers menu name, move and delete them (`MarkerCommands`, each one undoable step that never touches `events.jsonl`),
/// and the ones with a name are the chapters (`chapters-1`): the text of YouTube for the clipboard, and the chapter track
/// of an MP4 or a MOV.
extension EditorModel {
    /// The instants of the `marker` events of every take of `project`, by take id (`MarkerList.recordedInstants`); a
    /// take without any has none. Reads each take's events (from the disk, the first time): never on the main thread.
    nonisolated static func recordedMarkers(of project: LoadedProject) -> MarkerList.Recorded {
        var recorded: MarkerList.Recorded = [:]
        for take in [project.take] + project.takes where recorded[take.id] == nil {
            let instants = MarkerList.recordedInstants(in: project.events(ofTake: take.id))
            if !instants.isEmpty { recorded[take.id] = instants }
        }
        return recorded
    }

    /// The markers the output shows, by output time; none without a document.
    var visibleMarkers: [VisibleMarker] {
        guard let document else { return [] }
        return MarkerList.visible(document: document, recorded: recordedMarkers, timeMap: TimeMap(sequence: document.sequence))
    }

    /// The marker shown on the playhead's frame (the first, if two are on it); `nil` if none is.
    var markerAtPlayhead: VisibleMarker? {
        guard let document else { return nil }
        let map = TimeMap(sequence: document.sequence)
        let shown = MarkerList.visible(document: document, recorded: recordedMarkers, timeMap: map)
        return MarkerList.at(
            frame: playheadFrame, in: shown, frameRate: document.frameRate, frameCount: map.frameCount(frameRate: document.frameRate))
    }

    /// M and the Markers menu's "Add Marker": a marker at the playhead (at the time playing, while it plays), which plays
    /// on; none in the middle of the frame of one shown already, nor where the output shows nothing. Whether one was added.
    @discardableResult
    func addMarkerAtPlayhead() -> Bool {
        guard canEdit, !isGesturing, let document else { return false }
        let map = TimeMap(sequence: document.sequence)
        let step = MarkerCommands.add(
            document, atOutput: markerTime(document, map), timeMap: map, recorded: recordedMarkers, makeID: Self.newID)
        guard let step else { return false }
        return perform(step) != .refused
    }

    /// ⌥← and ⌥→, and the Markers menu's: the marker before (`forward` false) or after the playhead, which goes to its
    /// frame, paused. Whether there was one.
    @discardableResult
    func goToMarker(forward: Bool) -> Bool {
        guard canPlay, let document else { return false }
        let map = TimeMap(sequence: document.sequence)
        let frameRate = document.frameRate, frameCount = map.frameCount(frameRate: frameRate)
        let from = PlayheadRule.frame(nearest: Double(markerTime(document, map)) / 1e9, frameRate: frameRate, frameCount: frameCount)
        let shown = MarkerList.visible(document: document, recorded: recordedMarkers, timeMap: map)
        guard let marker = MarkerList.neighbor(of: from, forward: forward, in: shown, frameRate: frameRate, frameCount: frameCount)
        else { return false }
        goTo(marker)
        return true
    }

    /// The playhead on the frame `marker` is shown on, paused: a click on its flag, or on it in the Markers menu.
    func goTo(_ marker: VisibleMarker) {
        guard canPlay, let document else { return }
        if isPlaying { pause() }
        let map = TimeMap(sequence: document.sequence)
        seek(frame: PlayheadRule.frame(
            nearest: Double(marker.output) / 1e9, frameRate: document.frameRate, frameCount: map.frameCount(frameRate: document.frameRate)))
    }

    /// `marker` named `name` (trimmed, at most 100 characters; empty is no name): one `marker.rename` step. Nothing if
    /// the output no longer shows it (undone, or cut, while its name was being typed).
    func renameMarker(_ marker: VisibleMarker, to name: String) {
        guard canEdit, !isGesturing, let document, let current = visibleMarkers.first(where: { $0.id == marker.id }),
            let step = MarkerCommands.rename(document, current, to: name, makeID: Self.newID)
        else { return }
        perform(step)
    }

    /// `marker` deleted (a recorded one is hidden, an added one taken out): one `marker.delete` step. Nothing if the
    /// output no longer shows it.
    func deleteMarker(_ marker: VisibleMarker) {
        guard canEdit, !isGesturing, let document, let current = visibleMarkers.first(where: { $0.id == marker.id }),
            let step = MarkerCommands.delete(document, current, makeID: Self.newID)
        else { return }
        perform(step)
    }

    /// The chapters of the whole output (`Chapters.list`): one per marker with a name, "Intro" at 00:00 when the first one
    /// is later; none without a named marker.
    var chapters: [Chapter] {
        guard let document else { return [] }
        let map = TimeMap(sequence: document.sequence)
        let shown = MarkerList.visible(document: document, recorded: recordedMarkers, timeMap: map)
        return Chapters.list(shown, duration: map.duration, introTitle: Self.introTitle)
    }

    /// The title of the chapter at 00:00 when no named marker is in the first second.
    static var introTitle: String {
        String(localized: "Intro", comment: "The title of the first chapter (YouTube's, and the video file's) when no marker with a name is at its start")
    }

    /// "Copy Chapters": the text of YouTube's description (`00:00 Intro`, a line per chapter) on the clipboard. Whether
    /// there were any.
    @discardableResult
    func copyChapters() -> Bool {
        guard let document else { return false }
        let chapters = self.chapters
        guard !chapters.isEmpty else { return false }
        let text = Chapters.youTubeText(chapters, duration: TimeMap(sequence: document.sequence).duration)
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        NSAccessibility.post(
            element: NSApp as Any, notification: .announcementRequested,
            userInfo: [.announcement: String(localized: "Chapters copied.", comment: "VoiceOver: Copy Chapters put YouTube's text on the clipboard")])
        return true
    }

    /// The output time a marker is added at and the markers are counted from: the playhead's frame, or the frame of the
    /// time playing while it plays (the playhead is updated ten times a second).
    private func markerTime(_ document: EditDocument, _ map: TimeMap) -> Int64 {
        guard isPlaying else { return playheadNanoseconds }
        let frameRate = document.frameRate, last = max(map.frameCount(frameRate: frameRate) - 1, 0)
        let frame = min(max(Int((playbackSeconds() * Double(frameRate)).rounded(.down)), 0), last)
        return TimeMap.frameTime(frame, frameRate: frameRate)
    }

    #if DEBUG
    /// `TOMA_SHOWCASE_P3_MARKERS=named` (T11): every recorded marker of every take of the package named ("Setup",
    /// "Demo", …, in time order), before the takes are added (`showcaseTwoTakes`) and the export sheet opens, and, 3 s
    /// later, with `TOMA_SHOWCASE_P3_MARKERS_PNG=<path>`, the PNGs `<path>-timeline.png` (the timeline, its ruler with
    /// the named flags) and `<path>-sheet.png` (the sheet over the window: the export's, with "Chapters in the File", for
    /// the `export` surface). Its own variable: `TOMA_SHOWCASE_P3_TIMELINE_PNG` makes the annotations' showcase wait
    /// 3 s before this one runs.
    func showcaseMarkers(_ environment: [String: String]) {
        guard environment["TOMA_SHOWCASE_P3_MARKERS"] == "named" else { return }
        let names = ["Setup", "Demo", "Questions", "Wrap-up", "Extras"]
        var k = 0
        for take in recordedMarkers.keys.sorted() {
            for t in recordedMarkers[take] ?? [] {
                guard let document,
                    !document.markers.items.contains(where: { $0.origin == .recorded && $0.take == take && $0.t == t })
                else { continue }
                let marker = VisibleMarker(
                    id: MarkerList.syntheticID(take: take, t: t), entryID: nil, take: take, t: t, name: "", origin: .recorded,
                    output: 0)
                if let step = MarkerCommands.rename(document, marker, to: names[k % names.count], makeID: Self.newID) {
                    perform(step)
                    k += 1
                }
            }
        }
        if environment["TOMA_SHOWCASE_PANEL_PNG"] != nil { CaptionsShowcase.snapshotLater(window) }
        Task {
            try? await Task.sleep(for: .seconds(3))
            guard let path = environment["TOMA_SHOWCASE_P3_MARKERS_PNG"] else { return }
            Self.writeTakesTimelinePNG(to: URL(filePath: path + "-timeline.png"))
            if let sheet = window?.attachedSheet?.contentView { Self.writePNG(of: sheet, to: URL(filePath: path + "-sheet.png")) }
        }
    }

    /// `view` drawn into a PNG at `url`, over the window's background.
    private static func writePNG(of view: NSView, to url: URL) {
        view.layoutSubtreeIfNeeded()
        guard let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds), let context = NSGraphicsContext(bitmapImageRep: rep)
        else { return }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = context
        view.effectiveAppearance.performAsCurrentDrawingAppearance {
            NSColor.windowBackgroundColor.setFill()
            view.bounds.fill()
        }
        NSGraphicsContext.restoreGraphicsState()
        view.effectiveAppearance.performAsCurrentDrawingAppearance { view.displayIgnoringOpacity(view.bounds, in: context) }
        try? rep.representation(using: .png, properties: [:])?.write(to: url)
    }
    #endif
}
