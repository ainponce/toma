// SPDX-License-Identifier: GPL-3.0-or-later
import AppKit
import Analysis
import AppSupport
import Editing
import Export
import Observation
import ProjectFormat
import QuartzCore
import Recovery
import Render
import Synchronization
import UniformTypeIdentifiers
import os

/// What the editor has selected: what the panel shows and what Delete acts on.
enum EditorSelection: Equatable {
    case clips(Set<String>)
    case zooms(Set<String>)
    case cameraChange(String)
    case screenChange(String)
}

/// A track of sound of the take, as a row of the Audio tab.
struct AudioTrackRow: Equatable, Identifiable {
    var take: String
    var track: String
    var isMicrophone: Bool
    /// The device's visible name.
    var deviceName: String

    var id: String { AudioPlan.key(take: take, track: track) }
}

/// The import of a background image, as the panel shows it.
enum ImageImportState: Equatable {
    case idle
    /// Copying it into the project; a full disk makes it wait (the amber banner says so) until it is cancelled.
    case importing
    case notAnImage
    case saveFailed
}

/// "Use This Style for New Projects" and "Restore Toma's Style", as the panel shows them.
enum StyleStoreState: Equatable {
    case idle
    case working
    case failed
}

/// A strip above the preview (design §5.9): one at a time, the most pressing.
enum EditorBanner: Equatable {
    /// The last change could not be saved yet (amber).
    case saveFailed(POSIXErrorCode)
    /// Nothing can be changed, for this reason (never `.newerDocument` nor `.unreadable`: those show no preview at all).
    case readOnly(ReadOnlyReason)
    /// Another app changed the project before its first edit here: it was opened again.
    case reopenedAfterOtherApp
    /// The log was damaged: the edit was opened up to this instant.
    case recovered(upTo: Date)
    /// A project of an earlier version keeps its look, until it is edited or this is closed (once per project).
    case legacyLook
    /// The playhead is in a part of the recording that could not be read.
    case videoGap
}

/// One project in the editor (design §5): its edit session, opened off the main thread; the preview, drawn by a
/// `PreviewEngine` on its own queue from the scene of each revision, built on another queue; the sound of each revision,
/// played by a `PreviewAudioPlayer`, whose clock leads playback; the playhead; and the banners.
///
/// The playhead paused is always a frame of the project's grid (`playheadFrame`), the export's frame `n` at the export's
/// size (the document's format at 1080 on its shorter side). Playing, the time runs free on the audio's clock (the
/// host's while there is no sound) and the label follows it ten times a second. When the sequence changes, the playhead
/// keeps the source instant it shows if that is still kept, at its new output time; if it was cut, it goes to the output
/// time of the edit point that took its place (Task 14).
@MainActor @Observable
final class EditorModel {
    enum State: Equatable {
        case opening
        case ready
        /// Take `takeID` is still marked as being recorded: it can be recovered from here.
        case unfinished(takeID: String)
        case recovering
        case failed(String)
        /// The document is of a newer version of Toma: nothing is shown (the take without its edit would show what was
        /// cut).
        case newerDocument
    }

    enum ExportState: Equatable {
        case idle
        case running(progress: Double)
        case finished(URL)
    }

    /// The package as it was asked to be opened: the window's key.
    let packageURL: URL
    let takeID: String?
    private(set) var state = State.opening
    /// The project's name: its package's, without `.toma`.
    private(set) var name: String
    /// The session's document, the one edits apply to; `nil` until the session opens.
    private(set) var document: EditDocument?
    /// What the output lasts, in seconds.
    private(set) var durationSeconds = 0.0
    /// The frame of the project's grid the playhead is on: paused, the one shown; playing, the one before the time.
    private(set) var playheadFrame = 0
    /// The time of the transport's label: paused, the playhead frame's; playing, updated ten times a second.
    private(set) var currentSeconds = 0.0
    private(set) var isPlaying = false
    /// The format of the scene the preview shows (the document's, once its scene is built).
    private(set) var previewAspect = Aspect.landscape
    private(set) var banner: EditorBanner?
    private(set) var exportState = ExportState.idle
    /// "Apply Default Style" is under way.
    private(set) var isApplyingDefaultStyle = false
    var selection: EditorSelection?
    /// Whether the panel is shown; the window shows or hides its inspector by it.
    var panelVisible = true
    /// The image the background is being imported from (the panel's "Choose Image…").
    var imageImport = ImageImportState.idle
    @ObservationIgnored var importTask: Task<Void, Never>?
    /// Saving or restoring the style for new projects is under way, or failed.
    var styleStore = StyleStoreState.idle
    /// The take has a photo of the desktop (`wallpapers/`) the Desktop background can show.
    private(set) var hasDesktopPhoto = false
    /// The take has a camera: the panel's Camera tab exists.
    private(set) var hasCamera = false
    /// The take saved the shapes of the cursor (`cursorImage` events): macOS's cursor can be drawn.
    private(set) var hasCursorImages = false
    /// The take has clicks to make zooms from; without them the Zoom tab says so.
    private(set) var hasClicks = false
    /// The take noted when keys were typed (`keyActivity`): "Hold While Typing" has something to hold.
    private(set) var canHoldWhileTyping = false
    /// The take's tracks of sound, as the Audio tab lists them.
    private(set) var audioTracks: [AudioTrackRow] = []
    /// The automatic zoom's settings that are being planned again off the main thread: the controls show them meanwhile.
    var autoZoomPending: AutoZoomSettings?
    @ObservationIgnored var autoZoomTask: Task<Void, Never>?
    /// The edit session, for what the panel does with it (`EditorModel+Panel`).
    var panelSession: EditSession? { session }

