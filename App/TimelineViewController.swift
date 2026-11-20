// SPDX-License-Identifier: GPL-3.0-or-later
import AppKit
import AppSupport
import Editing
import ProjectFormat

/// The timeline's part of the editor's window: it follows the model (the document shown, the playhead, the spans that
/// could not be read) and makes the project's thumbnail and waveform caches, which work off the main thread.
@MainActor
final class TimelineViewController: NSViewController {
    private let model: EditorModel
    private let timeline = EditorTimelineView()
    /// The timeline itself, for the window's keys.
    var timelineView: EditorTimelineView { timeline }
    private let bar = TimelineBar()
    /// The package and the take the caches read, the takes whose thumbnails and waveforms are made (each the sequence
    /// came to show, 3d), and the work of the waveforms.
    private var cachesFor: (url: URL, take: TakeRecord)?
    private var cachedTakes: Set<String> = []
    private var waveformWork: [Task<Void, Never>] = []
    private var cameraCheck: Task<Void, Never>?
    private var stopped = false

    init(model: EditorModel) {
        self.model = model
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        nil
    }

    /// The window closed: nothing goes on drawing or working out waveforms.
    func stop() {
        stopped = true
        for work in waveformWork { work.cancel() }
        waveformWork = []
        cameraCheck?.cancel()
        timeline.stop()
    }

    override func loadView() {
        view = TimelineContainer(bar: bar, timeline: timeline)
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        timeline.playbackTime = { [weak model] in TimeMap.outputNanoseconds(seconds: model?.playbackSeconds() ?? 0) }
        timeline.onScrub = { [weak model] τ in model?.scrub(toSeconds: Double(τ) / 1e9) }
        timeline.onScrubEnd = { [weak model] in model?.endScrub() }
        timeline.onMute = { [weak self] track, muted in self?.setMuted(track, muted) }
        timeline.onSolo = { [weak model] row in model?.toggleSolo(row) }
        timeline.restoredScaleAndScroll = { [weak model] in (model?.timelineScale, model?.timelineOffset ?? 0) }
        timeline.onScaleAndScrollChange = { [weak model] scale, offset in
            model?.timelineScale = scale
            model?.timelineOffset = offset
        }
        timeline.interaction.model = model
        // "Rename Marker…" of the Markers menu: the popover over the marker's flag.
        model.askMarkerName = { [weak timeline] marker in timeline?.interaction.askMarkerName(marker) }
        // The Camera header: the panel edits the project's layout, on the Camera tab.
        timeline.onCameraHeader = { [weak model] in
            guard let model else { return }
            model.selection = nil
            if !model.panelVisible { model.panelVisible = true }
            model.panelTab = .camera
        }
        wireBar()
        followContent()
        followBar()
        followPlayhead()
    }

    /// The bar's controls do what the timeline's menus do, and follow its scale and its snapping.
    private func wireBar() {
        bar.onSplit = { [weak model] in model?.splitAtPlayhead() }
        bar.onSpeed = { [weak model] in model?.setSpeed($0) }
        bar.onCustomSpeed = { [weak timeline] in timeline?.interaction.askCustomSpeed() }
        bar.onAddZoom = { [weak model] in model?.addZoom() }
        bar.onAddBlur = { [weak model] in model?.addBlur() }
        bar.onAddLayout = { [weak model] in model?.addLayoutBlock(kind: $0) }
        bar.onSnapping = { [weak timeline] in timeline?.snapping = $0 }
        bar.onScale = { [weak timeline] in timeline?.setScale($0) }
        bar.onZoomIn = { [weak timeline] in timeline?.zoomIn() }
        bar.onZoomOut = { [weak timeline] in timeline?.zoomOut() }
        bar.onFit = { [weak timeline] in timeline?.fitToWindow() }
        timeline.onSnappingChange = { [weak self] in self.map { $0.bar.setSnapping($0.timeline.snapping) } }
        timeline.onScaleChange = { [weak self] in
            guard let self else { return }
            bar.setScale(timeline.scale, fit: timeline.scaleRange.lowerBound)
        }
    }

    /// The document, the spans that could not be read and whether it can be edited, as the model has them now and each
    /// time they change.
    private func followContent() {
        guard !stopped else { return }
        withObservationTracking {
            showContent()
        } onChange: { [weak self] in
            Task { @MainActor in self?.followContent() }
        }
    }

    /// What the bar enables and shows: whether the document can be edited, and the speed of what the menu applies to.
    private func followBar() {
        guard !stopped else { return }
        withObservationTracking {
            bar.setEnabled(model.canEdit, hasClip: !model.speedTargets.isEmpty, hasCamera: model.hasCamera)
            bar.setSpeed(model.speedOfTargets)
        } onChange: { [weak self] in
            Task { @MainActor in self?.followBar() }
        }
    }

