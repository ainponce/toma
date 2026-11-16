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
    /// The package and the take the caches read, and the work of the waveforms.
    private var cachesFor: (url: URL, take: TakeRecord)?
    private var waveformWork: [Task<Void, Never>] = []
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
        timeline.restoredScaleAndScroll = { [weak model] in (model?.timelineScale, model?.timelineOffset ?? 0) }
        timeline.onScaleAndScrollChange = { [weak model] scale, offset in
            model?.timelineScale = scale
            model?.timelineOffset = offset
        }
        timeline.interaction.model = model
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
            bar.setEnabled(model.canEdit, hasClip: !model.speedTargets.isEmpty)
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
        guard model.state == .ready, let document = model.document, let project = model.overlayProject else {
            timeline.showNothing()
            return
        }
        if cachesFor?.url != project.package.url || cachesFor?.take != project.take, let caches = model.panelSession?.caches {
            cachesFor = (project.package.url, project.take)
            makeCaches(project, caches)
        }
        timeline.show(take: project.take, markers: model.markerTimes, document: document, missing: missing)
    }

    /// The thumbnails' cache, and the waveform of each audio track worked out off the main thread (decoded by the cache on
    /// its queue, its levels in a task of their own).
    private func makeCaches(_ project: LoadedProject, _ caches: ProjectCaches) {
        timeline.tracks.forgetThumbnails()
        timeline.tracks.thumbnailCache = ThumbnailCache(project: project, caches: caches)
        for work in waveformWork { work.cancel() }
        timeline.tracks.waveformLevels = [:]
        let waveforms = WaveformCache(project: project, caches: caches)
        waveformWork = project.take.tracks.filter { !$0.kind.isVideo && !$0.segments.isEmpty }.map { track in
            Task { [weak self] in
                let waveform = await waveforms.waveform(track: track.id)
                let levels = await Task.detached(priority: .utility) { WaveformLevels(waveform) }.value
                guard !Task.isCancelled else { return }
                self?.timeline.setWaveform(levels, for: track.id)
            }
        }
    }

    private static func selectedIDs(_ selection: EditorSelection?) -> Set<String> {
        switch selection {
        case let .clips(ids)?, let .zooms(ids)?: ids
        case let .cameraChange(id)?, let .screenChange(id)?: [id]
        case nil: []
        }
    }

    private func setMuted(_ track: String, _ muted: Bool) {
        guard let take = model.overlayProject?.take, let record = take.track(track) else { return }
        model.setTrackMuted(
            AudioTrackRow(take: take.id, track: track, isMicrophone: record.kind == .microphone, deviceName: record.source.name),
            muted)
    }
}