    /// Whether the session can change the project, as it last said.
    private(set) var access = EditAccess.readOnly(.openElsewhere)

    var canEdit: Bool { state == .ready && access == .editable }
    var canPlay: Bool { state == .ready && engine != nil }
    var canExport: Bool { state == .ready && session != nil && !exportGate.isBusy }

    /// The layer the preview is drawn into; the preview's view hosts it.
    @ObservationIgnored let previewLayer = CAMetalLayer()
    @ObservationIgnored weak var window: NSWindow?
    /// Called with the project once it was recovered from this editor; set by the app delegate.
    @ObservationIgnored var onRecovered: (URL) -> Void = { _ in }

    @ObservationIgnored private let exportGate: ExportGate
    @ObservationIgnored private var session: EditSession?
    @ObservationIgnored private var renderer: FrameRenderer?
    @ObservationIgnored private var engine: PreviewEngine?
    @ObservationIgnored private var builder: RevisionBuilder?
    @ObservationIgnored private var player: PreviewAudioPlayer?
    /// The mix made when the project opened, which every revision's derives from.
    @ObservationIgnored private var baseMix: EditedMix?
    /// The revision of the session's document shown.
    @ObservationIgnored private var shownRevision = -1
    /// The document the playhead's time is counted in: paused, the session's; playing, that of the scene and the mix
    /// being played, until those of a newer revision are built.
    @ObservationIgnored private var timeline: Timeline?
    /// Playing: where the clock started on the host's clock, when there is no audio.
    @ObservationIgnored private var hostClock = (seconds: 0.0, host: 0.0)
    @ObservationIgnored private var usesAudioClock = false
    /// Where the sound was asked to start, until the player has taken it (its clock tells where it stopped before).
    @ObservationIgnored private var pendingAudioStart: Double?
    @ObservationIgnored private var clockGeneration = 0
    @ObservationIgnored private var lastLabelUpdate = 0.0
    @ObservationIgnored private var editorState = EditorState()
    /// Banners closed in this window (the legacy one is remembered in the project's caches).
    @ObservationIgnored private var dismissedRecovery = false
    @ObservationIgnored private var dismissedReopened = false
    /// An edit was made in this window: a project of an earlier version is not one without edits any more.
    @ObservationIgnored private var editedHere = false
    /// The spans of video that could not be read, in output seconds of the shown scene.
    @ObservationIgnored private var missingVideo: [ClosedRange<Double>] = []
    @ObservationIgnored private var missingVideoCheck: MissingVideoCheck?
    @ObservationIgnored private var openTask: Task<Void, Never>?
    @ObservationIgnored private var applyTask: Task<Void, Never>?
    @ObservationIgnored private var exportTask: Task<Void, Never>?
    @ObservationIgnored private var exportFinishedTask: Task<Void, Never>?
    @ObservationIgnored private var closed = false

    private nonisolated static let logger = Logger(subsystem: "dev.toma.Toma", category: "Editor")

    /// While playing, the label is updated at most this often (ten times a second).
    private static let labelInterval = 0.1
    /// How long "Export finished · Show in Finder" stays.
    private static let exportFinishedDuration = Duration.seconds(8)
    /// The shorter side of the export the paused preview is drawn at, until the export sheet remembers one (Task 43).
    static let previewShortSide = 1080

    /// A document and its time map.
    private struct Timeline {
        var document: EditDocument
        var map: TimeMap
        var revision: Int

        init(_ document: EditDocument, revision: Int) {
            self.document = document
            map = TimeMap(sequence: document.sequence)
            self.revision = revision
        }

        var frameRate: Int { document.frameRate }
        var lastFrame: Int { map.frameCount(frameRate: frameRate) - 1 }

        func seconds(ofFrame n: Int) -> Double {
            Double(TimeMap.frameTime(n, frameRate: frameRate)) / 1e9
        }

        /// The frame of the grid at or before `seconds`, as the engine plays it.
        func frame(atOrBefore seconds: Double) -> Int {
            let n = seconds.isFinite ? Int((seconds * Double(frameRate) + 1e-6).rounded(.down)) : 0
            return min(max(n, 0), lastFrame)
        }

        /// The frame of the grid nearest `seconds`.
        func frame(nearest seconds: Double) -> Int {
            let n = seconds.isFinite ? Int((seconds * Double(frameRate)).rounded()) : 0
            return min(max(n, 0), lastFrame)
        }
    }

    init(packageURL: URL, takeID: String?, exportGate: ExportGate) {
        self.packageURL = packageURL
        self.takeID = takeID
        self.exportGate = exportGate
        name = packageURL.deletingPathExtension().lastPathComponent
    }

    // MARK: - Opening