    private func followPlayhead() {
        guard !stopped else { return }
        withObservationTracking {
            // The document too: the playhead's time depends on its frame rate.
            _ = model.document
            timeline.isPlaying = model.isPlaying
            timeline.playhead = model.playheadNanoseconds
        } onChange: { [weak self] in
            Task { @MainActor in self?.followPlayhead() }
        }
    }

    private func showContent() {
        let missing = model.missingVideo
        timeline.canEdit = model.canEdit
        timeline.marks = model.timelineMarks
        timeline.selected = Self.selectedIDs(model.selection)
        timeline.audioSolo = model.audioSolo
        // The music's lengths, waveforms and what is being made (3c), as `EditorAudio` has them.
        timeline.musicInfo = TimelineMusicInfo(shown: model.audio.shown, waveforms: model.audio.waveforms)
        guard model.state == .ready, let document = model.document, let project = model.overlayProject else {
            timeline.showNothing()
            return
        }
        let takes = project.takeRecords(shownBy: document)
        if let caches = model.panelSession?.caches {
            if cachesFor?.url != project.package.url || cachesFor?.take != project.take {
                cachesFor = (project.package.url, project.take)
                makeCaches(project, caches)
            }
            // Each take the sequence shows has its own thumbnails and waveforms, made the first time it shows it.
            for take in takes where !cachedTakes.contains(take.id) {
                if let shown = project.focused(on: take.id) { addCaches(of: shown, caches) }
            }
        }
        timeline.show(take: project.take, takes: takes, recorded: model.recordedMarkers,
            document: document, missing: missing, contentRatio: model.contentRatio(of: document))
        // What the cut of the sound is held to in each take the sequence shows (3c), read before a drag needs it.
        model.warmAudioTakeBounds()
    }

    /// The thumbnails' cache, and the waveform of each audio track worked out off the main thread (decoded by the cache on
    /// its queue, its levels in a task of their own).
    private func makeCaches(_ project: LoadedProject, _ caches: ProjectCaches) {
        // Whether the camera has anything to read (plan decision 40): the Camera row says so when it has not. The files are
        // looked at off the main thread.
        let (take, package) = (project.take, project.package)
        cameraCheck?.cancel()
        cameraCheck = Task { [weak self] in
            let readable = await Task.detached(priority: .utility) {
                LayoutTrackRules.cameraReadable(take: take) { SegmentAvailability.classify($0, in: package) }
            }.value
            guard !Task.isCancelled else { return }
            let unreadable = !readable && take.tracks.contains { $0.kind == .camera }
            self?.timeline.cameraUnreadable = unreadable
            self?.model.cameraUnreadable = unreadable
        }
        timeline.tracks.forgetThumbnails()
        timeline.tracks.thumbnailCaches = [:]
        timeline.tracks.contentClips.frames = MediaClipFrames(package: project.package)
        for work in waveformWork { work.cancel() }
        waveformWork = []
        timeline.tracks.waveformLevels = [:]
        cachedTakes = []
        addCaches(of: project, caches)
    }

    /// The thumbnails' cache of `project`'s take, and the waveform of each of its audio tracks, worked out as
    /// `makeCaches` says, by take (`AudioPlan.key(take:track:)`).
    private func addCaches(of project: LoadedProject, _ caches: ProjectCaches) {
        let take = project.take.id
        cachedTakes.insert(take)
        timeline.tracks.thumbnailCaches[take] = ThumbnailCache(project: project, caches: caches)
        let waveforms = WaveformCache(project: project, caches: caches)
        waveformWork += project.take.tracks.filter { !$0.kind.isVideo && !$0.segments.isEmpty }.map { track in
            Task { [weak self] in
                let waveform = await waveforms.waveform(track: track.id)
                let levels = await Task.detached(priority: .utility) { WaveformLevels(waveform) }.value
                guard !Task.isCancelled else { return }
                self?.timeline.setWaveform(levels, take: take, track: track.id)
            }
        }
    }

    private static func selectedIDs(_ selection: EditorSelection?) -> Set<String> {
        switch selection {
        case let .clips(ids)?, let .zooms(ids)?: ids
        case let .cameraChange(id)?, let .screenChange(id)?, let .layoutBlock(id)?: [id]
        case let .privacyBlocks(ids)?: ids
        case let .annotations(ids)?: ids
        case let .gainRange(id)?: [id]
        case let .musicItem(id)?: [id]
        case nil: []
        }
    }

    /// The Mute of an audio row's header: of the track in every take that recorded it, as the Audio tab's.
    private func setMuted(_ track: String, _ muted: Bool) {
        guard let row = model.audioTracks.first(where: { $0.id == track }) else { return }
        model.setTrackMuted(row, muted)
    }
}