    /// Opens the project off the main thread ("Opening…" meanwhile): its edit session, its renderer at the export's size
    /// and the preview engine, then the mix of its sound.
    func load() {
        guard !closed else { return }
        openTask?.cancel()
        tearDownPreview()
        state = .opening
        banner = nil
        let url = packageURL, take = takeID
        let previous = session
        previous?.onChange = nil
        session = nil
        openTask = Task {
            // Its lock would make the project open read-only.
            await previous?.close()
            // A take still marked as being recorded is not opened: opening a version 3 project writes its document.
            if let unfinished = await Task.detached(operation: { Self.unfinishedTake(at: url, take: take) }).value {
                guard !closed else { return }
                state = .unfinished(takeID: unfinished)
                return
            }
            let defaultStyle = await Task.detached { DefaultStyleStore(directory: DefaultStyleStore.defaultDirectory).load() }.value
            let context = EditContext(
                app: AppInfo(name: AppIdentity.name, version: AppIdentity.version), cachesRoot: ProjectCaches.defaultRoot,
                defaultStyle: defaultStyle, now: { Date() },
                makeID: { prefix in prefix + String(format: "%08x", UInt32.random(in: .min ... .max)) },
                styleDirectory: DefaultStyleStore.defaultDirectory)
            let session: EditSession
            do {
                session = try await EditSession.open(url, take: take, context: context)
            } catch {
                Self.logger.error("Cannot open \(url.path, privacy: .public): \(String(describing: error), privacy: .public)")
                guard !closed else { return }
                state = .failed(userFacingDescription(of: error))
                return
            }
            guard !closed, !Task.isCancelled else {
                await session.close()
                return
            }
            await adopt(session)
        }
    }

    private func adopt(_ session: EditSession) async {
        self.session = session
        access = session.access
        session.onChange = { [weak self] in self?.sessionChanged() }
        name = session.packageURL.deletingPathExtension().lastPathComponent
        if let shown = Self.unshowable(session.access) {
            show(shown)
            return
        }
        let caches = session.caches
        editorState = await Task.detached { EditorState.load(caches) }.value
        let document = session.document, revision = session.revision
        let project = currentProject(of: session)
        let size = Self.exportSize(of: document)
        let renderer: FrameRenderer
        do {
            // Builds the motion paths: never on the main thread.
            renderer = try await Task.detached {
                try FrameRenderer(project: project, document: document, outputSize: size)
            }.value
        } catch {
            Self.logger.error("Cannot draw \(project.package.url.path, privacy: .public): \(String(describing: error), privacy: .public)")
            guard !closed else { return }
            state = .failed(userFacingDescription(of: error))
            return
        }
        // Closed, or shown as a project of a newer version or one that can't be read, meanwhile.
        guard !closed, self.session === session, state == .opening else { return }
        self.renderer = renderer
        let engine = PreviewEngine(renderer: renderer, layer: previewLayer)
        self.engine = engine
        let check = MissingVideoCheck(renderer: renderer) { [weak self] spans in
            self?.missingVideo = spans
            self?.updateBanner()
        }
        missingVideoCheck = check
        engine.onPresented = { _, _ in check.run() }
        let builder = RevisionBuilder(renderer: renderer, take: project.take, events: project.events) { [weak self] built in
            self?.revisionBuilt(built)
        }
        builder.prime(document)
        self.builder = builder
        shownRevision = revision
        timeline = Timeline(document, revision: revision)
        self.document = document
        hasCamera = project.take.tracks.contains { $0.kind == .camera && !$0.segments.isEmpty }
        hasCursorImages = project.events.contains { if case .cursorImage = $0.kind { true } else { false } }
        hasClicks = ZoomPanelRules.hasClicks(events: project.events)
        canHoldWhileTyping = ZoomPanelRules.canHoldWhileTyping(events: project.events)
        audioTracks = project.take.tracks.filter { ($0.kind == .microphone || $0.kind == .systemAudio) && !$0.segments.isEmpty }
            .map { AudioTrackRow(take: project.take.id, track: $0.id, isMicrophone: $0.kind == .microphone, deviceName: $0.source.name) }
        hasDesktopPhoto = false
        Self.findDesktopPhoto(in: project, document: document) { [weak self] found in self?.hasDesktopPhoto = found }
        previewAspect = document.aspect
        durationSeconds = timeline?.map.durationSeconds ?? 0
        state = .ready
        seek(frame: 0)
        // The session may have changed while the renderer was made.
        sessionChanged()
        makeMix(of: project, document: document, revision: revision)
    }

    /// The mix of the document as it opened, off the main thread: it reads where every audio segment ends. Playback
    /// follows the host's clock until it is there.
    private func makeMix(of project: LoadedProject, document: EditDocument, revision: Int) {
        Task {
            let mix: EditedMix
            do {
                mix = try await EditedMix.make(project: project, document: document, framesPerSecond: document.frameRate)
            } catch {
                Self.logger.error("No preview sound for \(project.package.url.path, privacy: .public): \(String(describing: error), privacy: .public)")
                return
            }
            guard !closed, state == .ready, builder != nil else { return }
            baseMix = mix
            let player = PreviewAudioPlayer(mix: mix)
            self.player = player
            if shownRevision != revision, let session {
                // Edited meanwhile: the mix (and scene) of the revision shown.
                builder?.build(revision: session.revision, document: session.document, outputSize: Self.exportSize(of: session.document), mix: mix)
            } else if isPlaying {
                startClock(at: clockSeconds())
            }
        }
    }

    /// Whether the take has a photo of the desktop of the first screen shown, read off the main thread.
    private static func findDesktopPhoto(in project: LoadedProject, document: EditDocument, found: @escaping @MainActor (Bool) -> Void) {
        let take = project.take, package = project.package
        let display = document.screens.initial[take.id].flatMap(take.track).flatMap { $0.kind.isScreen ? $0.source.displayID : nil }
        Task {
            let has = await Task.detached { display.map { package.wallpaper(take: take.id, displayID: $0) != nil } ?? false }.value
            found(has)
        }
    }

    /// A take still marked as being recorded, by its manifest: the take asked for, or the last one.
    private nonisolated static func unfinishedTake(at url: URL, take: String?) -> String? {
        guard let data = try? SafeRead.regularFile(at: ProjectPackage(url: url).manifestURL),
            let manifest = try? ProjectJSON.decoder().decode(Manifest.self, from: data)
        else { return nil }
        let record = take.map { id in manifest.takes.first { $0.id == id } } ?? manifest.takes.last
        return record?.status == .recording ? record?.id : nil
    }

    /// The project at the package's current place: the package may have been moved while open.
    private func currentProject(of session: EditSession) -> LoadedProject {
        var project = session.project
        project.package = ProjectPackage(url: session.packageURL)
        return project
    }

    /// The export's size, which the paused preview is drawn at: the document's format at 1080 on its shorter side.
    private static func exportSize(of document: EditDocument) -> SIMD2<Int> {
        StageLayout.outputSize(aspect: document.aspect, shortSide: previewShortSide)
    }

    /// The state that shows no preview for `access`, if it is one of those.
    private static func unshowable(_ access: EditAccess) -> State? {
        switch access {
        case .readOnly(.newerDocument): .newerDocument
        case .readOnly(.unreadable):
            .failed(EditorBanners.text(.readOnly(.unreadable)))
        case .editable, .readOnly: nil
        }
    }

    /// Shows `shown` instead of the preview: nothing of the document is drawn, played or exported.
    private func show(_ shown: State) {
        tearDownPreview()
        state = shown
        banner = nil
    }

    private func tearDownPreview() {
        stopPlaying()
        engine?.onPresented = nil
        engine = nil
        builder = nil
        renderer = nil
        player?.stop()
        player = nil
        baseMix = nil
        missingVideoCheck = nil
        missingVideo = []
        timeline = nil
        document = nil
    }

    /// Recovers the unfinished take from what is on disk, wherever the project is (the menu's recovery only
    /// looks in the projects folder), and loads it. `TakeRecovery` refuses a take that is being recorded and
    /// a project of a newer format, and never deletes recorded data.
    func recover() {
        guard case .unfinished(let takeID) = state else { return }
        state = .recovering
        let package = ProjectPackage(url: packageURL)
        Task {
            do {
                // Off the main thread: recovery reads every open segment.
                let take = try await Task.detached(priority: .userInitiated) {
                    try await TakeRecovery.recover(package: package, takeID: takeID)
                }.value
                Self.logger.notice("Recovered \(take.id, privacy: .public) of \(package.url.path, privacy: .public) from its editor")
                guard !closed else { return }
                onRecovered(packageURL)
                load()
            } catch {
                Self.logger.error("Cannot recover \(takeID, privacy: .public) of \(package.url.path, privacy: .public): \(String(describing: error), privacy: .public)")
                guard !closed else { return }
                state = .unfinished(takeID: takeID)
                showAlert(String(localized: "Couldn't recover the recording"), informative: userFacingDescription(of: error), style: .warning)
            }
        }
    }

    // MARK: - Edits

    /// Applies `step` to the document. The banners follow from the session's state as it changes (a first edit of an
    /// earlier version's project is pending its upgrade, `.pendingUpgrade`, until the session says how it went).
    @discardableResult
    func perform(_ step: EditStep) -> EditOutcome {
        guard let session else { return .refused }
        let outcome = session.perform(step)
        if outcome != .refused, !editedHere {
            editedHere = true
            updateBanner()
        }
        return outcome
    }

    // MARK: - Gestures

    /// A drag on the preview or on a bar of the panel is one gesture (design decision 22): while it lasts, the preview shows
    /// the document with the step applied, never logged; on its end, one `perform`.
    private(set) var isGesturing = false
    @ObservationIgnored private var gestureStep: EditStep?
    /// What the gesture shows of the document besides its step (the zoom's box shows the frame without zoom).
    @ObservationIgnored private var gestureLook: (EditDocument) -> EditDocument = { $0 }
    @ObservationIgnored private var gestureBuilds = 0

    /// Starts a gesture. `look` changes what the preview shows while it lasts (never what is logged).
    func beginGesture(look: @escaping (EditDocument) -> EditDocument = { $0 }) {
        guard canEdit, !isGesturing else { return }
        isGesturing = true
        gestureStep = nil
        gestureLook = look
        showGesture()
    }

    /// The step the gesture has now: the preview shows the document with its changes applied; if they do not apply, the
    /// document without them.
    func updateGesture(_ step: EditStep) {
        guard isGesturing else { return }
        gestureStep = step
        showGesture()
    }

    /// Ends the gesture with one `perform` of its last step (none if it never had one).
    func endGesture() {
        guard isGesturing else { return }
        isGesturing = false
        let step = gestureStep
        gestureStep = nil
        gestureLook = { $0 }
        if let step, perform(step) != .refused { return }
        showSessionRevision()
    }

    /// Ends the gesture without a change: the preview goes back to the document.
    func cancelGesture() {
        guard isGesturing else { return }
        isGesturing = false
        gestureStep = nil
        gestureLook = { $0 }
        showSessionRevision()
    }

    private func showGesture() {
        guard let document, let builder else { return }
        var shown = document
        if let step = gestureStep, let applied: EditDocument = try? document.applying(step.changes) { shown = applied }
        shown = gestureLook(shown)
        // Negative revisions are the gestures': no session's revision is one.
        gestureBuilds += 1
        builder.build(revision: -gestureBuilds, document: shown, outputSize: Self.exportSize(of: shown), mix: baseMix)
    }

    /// The preview shows the session's document again.
    private func showSessionRevision() {
        guard let session, let builder else { return }
        builder.build(revision: session.revision, document: session.document, outputSize: Self.exportSize(of: session.document), mix: baseMix)
    }

    /// The project as the session has it, for what the overlays place.
    var overlayProject: LoadedProject? { session.map(currentProject(of:)) }
    /// The playhead in output nanoseconds.
    var playheadNanoseconds: Int64 { timeline.map { Int64(TimeMap.frameTime(playheadFrame, frameRate: $0.frameRate)) } ?? 0 }

    func undo() {
        _ = session?.undo()
    }

    func redo() {
        _ = session?.redo()
    }

    var undoLabel: EditLabel? { session?.undoLabel }
    var redoLabel: EditLabel? { session?.redoLabel }

    /// The format selector of the bar: an edit, undone like any other.
    func setAspect(_ aspect: Aspect) {
        guard let document, let step = StyleCommands.setAspect(document, aspect) else { return }
        perform(step)
    }

    /// "Apply Default Style" of the earlier version's banner: one edit. Its image background waits for a full disk to
    /// have room (the amber banner says so) until it is saved, or the window closes and the session with it; it is never
    /// cancelled midway, which would apply Toma's gradient instead.
    func applyDefaultStyle() {
        guard let session, canEdit, applyTask == nil else { return }
        isApplyingDefaultStyle = true
        applyTask = Task {
            let directory = DefaultStyleStore.defaultDirectory
            let style = await Task.detached { DefaultStyleStore(directory: directory).load() }.value
            if await session.applyDefaultStyle(style, styleDirectory: directory) != .refused { editedHere = true }
            isApplyingDefaultStyle = false
            applyTask = nil
            updateBanner()
        }
    }

    /// Closes the banner shown, if it can be closed: the earlier version's one for good (in the project's caches), the
    /// others for this window.
    func dismissBanner() {
        switch banner {
        case .legacyLook?:
            editorState.legacyBannerDismissed = true
            if let caches = session?.caches { editorState.save(caches) }
        case .recovered?: dismissedRecovery = true
        case .reopenedAfterOtherApp?: dismissedReopened = true
        case .saveFailed?, .readOnly?, .videoGap?, nil: return
        }
        updateBanner()
    }

    /// The session's document, access or notices changed.
    private func sessionChanged() {
        guard let session, !closed else { return }
        if access != session.access { access = session.access }
        if let shown = Self.unshowable(session.access) {
            show(shown)
            return
        }
        guard state == .ready else { return }
        name = session.packageURL.deletingPathExtension().lastPathComponent
        if session.revision != shownRevision {
            shownRevision = session.revision
            let next = session.document
            document = next
            durationSeconds = TimeMap(sequence: next.sequence).durationSeconds
            pruneSelection(in: next)
            if !isPlaying { movePlayhead(to: Timeline(next, revision: session.revision)) }
            builder?.build(revision: session.revision, document: next, outputSize: Self.exportSize(of: next), mix: baseMix)
        }
        updateBanner()
    }

    /// Leaves out of the selection what the document no longer has.
    private func pruneSelection(in document: EditDocument) {
        switch selection {
        case let .clips(ids)?:
            let kept = ids.intersection(document.sequence.map(\.id))
            selection = kept.isEmpty ? nil : .clips(kept)
        case let .zooms(ids)?:
            let kept = ids.intersection(document.zoom.regions.map(\.id))
            selection = kept.isEmpty ? nil : .zooms(kept)
        case let .cameraChange(id)?:
            if !document.camera.changes.contains(where: { $0.id == id }) { selection = nil }
        case let .screenChange(id)?:
            if !document.screens.changes.contains(where: { $0.id == id }) { selection = nil }
        case nil:
            break
        }
    }

    /// The scene and the mix of a revision are built: the preview and the sound take them. Playing, the time goes on
    /// in the new revision (the same source instant) and the new sound is heard from there.
    private func revisionBuilt(_ built: RevisionBuilder.Built) {
        guard let engine, state == .ready else { return }
        engine.setScene(built.scene)
        previewAspect = built.document.aspect
        let mixChanged = timeline.map { Self.mixChanged(from: $0.document, to: built.document) } ?? true
        if let mix = built.mix { player?.setMix(mix) }
        if isPlaying, let timeline {
            let seconds = Self.seconds(afterChange: clockSeconds(), from: timeline.document, to: built.document)
            self.timeline = Timeline(built.document, revision: built.revision)
            if mixChanged || timeline.document.sequence != built.document.sequence { startClock(at: seconds) }
        } else {
            engine.request(.paused(frame: playheadFrame))
        }
    }

    /// Whether the sound of `new` differs from that of `old`.
    private static func mixChanged(from old: EditDocument, to new: EditDocument) -> Bool {
        old.sequence != new.sequence || old.frameRate != new.frameRate || old.audio != new.audio
            || old.cursor.clickSound != new.cursor.clickSound || old.cursor.clickSoundGain != new.cursor.clickSoundGain
    }

    /// The playhead (paused) moves into `next`: the same source instant, or the edit point that replaced it.
    private func movePlayhead(to next: Timeline) {
        guard let timeline else {
            self.timeline = next
            return
        }
        let seconds = Self.seconds(afterChange: timeline.seconds(ofFrame: playheadFrame), from: timeline.document, to: next.document)
        self.timeline = next
        setPlayhead(next.frame(nearest: seconds))
    }

    /// Where output second `seconds` of `old` is in `new` (Task 14): the output time of the source instant shown there if
    /// `new` keeps it; otherwise that of the first instant of its take kept after it, the edit point that closed the cut
    /// (the end, if none is).
    private static func seconds(afterChange seconds: Double, from old: EditDocument, to new: EditDocument) -> Double {
        guard old.sequence != new.sequence else { return seconds }
        let oldMap = TimeMap(sequence: old.sequence), newMap = TimeMap(sequence: new.sequence)
        guard let (clip, source) = oldMap.source(atOutput: TimeMap.outputNanoseconds(seconds: seconds)) else { return 0 }
        let take = old.sequence[clip].take
        let output = newMap.output(atSource: source, take: take) ?? newMap.firstKeptOutput(atOrAfter: source, take: take)
            ?? newMap.duration
        return Double(output) / 1e9
    }

    // MARK: - Playback

    func togglePlay() {
        isPlaying ? pause() : play()
    }

    /// Plays from the playhead (from the start if it is at the end).
    func play() {
        guard canPlay, !isPlaying, let timeline else { return }
        if playheadFrame >= timeline.lastFrame { setPlayhead(0) }
        isPlaying = true
        lastLabelUpdate = 0
        startClock(at: timeline.seconds(ofFrame: playheadFrame))
    }

    /// Stops on the frame shown.
    func pause() {
        guard isPlaying else { return }
        let seconds = clockSeconds()
        stopPlaying()
        guard let timeline, let session else { return }
        setPlayhead(timeline.frame(atOrBefore: seconds))
        // A revision whose scene was still being built: the playhead goes into it now.
        if timeline.revision != session.revision { movePlayhead(to: Timeline(session.document, revision: session.revision)) }
        engine?.request(.paused(frame: playheadFrame))
        missingVideoCheck?.run()
    }

    /// Goes to frame `n` of the grid; playing, it plays on from there.
    func seek(frame n: Int) {
        guard let timeline else { return }
        setPlayhead(min(max(n, 0), timeline.lastFrame))
        if isPlaying {
            startClock(at: timeline.seconds(ofFrame: playheadFrame))
        } else {
            engine?.request(.paused(frame: playheadFrame))
        }
    }

    func seekToStart() {
        seek(frame: 0)
    }

    /// The last frame: playing stops there.
    func seekToEnd() {
        guard let timeline else { return }
        if isPlaying { pause() }
        seek(frame: timeline.lastFrame)
    }

    /// The time being played, read from the clock (not observed): for what follows playback closer than the label.
    func playbackSeconds() -> Double {
        isPlaying ? clockSeconds() : currentSeconds
    }

    /// Asks for the paused frame again (the view's size changed).
    func redrawPaused() {
        guard !isPlaying, state == .ready else { return }
        engine?.request(.paused(frame: playheadFrame))
    }

    /// Each refresh of the display while playing: the frame at the clock's time, and the label ten times a second.
    func displayTick() {
        guard isPlaying, let engine, let timeline else { return }
        let seconds = clockSeconds()
        guard seconds < timeline.map.durationSeconds else {
            // The end: stops on the last frame.
            stopPlaying()
            setPlayhead(timeline.lastFrame)
            engine.request(.paused(frame: playheadFrame))
            return
        }
        engine.request(.playing(seconds: seconds))
        let now = Self.hostSeconds()
        if now - lastLabelUpdate >= Self.labelInterval {
            lastLabelUpdate = now
            currentSeconds = seconds
            let frame = timeline.frame(atOrBefore: seconds)
            if playheadFrame != frame { playheadFrame = frame }
            updateBanner()
        }
    }

    private func setPlayhead(_ n: Int) {
        playheadFrame = n
        currentSeconds = timeline?.seconds(ofFrame: n) ?? 0
        updateBanner()
    }

    /// Starts the clock at `seconds`: the audio's, which waits there until its first frame is heard, or the host's while
    /// there is no sound (or it cannot start).
    private func startClock(at seconds: Double) {
        clockGeneration += 1
        hostClock = (seconds, Self.hostSeconds())
        guard let player else {
            usesAudioClock = false
            return
        }
        usesAudioClock = true
        pendingAudioStart = seconds
        let generation = clockGeneration
        Task {
            // Paused, or started again elsewhere, meanwhile.
            guard generation == clockGeneration, isPlaying else { return }
            do {
                // The player takes the start before its first suspension: from here on its clock is the one.
                pendingAudioStart = nil
                try await player.play(fromSeconds: seconds)
            } catch {
                guard generation == clockGeneration, isPlaying else { return }
                Self.logger.error("The preview's sound did not start: \(String(describing: error), privacy: .public)")
                // On by the host's clock from where the sound stood.
                hostClock = (player.clock.seconds(atHost: Self.hostSeconds()), Self.hostSeconds())
                usesAudioClock = false
            }
        }
    }

    private func clockSeconds() -> Double {
        if usesAudioClock, let player { return pendingAudioStart ?? player.clock.seconds(atHost: Self.hostSeconds()) }
        return hostClock.seconds + (Self.hostSeconds() - hostClock.host)
    }

    private func stopPlaying() {
        guard isPlaying else { return }
        isPlaying = false
        clockGeneration += 1
        pendingAudioStart = nil
        player?.stop()
    }

    /// The host clock now, in seconds: the audio clock's.
    private static func hostSeconds() -> Double {
        Double(HostTime.now().nanoseconds) / 1e9
    }

    // MARK: - Banners

    private func updateBanner() {
        guard state == .ready, let session else {
            if banner != nil { banner = nil }
            return
        }
        let next = Self.banner(
            access: session.access, notices: session.notices, legacyDismissed: editorState.legacyBannerDismissed || editedHere,
            recoveryDismissed: dismissedRecovery, reopenedDismissed: dismissedReopened,
            inGap: missingVideo.contains { $0.contains(currentSeconds) })
        if banner != next { banner = next }
    }

    /// The most pressing banner: a save that failed, then why the project is read-only, then what opening found, then
    /// the earlier version's look, then a part of the video that could not be read under the playhead.
    private static func banner(
        access: EditAccess, notices: [EditNotice], legacyDismissed: Bool, recoveryDismissed: Bool, reopenedDismissed: Bool,
        inGap: Bool
    ) -> EditorBanner? {
        for case let .saveFailed(code) in notices { return .saveFailed(code) }
        if case let .readOnly(reason) = access { return .readOnly(reason) }
        if !reopenedDismissed, notices.contains(.reopenedAfterOtherApp) { return .reopenedAfterOtherApp }
        if !recoveryDismissed { for case let .recovered(date) in notices { return .recovered(upTo: date) } }
        if !legacyDismissed, notices.contains(.legacyLook) { return .legacyLook }
        return inGap ? .videoGap : nil
    }

    // MARK: - Export

    func exportVideo() {
        guard canExport, let window, let session else { return }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.mpeg4Movie]
        panel.canCreateDirectories = true
        let current = session.packageURL
        panel.nameFieldStringValue = current.deletingPathExtension().lastPathComponent + ".mp4"
        panel.directoryURL = current.deletingLastPathComponent()
        Task {
            guard await panel.beginSheetModal(for: window) == .OK, let destination = panel.url else { return }
            startExport(to: destination)
        }
    }

    /// Exports the document as it is now (what is edited meanwhile is not in it), in its format at 1080 on the shorter
    /// side and its frames per second, until the export sheet chooses (Task 43).
    private func startExport(to destination: URL) {
        guard canExport, let session else { return }
        let project = currentProject(of: session), document = session.document
        exportGate.isBusy = true
        exportFinishedTask?.cancel()
        exportState = .running(progress: 0)
        let settings = ExportSettings(
            aspect: document.aspect, resolution: .p1080, framesPerSecond: document.frameRate, quality: .standard)
        let exporter = MP4Exporter(project: project, document: document, settings: settings)
        let throttle = ProgressThrottle()
        // Called off the main thread, per frame.
        let progress: @Sendable (Double) -> Void = { [weak self] value in
            guard throttle.shouldReport(value) else { return }
            Task { @MainActor in self?.exportProgressed(value) }
        }
        exportTask = Task {
            do {
                let summary = try await exporter.export(to: destination, progress: progress)
                exportState = .finished(destination)
                exportFinishedTask = Task {
                    try? await Task.sleep(for: Self.exportFinishedDuration)
                    guard !Task.isCancelled, exportState == .finished(destination) else { return }
                    exportState = .idle
                }
                let leftOut = Self.leftOut(summary, take: project.take)
                if !leftOut.isEmpty { showAlert(leftOut.joined(separator: "\n\n"), style: .warning) }
            } catch let error where Self.isCancellation(error) {
                exportState = .idle
            } catch {
                Self.logger.error("Export to \(destination.path, privacy: .public) failed: \(String(describing: error), privacy: .public)")
                exportState = .idle
                showAlert(String(localized: "Couldn't export the video"), informative: userFacingDescription(of: error), style: .warning)
            }
            exportGate.isBusy = false
            exportTask = nil
        }
    }

    /// What the export had to leave out, one sentence for each kind.
    private static func leftOut(_ summary: ExportSummary, take: TakeRecord) -> [String] {
        var leftOut: [String] = []
        let systemAudio = Set(take.tracks.filter { $0.kind == .systemAudio }.map(\.id))
        let systemAudioGaps = summary.missingAudio.filter { systemAudio.contains($0.track) }.count
        let microphoneGaps = summary.missingAudio.count - systemAudioGaps
        if microphoneGaps > 0 {
            leftOut.append(String(localized: "The video was exported, but \(microphoneGaps) parts have no sound: their microphone audio couldn't be read."))
        }
        if systemAudioGaps > 0 {
            leftOut.append(String(localized: "The video was exported, but \(systemAudioGaps) parts have no system audio: it couldn't be read."))
        }
        let cameras = Set(take.tracks.filter { $0.kind == .camera }.map(\.id))
        let cameraGaps = summary.missingVideo.filter { cameras.contains($0.track) }.count
        let screenGaps = summary.missingVideo.count - cameraGaps
        if screenGaps > 0 {
            leftOut.append(String(localized: "The video was exported, but \(screenGaps) parts of the screen couldn't be read: they show the frame before them."))
        }
        if cameraGaps > 0 {
            leftOut.append(String(localized: "The video was exported, but \(cameraGaps) parts of the camera couldn't be read: they show the frame before them."))
        }
        return leftOut
    }

    func cancelExport() {
        exportTask?.cancel()
    }

    /// Cancels an export in progress and waits for its task to end: the exporter has removed its partial file.
    func cancelExportAndWait() async {
        guard let exportTask else { return }
        exportTask.cancel()
        await exportTask.value
    }

    func showExportInFinder() {
        guard case let .finished(url) = exportState else { return }
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    private func exportProgressed(_ value: Double) {
        guard case .running(let progress) = exportState, value > progress else { return }
        exportState = .running(progress: value)
    }

    private static func isCancellation(_ error: any Error) -> Bool {
        error is CancellationError || (error as? ExportError) == .cancelled
    }

    // MARK: - Closing

    /// The window closed: playback stops, an export in progress is cancelled, and the session closes (its snapshot and
    /// lock), off the main thread. An "Apply Default Style" waiting for room on a full disk gives up as the session
    /// closes, without applying anything (cancelling its task would apply Toma's gradient instead).
    func close() {
        guard !closed else { return }
        closed = true
        openTask?.cancel()
        exportTask?.cancel()
        exportFinishedTask?.cancel()
        tearDownPreview()
        if let session {
            session.onChange = nil
            Task { await session.close() }
        }
        session = nil
    }

    private func showAlert(_ message: String, informative: String = "", style: NSAlert.Style) {
        let alert = NSAlert()
        alert.alertStyle = style
        alert.messageText = message
        alert.informativeText = informative
        if let window, window.isVisible {
            alert.beginSheetModal(for: window)
        } else {
            alert.runModal()
        }
    }
}

/// Builds the scene (`MotionPaths` and `FrameRenderer.makeScene`) and the mix of each revision of the document off the
/// main thread (design §7.8), one at a time: a revision asked for while one is being built waits, and only the latest
/// waiting one is built. The motion paths of the last revision are kept for the next one when it changes nothing they
/// read (`MotionPaths.areThePaths(of:)`: a background, a shadow, the corners), which then costs no rebuild.
private final class RevisionBuilder: Sendable {
    struct Built: Sendable {
        var revision: Int
        var document: EditDocument
        /// At the export's size.
        var scene: FrameEvaluator
        /// The revision's mix, if the project's was made.
        var mix: EditedMix?
    }

    private struct Request: Sendable {
        var revision: Int
        var document: EditDocument
        var outputSize: SIMD2<Int>
        var mix: EditedMix?
    }

    private let renderer: FrameRenderer
    private let take: TakeRecord
    private let events: [InputEvent]
    private let built: @MainActor @Sendable (Built) -> Void
    private let queue = DispatchQueue(label: "dev.toma.Editor.revisions", qos: .userInitiated)
    private let state = Mutex(State())

    private struct State {
        var pending: Request?
        var building = false
        /// The paths last built; used on `queue` only.
        var paths: MotionPaths?
    }

    /// `built` is called on the main actor with each revision built.
    init(renderer: FrameRenderer, take: TakeRecord, events: [InputEvent], built: @escaping @MainActor @Sendable (Built) -> Void) {
        self.renderer = renderer
        self.take = take
        self.events = events
        self.built = built
    }

    /// Builds the paths of `document` (the revision shown) ahead, so the first edit that keeps them does not build them.
    func prime(_ document: EditDocument) {
        queue.async { _ = self.paths(of: document) }
    }

    /// Builds `revision` of the document, `document` at `outputSize`, and its mix from `mix` (the project's).
    func build(revision: Int, document: EditDocument, outputSize: SIMD2<Int>, mix: EditedMix?) {
        let start = state.withLock { state in
            state.pending = Request(revision: revision, document: document, outputSize: outputSize, mix: mix)
            defer { state.building = true }
            return !state.building
        }
        if start { queue.async { self.drain() } }
    }

    /// The paths of `document`: those last built if they are its, otherwise new ones. On `queue`.
    private func paths(of document: EditDocument) -> MotionPaths {
        if let last = state.withLock({ $0.paths }), last.areThePaths(of: document) { return last }
        let paths = MotionPaths(take: take, events: events, document: document)
        state.withLock { $0.paths = paths }
        return paths
    }

    private func drain() {
        while let request = state.withLock({ state -> Request? in
            guard let request = state.pending else {
                state.building = false
                return nil
            }
            state.pending = nil
            return request
        }) {
            let paths = paths(of: request.document)
            let result = Built(
                revision: request.revision, document: request.document,
                scene: renderer.makeScene(document: request.document, paths: paths, outputSize: request.outputSize),
                mix: request.mix?.with(document: request.document, framesPerSecond: request.document.frameRate))
            let built = self.built
            Task { @MainActor in built(result) }
        }
    }
}

/// The spans of video the renderer could not read so far (`FrameRenderer.missingVideo`), read off the main thread (a
/// reader's lock is held while it decodes) after the frames the engine presents, one reading at a time.
private final class MissingVideoCheck: Sendable {
    private let renderer: FrameRenderer
    private let found: @MainActor @Sendable ([ClosedRange<Double>]) -> Void
    private let queue = DispatchQueue(label: "dev.toma.Editor.missingVideo", qos: .utility)
    private let state = Mutex<(running: Bool, again: Bool, last: [ClosedRange<Double>])>((false, false, []))

    init(renderer: FrameRenderer, found: @escaping @MainActor @Sendable ([ClosedRange<Double>]) -> Void) {
        self.renderer = renderer
        self.found = found
    }

    /// Reads them again, from any thread; told on the main actor when they changed.
    func run() {
        let start = state.withLock { state in
            if state.running {
                state.again = true
                return false
            }
            state.running = true
            return true
        }
        if start { queue.async { self.read() } }
    }

    private func read() {
        while true {
            let spans = renderer.missingVideo.map { $0.start...$0.end }
            let changed = state.withLock { state in
                defer { state.last = spans }
                return state.last != spans
            }
            if changed {
                let found = self.found
                Task { @MainActor in found(spans) }
            }
            let again = state.withLock { state in
                defer { state.again = false }
                if !state.again { state.running = false }
                return state.again
            }
            if !again { return }
        }
    }
}

/// Lets export progress through at most every half percent, so the main thread is not called per frame.
private final class ProgressThrottle: Sendable {
    private let last = Mutex(-1.0)

    func shouldReport(_ value: Double) -> Bool {
        last.withLock { last in
            guard value >= 1 || value - last >= 0.005 else { return false }
            last = value
            return true
        }
    }
}
