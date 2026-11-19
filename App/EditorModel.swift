// SPDX-License-Identifier: GPL-3.0-or-later
import AppKit
import Analysis
import AppSupport
import Editing
import Export
import Observation
import ProjectFormat
import ProjectJobs
import QuartzCore
import Recovery
import Render
import UniformTypeIdentifiers
import os

/// What the editor has selected: what the panel shows and what Delete acts on.
enum EditorSelection: Equatable {
    case clips(Set<String>)
    case zooms(Set<String>)
    case cameraChange(String)
    case screenChange(String)
    case layoutBlock(String)
    /// Privacy blocks (phase 2 design §7.1), all of the Privacy track.
    case privacyBlocks(Set<String>)
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

/// A strip above the preview (design §5.9): one at a time, the most pressing.
enum EditorBanner: Equatable {
    /// The last change could not be saved yet (amber).
    case saveFailed(POSIXErrorCode)
    /// "Apply Default Style" (`defaultStyle`) or a style of the row Style waits for room on a full disk to bring its image
    /// in (amber): nothing is applied yet.
    case waitingForSpace(defaultStyle: Bool)
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
/// size (the document's format at the resolution the export sheet remembers, plan decision 11). Playing, the time runs
/// free on the audio's clock (the host's while there is no sound) and the label follows it ten times a second; J and L
/// play at other speeds, on the host's clock without sound (`shuttle(_:)`). When the sequence changes, the playhead
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
    /// The projects folder: a package in its trash opens read-only (1c decision 36).
    let projectsFolder: URL
    private(set) var state = State.opening
    /// The project's name: its package's, without `.toma`.
    private(set) var name: String
    /// Where the package was last seen: where it was opened, then where its session finds it (renamed or moved while
    /// open, design §6.7). It opens again from here.
    private(set) var location: URL
    /// Where the first session found the package (its real path), once one opened: until the package moves from there, the
    /// path it was opened from still names it (`EditorPlace`).
    @ObservationIgnored private(set) var firstSeen: URL?
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
    /// A style of the row Style is being applied (`applyStyle`).
    private(set) var isApplyingStyle = false
    var selection: EditorSelection?
    /// The little window of Speed Up Typing is shown (phase 2 design §7.5).
    var isAskingTypingSpeed = false
    /// The in and out marks of the timeline's ruler (I and O, or ⌥ and a drag), in output nanoseconds.
    var timelineMarks = TimelineMarks()
    /// The safe-zone guide is shown over the preview (View ▸ Show Safe Zones; `safeZones-1`, never in the export).
    var showsSafeZones = false
    /// Whether the panel is shown; the window shows or hides its inspector by it.
    var panelVisible = true
    /// The panel's tab.
    var panelTab = EditorPanelTab.background
    /// The timeline's scale, in points per second (`nil`: the whole sequence fitted to the window), and how far it is
    /// scrolled, in points: restored with the window's state when the project opens, for the timeline to start from and
    /// write back as it changes.
    var timelineScale: Double?
    var timelineOffset = 0.0
    /// The image the background is being imported from (the panel's "Choose Image…").
    var imageImport = ImageImportState.idle
    @ObservationIgnored var importTask: Task<Void, Never>?
    /// The take has a photo of the desktop (`wallpapers/`) the Desktop background can show.
    private(set) var hasDesktopPhoto = false
    /// The take has a camera: the panel's Camera tab exists.
    private(set) var hasCamera = false
    /// No camera track of the take has anything to read (`LayoutTrackRules.cameraReadable`): the layouts that need the camera
    /// show only the screen, and the Camera track says so. Set by the timeline once it has looked at the files.
    var cameraUnreadable = false
    /// Whether the renderer found the camera readable (`FrameRenderer.cameraReadable`; false before it is made, and for a
    /// take without a camera): what the preview's overlays go by, so they see the layouts the frame shows.
    var renderCameraReadable: Bool { renderer?.cameraReadable ?? false }
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
    /// "Follow the Cursor" of the screen track being planned off the main thread.
    @ObservationIgnored var followCursorTask: Task<Void, Never>?
    /// The source instants of the take's markers, in order (`TimelineContent.markerTimes(in:)`), found once when the
    /// project opens, off the main thread: the ruler, ↑ and ↓ and a drag's snapping read them, never the events.
    @ObservationIgnored private(set) var markerTimes: [HostTime] = []
    /// Where the take's screens are (`TakeScreens`), read once when the project opens, off the main thread: each
    /// revision's `StagePoints` for the overlays then reads only what its document names.
    @ObservationIgnored private(set) var takeScreens: TakeScreens?
    /// The edit session, for what the panel does with it (`EditorModel+Panel`).
    var panelSession: EditSession? { session }
    /// The scene the preview draws now (the last revision built and shown): the overlays read the frame at the playhead
    /// from it, as the render draws it (the rect of a privacy block, `PrivacyRectEditorView`).
    private(set) var shownScene: FrameEvaluator?

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
    /// The document changed (an edit, an undo or a redo) or the session saved it; set by the app delegate, which tells
    /// the library.
    @ObservationIgnored var onEdited: () -> Void = {}
    /// Whether the project is open for viewing only because another app has it (`access` changed); set by the app
    /// delegate, which tells the library.
    @ObservationIgnored var onAccessChanged: () -> Void = {}
    /// The package is somewhere else now (`location` changed); set by the window, which shows it.
    @ObservationIgnored var onLocationChanged: () -> Void = {}
    /// What the editor does with its project as a whole (design §6.7): renaming it, duplicating it, the trash; set by
    /// the window.
    @ObservationIgnored var projectActions: EditorProjectActions?
    /// Another app holds the project's `edit.lock`.
    var isOpenElsewhere: Bool {
        switch access {
        case .readOnly(.openElsewhere), .readOnly(.otherAppStartedEditing): true
        default: false
        }
    }
    /// The package is in the trash of the projects folder, as last looked at (when it opened, and when it may have moved):
    /// it opens for viewing only (1c decision 36), with Restaurar, and a take there that did not finish saving is offered
    /// to be restored, never recovered.
    private(set) var isInTrash = false
    /// Whether the package is being looked at again (`packageMayHaveMoved`): one look at a time.
    @ObservationIgnored private var isLookingAtTheTrash = false
    /// "Custom Speed…" of the Project menu: the timeline's sheet; set by the window.
    @ObservationIgnored var askCustomSpeed: () -> Void = {}

    @ObservationIgnored private let exportGate: ExportGate
    @ObservationIgnored private var session: EditSession?
    /// The session's package folder, held open for the readers (`currentProject(of:)`); let go with the session.
    @ObservationIgnored private var packageHandle: PackageHandle?
    @ObservationIgnored private var renderer: FrameRenderer?
    @ObservationIgnored private var engine: PreviewEngine?
    @ObservationIgnored private var builder: RevisionBuilder?
    @ObservationIgnored private var player: PreviewAudioPlayer?
    /// The mix made when the project opened, which every revision's derives from.
    @ObservationIgnored private var baseMix: EditedMix?
    /// What the preview and the export read of the project's analysis caches (phase 2 design §10): nothing until a
    /// feature's job finishes and hands its result over with `updateAnalysis(_:)`.
    @ObservationIgnored private(set) var analysis = AnalysisInputs.none
    /// The analysis jobs of this project, one at a time and paused while a take records (`ProjectJobs`). The features'
    /// jobs are enqueued here; closing the editor cancels them.
    let jobs = ProjectJobs()
    /// What an export does first, in order, before its exporter starts: each feature adds its own (for example, waiting
    /// for its analysis jobs with progress). One that answers `false` cancels the export, saying nothing of its own.
    var exportPreparations: [@MainActor (EditorModel) async -> Bool] = []
    /// The camera's analysis (plan 2b decision 16): its masks and faces asked for, followed and handed to the preview, and
    /// waited for by the export.
    @ObservationIgnored private(set) lazy var image = EditorImage(model: self)
    /// The last `jobs.setRecording(_:)` told, so the next one goes after it and they arrive in order.
    @ObservationIgnored private var recordingTold: Task<Void, Never>?
    /// Which remaking of the mix is the latest, so an older one that finishes late is dropped.
    @ObservationIgnored private var mixGeneration = 0
    /// Which revision's mix the player holds and which one is heard.
    @ObservationIgnored private var sound = PlayingMix()
    /// The revision of the session's document shown.
    @ObservationIgnored private var shownRevision = -1
    /// The document the playhead's time is counted in: paused, the session's; playing, that of the scene and the mix
    /// being played, until those of a newer revision are built.
    @ObservationIgnored private var timeline: Timeline?
    /// Playing: where the clock started on the host's clock, when there is no audio.
    @ObservationIgnored private var hostClock = (seconds: 0.0, host: 0.0)
    /// Playing: the speed, signed (J and L: `shuttle(_:)`); 1 with `play()`.
    @ObservationIgnored private var speed = 1
    @ObservationIgnored private var usesAudioClock = false
    /// Where the sound was asked to start, until the player has taken it (its clock tells where it stopped before).
    @ObservationIgnored private var pendingAudioStart: Double?
    @ObservationIgnored private var clockGeneration = 0
    @ObservationIgnored private var lastLabelUpdate = 0.0
    /// The playhead is being dragged on the timeline's ruler.
    @ObservationIgnored private var isScrubbing = false
    /// The window's state, remembered in the project's caches (`EditorWindowState`).
    @ObservationIgnored let windowMemory = EditorWindowMemory()
    /// The window's undo manager: Edit ▸ Undo and Redo (`EditorMenus`).
    @ObservationIgnored private(set) lazy var undoManager = EditorUndoManager(model: self)
    /// "Some changes couldn't be saved" is being asked as the window closes.
    @ObservationIgnored var isAskingToClose = false

    /// The layout of the last block made or changed in this project (1c decision 10), which the next one takes.
    var lastBlockLayout: LayoutKind? { windowMemory.state.lastBlockLayout }

    /// Remembers `kind` as the last block layout, in the window's state (never in the document), written at once.
    func rememberBlockLayout(_ kind: LayoutKind) {
        guard windowMemory.state.lastBlockLayout != kind else { return }
        windowMemory.state.lastBlockLayout = kind
        writeWindowState()
    }
    /// Banners closed in this window (the legacy one is remembered in the project's caches).
    @ObservationIgnored private var dismissedRecovery = false
    @ObservationIgnored private var dismissedReopened = false
    /// An edit was made in this window: a project of an earlier version is not one without edits any more.
    @ObservationIgnored private var editedHere = false
    /// The spans of video that could not be read, in output seconds of the shown scene: the banner under the playhead and
    /// the hatching of the timeline's Video track.
    private(set) var missingVideo: [ClosedRange<Double>] = []
    @ObservationIgnored private var missingVideoCheck: MissingVideoCheck?
    @ObservationIgnored private var openTask: Task<Void, Never>?
    @ObservationIgnored private var applyTask: Task<Void, Never>?
    @ObservationIgnored private var exportTask: Task<Void, Never>?
    @ObservationIgnored private var exportFinishedTask: Task<Void, Never>?
    @ObservationIgnored private(set) var closed = false
    /// Once closed: the session closing (its last lines, snapshot and lock) and the export cancelled (its partial file
    /// removed), which a quit waits for (`waitUntilClosed()`).
    @ObservationIgnored private(set) var closing: Task<Void, Never>?

    private nonisolated static let logger = Logger(subsystem: "dev.toma.Toma", category: "Editor")

    /// While playing, the label is updated at most this often (ten times a second).
    private static let labelInterval = 0.1
    /// How long "Export finished · Show in Finder · Copy" stays.
    private static let exportFinishedDuration = Duration.seconds(8)
    /// The shorter side of the export the paused preview is drawn at: the resolution the export sheet remembers (1080
    /// until something is exported, plan decision 11), followed as it changes (`exportPreferencesChanged`).
    @ObservationIgnored private var previewShortSide = SettingsStore().settings.export.shortSide
    @ObservationIgnored private var preferencesObserver: (any NSObjectProtocol)?

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
            PlayheadRule.frame(atOrBefore: seconds, frameRate: frameRate, frameCount: lastFrame + 1)
        }

        /// The frame of the grid nearest `seconds`.
        func frame(nearest seconds: Double) -> Int {
            PlayheadRule.frame(nearest: seconds, frameRate: frameRate, frameCount: lastFrame + 1)
        }
    }

    init(packageURL: URL, takeID: String?, exportGate: ExportGate, projectsFolder: URL) {
        self.packageURL = packageURL
        self.takeID = takeID
        self.exportGate = exportGate
        self.projectsFolder = projectsFolder
        name = packageURL.deletingPathExtension().lastPathComponent
        location = packageURL
        preferencesObserver = NotificationCenter.default.addObserver(
            forName: .exportPreferencesChanged, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.exportPreferencesChanged() }
        }
        exportPreparations.append { await $0.image.prepareExport($0) }
    }

    // MARK: - Opening

    /// Opens the project off the main thread ("Opening…" meanwhile), from where it was last seen: its edit session (for
    /// viewing only if it is in the trash, 1c decision 36), its renderer at the export's size and the preview engine,
    /// then the mix of its sound.
    func load() {
        guard !closed else { return }
        openTask?.cancel()
        tearDownPreview()
        state = .opening
        banner = nil
        let previous = session
        // The session follows its package wherever it went.
        if let previous { noteLocation(previous.packageURL) }
        let url = location, take = takeID, projectsFolder = projectsFolder
        previous?.onChange = nil
        session = nil
        packageHandle = nil
        openTask = Task {
            // Its lock would make the project open read-only.
            await previous?.close()
            // The trash first, then a take still marked as being recorded, which is not opened: opening a version 3 project
            // writes its document (`EditorOpening`).
            let opening = await Task.detached { EditorOpening.of(url, take: take, projectsFolder: projectsFolder) }.value
            guard !closed else { return }
            isInTrash = opening.isInTrash
            let forced: ReadOnlyReason?
            switch opening {
            case .unfinished(let takeID, _):
                state = .unfinished(takeID: takeID)
                return
            case .session(let reason):
                forced = reason
            }
            let context = await Self.editContext(forcedReadOnly: forced)
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

    /// The context projects are opened and edited with here: a new project takes the style of the new projects (1c
    /// design §8), its look, its image and its camera; `forcedReadOnly` opens one for viewing only.
    static func editContext(forcedReadOnly: ReadOnlyReason? = nil) async -> EditContext {
        let newProjects = await StyleCatalog.shared.newProjectsStyle()
        return EditContext(
            app: AppInfo(name: AppIdentity.name, version: AppIdentity.version), cachesRoot: ProjectCaches.defaultRoot,
            defaultStyle: newProjects.style.look, now: { Date() },
            makeID: { prefix in prefix + String(format: "%08x", UInt32.random(in: .min ... .max)) },
            styleDirectory: newProjects.imageDirectory, cameraLook: newProjects.style.camera, forcedReadOnly: forcedReadOnly)
    }

    private func adopt(_ session: EditSession) async {
        self.session = session
        access = session.access
        onAccessChanged()
        session.onChange = { [weak self] in self?.sessionChanged() }
        if firstSeen == nil { firstSeen = session.packageURL.standardizedFileURL }
        noteLocation(session.packageURL)
        if let shown = Self.unshowable(session.access) {
            show(shown)
            return
        }
        // Read already before the window showed, unless its manifest could not be read then.
        await restoreWindowState(sessionCaches: session.caches)
        // The package's folder, held open off the main thread: what the preview and the export open later is found where
        // the package is then, also after a rename (design §6.7).
        let at = session.packageURL
        packageHandle = await Task.detached { PackageHandle(url: at) }.value
        guard !closed, self.session === session else { return }
        let document = session.document, revision = session.revision
        let project = currentProject(of: session)
        let size = previewSize(of: document)
        let renderer: FrameRenderer
        let screens: TakeScreens, markers: [HostTime]
        do {
            // Builds the motion paths, and reads the take's events for what the overlays and the timeline read of them:
            // never on the main thread.
            (renderer, screens, markers) = try await Task.detached {
                let renderer = try FrameRenderer(project: project, document: document, outputSize: size)
                return (renderer, TakeScreens(take: project.take, events: project.events), TimelineContent.markerTimes(in: project.events))
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
        takeScreens = screens
        markerTimes = markers
        let engine = PreviewEngine(renderer: renderer, layer: previewLayer)
        self.engine = engine
        let check = MissingVideoCheck(renderer: renderer) { [weak self] spans in
            self?.missingVideo = spans
            self?.updateBanner()
        }
        missingVideoCheck = check
        engine.onPresented = { _, _ in check.run() }
        // With the paths the renderer's scene was made with: the first edit that keeps them builds none.
        builder = RevisionBuilder(
            renderer: renderer, take: project.take, events: project.events, paths: renderer.scene.paths
        ) { [weak self] built in
            self?.revisionBuilt(built)
        }
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
        restoreProjectView()
        // The session, or the resolution the export sheet remembers, may have changed while the renderer was made.
        if previewSize(of: document) != size { showSessionRevision() }
        sessionChanged()
        makeMix(of: project, document: document, revision: revision)
        image.opened(project: project, caches: session.caches, document: session.document)
    }

    /// The mix of the document as it opened, off the main thread: it reads where every audio segment ends. Playback
    /// follows the host's clock until it is there.
    private func makeMix(of project: LoadedProject, document: EditDocument, revision: Int) {
        mixGeneration += 1
        let generation = mixGeneration, analysis = analysis
        Task {
            let mix: EditedMix
            do {
                mix = try await EditedMix.make(
                    project: project, document: document, framesPerSecond: document.frameRate, analysis: analysis)
            } catch {
                Self.logger.error("No preview sound for \(project.package.url.path, privacy: .public): \(String(describing: error), privacy: .public)")
                return
            }
            guard !closed, state == .ready, builder != nil, generation == mixGeneration else { return }
            baseMix = mix
            if let player {
                // Remade with new analysis: the player takes the revision shown's mix as it is built.
                player.setMix(mix)
                if let session { build(session.document, revision: session.revision) }
                return
            }
            let player = PreviewAudioPlayer(mix: mix)
            self.player = player
            sound.hold(document)
            if shownRevision != revision, let session {
                // Edited meanwhile: the mix (and scene) of the revision shown, played once built if playing.
                build(session.document, revision: session.revision)
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

    /// The project at the package's current place: the package may have been moved while open. Its readers find its files
    /// where it is when they open them (`packageHandle`), also after it moves again.
    private func currentProject(of session: EditSession) -> LoadedProject {
        var project = session.project
        project.package = ProjectPackage(url: session.packageURL, handle: packageHandle)
        return project
    }

    /// The export's size, which the paused preview is drawn at: the document's format at the resolution the export sheet
    /// remembers.
    private func previewSize(of document: EditDocument) -> SIMD2<Int> {
        StageLayout.outputSize(aspect: document.aspect, shortSide: previewShortSide, contentRatio: contentRatio(of: document))
    }

    /// The export sheet remembers another resolution (this editor's or another's exported at it): the preview is drawn at
    /// it from now on, the paused frame at once.
    private func exportPreferencesChanged() {
        let shortSide = SettingsStore().settings.export.shortSide
        guard shortSide != previewShortSide else { return }
        previewShortSide = shortSide
        // A gesture's next step is drawn at it, and its end draws the session's revision.
        if !isGesturing { showSessionRevision() }
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
        sound = PlayingMix()
        baseMix = nil
        missingVideoCheck = nil
        missingVideo = []
        timeline = nil
        document = nil
    }

    /// Recovers the unfinished take from what is on disk, wherever the project is (the menu's recovery only
    /// looks in the projects folder), and loads it. `TakeRecovery` refuses a take that is being recorded and
    /// a project of a newer format, and never deletes recorded data.
    ///
    /// Never in the trash (Task 39, ruling 2): recovery writes into the package, which emptying the trash would delete; it
    /// is restored first. Asked again here, wherever it went since it was opened.
    func recover() {
        guard case .unfinished(let takeID) = state, !isInTrash else { return }
        state = .recovering
        let url = location, projectsFolder = projectsFolder
        let package = ProjectPackage(url: url)
        Task {
            guard await Task.detached(operation: { EditorOpening.mayRecover(url, projectsFolder: projectsFolder) }).value else {
                guard !closed else { return }
                isInTrash = true
                state = .unfinished(takeID: takeID)
                return
            }
            do {
                // Off the main thread: recovery reads every open segment.
                let take = try await Task.detached(priority: .userInitiated) {
                    try await TakeRecovery.recover(package: package, takeID: takeID)
                }.value
                Self.logger.notice("Recovered \(take.id, privacy: .public) of \(package.url.path, privacy: .public) from its editor")
                guard !closed else { return }
                onRecovered(url)
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
    /// A gesture's look the preview keeps after it ended, until `releaseLook()`.
    @ObservationIgnored private var heldLook: ((EditDocument) -> EditDocument)?
    /// Which builds of the preview are shown (`PreviewBuilds`): a gesture's while it lasts, never a stale one.
    @ObservationIgnored private var builds = PreviewBuilds()

    /// Starts a gesture. `look` changes what the preview shows while it lasts (never what is logged).
    func beginGesture(look: @escaping (EditDocument) -> EditDocument = { $0 }) {
        guard canEdit, !isGesturing else { return }
        isGesturing = true
        builds.beginGesture()
        gestureStep = nil
        gestureLook = look
        showGesture()
    }

    /// The step the gesture has now: the preview shows the document with its changes applied; if they do not apply, the
    /// document without them. Returns the document with the step applied (without the gesture's look; `nil` without a
    /// step, or one that does not apply), for what else shows the gesture: applying is not cheap, and is done once a move.
    @discardableResult
    func updateGesture(_ step: EditStep?) -> EditDocument? {
        guard isGesturing else { return nil }
        gestureStep = step
        return showGesture()
    }

    /// Ends the gesture with one `perform` of its last step (none if it never had one); whether it changed the document.
    /// `holdingLook`: the preview keeps the gesture's look until `releaseLook()` (the camera's bubble is the overlay's
    /// while it is thrown into its place, so it is never drawn twice).
    @discardableResult
    func endGesture(holdingLook: Bool = false) -> Bool {
        guard isGesturing else { return false }
        isGesturing = false
        builds.endGesture()
        let step = gestureStep
        gestureStep = nil
        if holdingLook { heldLook = gestureLook }
        gestureLook = { $0 }
        if let step, perform(step) != .refused { return true }
        showSessionRevision()
        return false
    }

    /// Ends the gesture without a change: the preview goes back to the document.
    func cancelGesture() {
        guard isGesturing else { return }
        isGesturing = false
        builds.endGesture()
        gestureStep = nil
        gestureLook = { $0 }
        showSessionRevision()
    }

    /// The look `endGesture(holdingLook: true)` kept is let go: the preview shows the session's document as it is.
    func releaseLook() {
        guard heldLook != nil else { return }
        heldLook = nil
        showSessionRevision()
    }

    @discardableResult
    private func showGesture() -> EditDocument? {
        guard let document, let session, let builder else { return nil }
        let applied: EditDocument? = gestureStep.flatMap { try? document.applying($0.changes) }
        let shown = gestureLook(applied ?? document)
        let ticket = builds.request(revision: session.revision, ofGesture: true)
        builder.build(ticket: ticket, document: shown, outputSize: previewSize(of: shown), mix: baseMix, analysis: analysis)
        return applied
    }

    /// The preview shows the session's document again.
    private func showSessionRevision() {
        guard let session else { return }
        build(session.document, revision: session.revision)
    }

    /// Builds the scene and the mix of session revision `revision`, `document`, with the look still held, if one is.
    private func build(_ document: EditDocument, revision: Int) {
        guard let builder else { return }
        let shown = heldLook?(document) ?? document
        let ticket = builds.request(revision: revision, ofGesture: false)
        builder.build(ticket: ticket, document: shown, outputSize: previewSize(of: shown), mix: baseMix, analysis: analysis)
    }

    /// A take starts or stops recording: the analysis queue pauses while it does (`ProjectJobs.setRecording(_:)`; an
    /// analysis that cannot be suspended is repeated from its last segment after the take).
    func setRecording(_ recording: Bool) {
        let previous = recordingTold
        recordingTold = Task { [jobs] in
            await previous?.value
            await jobs.setRecording(recording)
        }
    }

    /// A feature's analysis arrived (or went): `edit` changes what the preview and the export read of the caches. The
    /// preview's scene is built again with it and the mix is remade (off the main thread), then the revision shown is
    /// drawn again. Nothing happens if `edit` changes nothing.
    func updateAnalysis(_ edit: (inout AnalysisInputs) -> Void) {
        var next = analysis
        edit(&next)
        guard next != analysis else { return }
        analysis = next
        guard state == .ready, let session else { return }
        showSessionRevision()
        makeMix(of: currentProject(of: session), document: session.document, revision: session.revision)
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

    /// "Apply Default Style" of the earlier version's banner: one edit, with the look of the style of the new projects
    /// (1c design §8; its camera is left as the project has it). Its image background waits for a full disk to have room
    /// (the amber banner says so) until it is saved, or the window closes and the session with it; it is never cancelled
    /// midway, which would apply Toma's gradient instead.
    func applyDefaultStyle() {
        guard let session, canEdit, applyTask == nil else { return }
        isApplyingDefaultStyle = true
        updateBanner()
        applyTask = Task {
            let newProjects = await StyleCatalog.shared.newProjectsStyle()
            let outcome = await session.applyDefaultStyle(newProjects.style.look, styleDirectory: newProjects.imageDirectory)
            if outcome != .refused { editedHere = true }
            isApplyingDefaultStyle = false
            applyTask = nil
            updateBanner()
        }
    }

    /// "Apply" of the row Style (1c design §8): `EditSession.applyStyle`, one edit, which brings the style's image from
    /// `imageDirectory` first (waiting for a full disk to have room, as an import does). `(.refused, false)` if the project
    /// cannot be edited.
    func applyStyle(_ style: NamedStyle, imageDirectory: URL?) async -> (outcome: EditOutcome, imageMissing: Bool) {
        guard let session, canEdit, !isApplyingStyle else { return (.refused, false) }
        // While its image waits for room on a full disk, the banner says so (`.waitingForSpace`).
        isApplyingStyle = true
        updateBanner()
        let result = await session.applyStyle(style, imageDirectory: imageDirectory)
        isApplyingStyle = false
        if result.outcome != .refused { editedHere = true }
        updateBanner()
        return result
    }

    /// Closes the banner shown, if it can be closed: the earlier version's one for good (in the project's caches), the
    /// others for this window.
    func dismissBanner() {
        switch banner {
        case .legacyLook?:
            windowMemory.state.legacyBannerDismissed = true
            writeWindowState()
        case .recovered?: dismissedRecovery = true
        case .reopenedAfterOtherApp?: dismissedReopened = true
        case .saveFailed?, .waitingForSpace?, .readOnly?, .videoGap?, nil: return
        }
        updateBanner()
    }

    /// The session's document, access or notices changed.
    private func sessionChanged() {
        guard let session, !closed else { return }
        if access != session.access {
            access = session.access
            onAccessChanged()
        }
        if let shown = Self.unshowable(session.access) {
            show(shown)
            return
        }
        guard state == .ready else { return }
        noteLocation(session.packageURL)
        if session.revision != shownRevision {
            shownRevision = session.revision
            onEdited()
            let next = session.document
            document = next
            durationSeconds = TimeMap(sequence: next.sequence).durationSeconds
            pruneSelection(in: next)
            if !isPlaying { movePlayhead(to: Timeline(next, revision: session.revision)) }
            build(next, revision: session.revision)
            image.documentChanged(next)
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
        case let .layoutBlock(id)?:
            if !document.camera.layouts.contains(where: { $0.id == id }) { selection = nil }
        case let .privacyBlocks(ids)?:
            let kept = ids.intersection(document.privacy.blocks.map(\.id))
            selection = kept.isEmpty ? nil : .privacyBlocks(kept)
        case nil:
            break
        }
    }

    /// The scene and the mix of a revision are built: the preview and the sound take them. Playing, the time goes on
    /// in the new revision (the same source instant) and the new sound is heard from there.
    ///
    /// Which builds are shown is `PreviewBuilds`': a gesture's while it lasts, and never one older than what is on screen,
    /// than the revision the playhead is counted in (the newer one is on its way), or of a gesture that ended. Playing, a
    /// gesture's look is drawn and heard, and the playhead stays counted in the session's document.
    private func revisionBuilt(_ built: RevisionBuilder.Built) {
        guard let engine, state == .ready, builds.accepts(built.ticket, playheadRevision: timeline?.revision) else { return }
        engine.setScene(built.scene)
        shownScene = built.scene
        previewAspect = built.document.aspect
        if let mix = built.mix, let player {
            player.setMix(mix)
            sound.hold(built.document)
        }
        if isPlaying, built.ticket.gesture != nil {
            if player != nil, sound.needsPlay { startClock(at: clockSeconds()) }
        } else if isPlaying, let timeline {
            let seconds = Self.seconds(afterChange: clockSeconds(), from: timeline.document, to: built.document)
            self.timeline = Timeline(built.document, revision: built.ticket.revision)
            // The player plays a new mix only from its next `play` (and what it plays may be an older revision's than
            // the playhead's); the host's clock goes on in the new revision's time.
            if (player != nil && sound.needsPlay) || timeline.document.sequence != built.document.sequence {
                startClock(at: seconds)
            }
        } else {
            engine.request(.paused(frame: playheadFrame))
        }
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
        let output = PlayheadRule.output(
            afterChange: TimeMap.outputNanoseconds(seconds: seconds), from: old.sequence, to: new.sequence)
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
        speed = 1
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

    /// The speed playing at, signed: 0 paused, 1 playing (`play()`), and J and L's others (`shuttle(_:)`).
    var playbackSpeed: Int { isPlaying ? speed : 0 }

    /// J and L (design §5.7): plays at `speed` (signed; backwards with a negative one) from where the playhead is, or the
    /// time playing. At 1× forwards it is `play()`, with sound; at any other speed, the host's clock runs at that speed
    /// without sound, and backwards the preview shows the latest instant asked for, as a drag of the playhead does (it can
    /// show fewer frames). It stops at the end, and backwards at the start. Whether it plays.
    @discardableResult
    func shuttle(_ speed: Int) -> Bool {
        guard canPlay, speed != 0, let timeline else { return false }
        if isPlaying, self.speed == speed { return true }
        // Paused at the end, forwards plays from the start, as `play()` does; at the start, backwards does nothing.
        let from = !isPlaying && speed > 0 && playheadFrame >= timeline.lastFrame ? 0 : playheadFrame
        let seconds = isPlaying ? clockSeconds() : timeline.seconds(ofFrame: from)
        guard speed > 0 || seconds > 0 else { return false }
        if isPlaying { stopPlaying() }
        self.speed = speed
        isPlaying = true
        lastLabelUpdate = 0
        startClock(at: seconds)
        return true
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

    /// The playhead dragged on the timeline's ruler (design §5.5): it goes to the frame of the grid nearest `seconds`,
    /// and the preview shows it as `.scrubbing`, the latest instant asked for winning (the engine draws only that one),
    /// without sound. Playing stops first. `endScrub()` shows the exact frame.
    func scrub(toSeconds seconds: Double) {
        guard canPlay, let timeline else { return }
        if isPlaying { pause() }
        let frame = timeline.frame(nearest: seconds)
        guard !isScrubbing || frame != playheadFrame else { return }
        isScrubbing = true
        setPlayhead(frame)
        engine?.request(.scrubbing(seconds: timeline.seconds(ofFrame: frame)))
    }

    /// The drag of the playhead ended: the preview shows the exact frame it is on.
    func endScrub() {
        guard isScrubbing else { return }
        isScrubbing = false
        engine?.request(.paused(frame: playheadFrame))
        missingVideoCheck?.run()
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
        guard seconds < timeline.map.durationSeconds, speed > 0 || seconds > 0 else {
            // The end (or, backwards, the start): stops on its frame.
            stopPlaying()
            setPlayhead(speed > 0 ? timeline.lastFrame : 0)
            engine.request(.paused(frame: playheadFrame))
            return
        }
        engine.request(speed > 0 ? .playing(seconds: seconds) : .scrubbing(seconds: seconds))
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
    /// there is no sound (or it cannot start, or the speed is not 1×).
    private func startClock(at seconds: Double) {
        clockGeneration += 1
        hostClock = (seconds, Self.hostSeconds())
        guard let player, speed == 1 else {
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
                // The player takes the start, and the mix it holds, before its first suspension: from here on its clock
                // is the one.
                pendingAudioStart = nil
                sound.played()
                try await player.play(fromSeconds: seconds)
            } catch {
                guard generation == clockGeneration, isPlaying else { return }
                Self.logger.error("The preview's sound did not start: \(String(describing: error), privacy: .public)")
                // On by the host's clock from where the sound stood.
                hostClock = (player.clock.seconds(atHost: Self.hostSeconds()), Self.hostSeconds())
                usesAudioClock = false
                sound.stopped()
            }
        }
    }

    private func clockSeconds() -> Double {
        if usesAudioClock, let player { return pendingAudioStart ?? player.clock.seconds(atHost: Self.hostSeconds()) }
        return hostClock.seconds + Double(speed) * (Self.hostSeconds() - hostClock.host)
    }

    private func stopPlaying() {
        guard isPlaying else { return }
        isPlaying = false
        clockGeneration += 1
        pendingAudioStart = nil
        player?.stop()
        sound.stopped()
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
            access: session.access, notices: session.notices, applyingDefaultStyle: isApplyingDefaultStyle,
            applyingStyle: isApplyingStyle, legacyDismissed: windowMemory.state.legacyBannerDismissed || editedHere,
            recoveryDismissed: dismissedRecovery, reopenedDismissed: dismissedReopened,
            inGap: missingVideo.contains { $0.contains(currentSeconds) })
        guard banner != next else { return }
        banner = next
        // VoiceOver says a banner as it comes up: the amber one above all, whose edits wait in memory.
        if let next {
            let warning: Bool = switch next {
            case .saveFailed, .waitingForSpace: true
            case .readOnly, .reopenedAfterOtherApp, .recovered, .legacyLook, .videoGap: false
            }
            NSAccessibility.post(
                element: window ?? NSApp as Any, notification: .announcementRequested,
                userInfo: [
                    .announcement: EditorBanners.text(next),
                    .priority: (warning ? NSAccessibilityPriorityLevel.high : .medium).rawValue,
                ])
        }
    }

    /// The most pressing banner: a save that failed, then why the project is read-only, then what opening found, then
    /// the earlier version's look, then a part of the video that could not be read under the playhead.
    private static func banner(
        access: EditAccess, notices: [EditNotice], applyingDefaultStyle: Bool, applyingStyle: Bool, legacyDismissed: Bool,
        recoveryDismissed: Bool, reopenedDismissed: Bool, inGap: Bool
    ) -> EditorBanner? {
        for case let .saveFailed(code) in notices {
            // Its image waits for room: nothing of the style is applied yet.
            let waiting = (applyingDefaultStyle || applyingStyle) && (code == .ENOSPC || code == .EDQUOT)
            return waiting ? .waitingForSpace(defaultStyle: applyingDefaultStyle) : .saveFailed(code)
        }
        if case let .readOnly(reason) = access { return .readOnly(reason) }
        if !reopenedDismissed, notices.contains(.reopenedAfterOtherApp) { return .reopenedAfterOtherApp }
        if !recoveryDismissed { for case let .recovered(date) in notices { return .recovered(upTo: date) } }
        if !legacyDismissed, notices.contains(.legacyLook) { return .legacyLook }
        return inGap ? .videoGap : nil
    }

    // MARK: - Export

    /// What the export sheet asked to export (1c design §7.1).
    enum ExportJob: Sendable {
        /// An MP4 with `settings`, of `range`, or of the whole video for `nil` (as in 1b).
        case mp4(ExportSettings, range: ExportRange?)
        /// A GIF of `settings.range`.
        case gif(GIFSettings)
    }

    /// The project the export sheet's GIF estimate and preview are made of: the session's, read from where its package is
    /// now; `nil` without a session.
    var exportProject: LoadedProject? { session.map { currentProject(of: $0) } }

    /// Exports `document`, the copy the export sheet took (what is edited meanwhile is not in it), as `job` says, from the
    /// package where it is now (`ExportSheet`). An MP4 and a GIF are the same to the rest of the app: one export at a time
    /// in the whole app (`ExportGate`), the bar's ring with "Cancel Export", and closing the window or quitting asks first
    /// while it runs (`isExporting`, the gate). `false`, and nothing done, while another one runs or the project cannot be
    /// exported.
    func startExport(_ document: EditDocument, _ job: ExportJob, to destination: URL) -> Bool {
        guard canExport, let session else { return false }
        let project = currentProject(of: session)
        exportGate.isBusy = true
        exportFinishedTask?.cancel()
        exportState = .running(progress: 0)
        let throttle = ProgressThrottle()
        // Called off the main thread, per frame.
        let progress: @Sendable (Double) -> Void = { [weak self] value in
            guard throttle.shouldReport(value) else { return }
            Task { @MainActor in self?.exportProgressed(value) }
        }
        exportTask = Task {
            do {
                // What each feature needs before the export (its analysis done); one that says no stops it quietly.
                for preparation in exportPreparations {
                    try Task.checkCancellation()
                    guard await preparation(self) else { throw CancellationError() }
                }
                let analysis = analysis
                switch job {
                case let .mp4(settings, range):
                    let exporter = MP4Exporter(
                        project: project, document: document, settings: settings, range: range, analysis: analysis)
                    let summary = try await exporter.export(to: destination, progress: progress)
                    exportFinished(at: destination)
                    let leftOut = Self.leftOut(summary, take: project.take)
                    if !leftOut.isEmpty { showAlert(leftOut.joined(separator: "\n\n"), style: .warning) }
                case let .gif(settings):
                    let exporter = GIFExporter(project: project, document: document, settings: settings, analysis: analysis)
                    try await exporter.export(to: destination, progress: progress)
                    exportFinished(at: destination)
                }
            } catch let error where Self.isCancellation(error) {
                exportState = .idle
            } catch {
                Self.logger.error("Export to \(destination.path, privacy: .public) failed: \(String(describing: error), privacy: .public)")
                exportState = .idle
                switch job {
                case .mp4:
                    showAlert(String(localized: "Couldn't export the video"), informative: userFacingDescription(of: error), style: .warning)
                case .gif:
                    showAlert(Self.gifExportFailure(error, destination: destination), style: .warning)
                }
            }
            exportGate.isBusy = false
            exportTask = nil
        }
        return true
    }

    /// "Export finished · Show in Finder · Copy" in the bar, for `exportFinishedDuration`.
    private func exportFinished(at destination: URL) {
        exportState = .finished(destination)
        exportFinishedTask = Task {
            try? await Task.sleep(for: Self.exportFinishedDuration)
            guard !Task.isCancelled, exportState == .finished(destination) else { return }
            exportState = .idle
        }
    }

    /// "Couldn't export the GIF: …" (1c design §7.4) with why, in words: `GIFExportError` (a write that failed says which
    /// error, by name for the common ones), and the `ExportError` and `RenderError` the GIF's export also throws (a
    /// destination it never writes to, a frame the GPU could not draw).
    private static func gifExportFailure(_ error: any Error, destination: URL) -> String {
        let reason: String =
            switch error {
            case GIFExportError.diskFull, ExportError.diskFull:
                // The library's words for it, the same in the GIF's alert.
                String(localized: "the disk is full")
            // The library's words for the common ones.
            case GIFExportError.write(.EACCES), GIFExportError.write(.EPERM):
                String(localized: "there's no permission")
            case GIFExportError.write(.EROFS):
                String(localized: "the disk is read-only")
            case GIFExportError.write(.EIO):
                String(localized: "the disk failed")
            case GIFExportError.write(let code):
                String(localized: "the file couldn't be written (error \(code.rawValue))", comment: "Why a GIF couldn't be exported, after “Couldn't export the GIF:”")
            case GIFExportError.rangeShorterThanAFrame, ExportError.nothingToExport:
                String(localized: "the range lasts less than a frame", comment: "Why a GIF couldn't be exported, after “Couldn't export the GIF:”")
            case ExportError.destinationNotAllowed where isInsideAProject(destination):
                String(localized: "it can't be saved inside a project; choose a folder outside it", comment: "Why a GIF couldn't be exported, after “Couldn't export the GIF:”")
            case ExportError.destinationNotAllowed:
                // A folder or a link where the GIF would go.
                String(localized: "it can't be saved there", comment: "Why a GIF couldn't be exported, after “Couldn't export the GIF:”")
            case RenderError.noMetalDevice:
                String(localized: "this Mac has no graphics device to draw it", comment: "Why a GIF couldn't be exported, after “Couldn't export the GIF:”")
            case is RenderError:
                String(localized: "its frames couldn't be drawn", comment: "Why a GIF couldn't be exported, after “Couldn't export the GIF:”")
            default:
                String(localized: "an unexpected error occurred", comment: "Why a GIF couldn't be exported, after “Couldn't export the GIF:”")
            }
        return String(format: String(localized: "Couldn't export the GIF: %@", comment: "An alert: a GIF export that failed, and why"), reason)
    }

    /// Whether `destination` is inside a project package (`*.toma`), where an export never writes, as given or with its
    /// links resolved.
    private static func isInsideAProject(_ destination: URL) -> Bool {
        [destination.standardizedFileURL, destination.resolvingSymlinksInPath()].contains { url in
            url.pathComponents.dropLast().contains {
                ($0 as NSString).pathExtension.lowercased() == ProjectPackage.fileExtension.lowercased()
            }
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

    /// Copy, once an export finished (1c decision 24): the file (its URL) on the clipboard, to paste it into Slack, Mail
    /// or an issue on GitHub as the file itself.
    func copyExport() {
        guard case let .finished(url) = exportState else { return }
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.writeObjects([url as NSURL])
    }

    private func exportProgressed(_ value: Double) {
        guard case .running(let progress) = exportState, value > progress else { return }
        exportState = .running(progress: value)
    }

    private static func isCancellation(_ error: any Error) -> Bool {
        error is CancellationError || (error as? ExportError) == .cancelled || (error as? GIFExportError) == .cancelled
    }

    // MARK: - Where the package is

    /// Where the package is now: where its session finds it, or where it was last seen.
    var currentLocation: URL {
        session?.packageURL.standardizedFileURL ?? location
    }

    /// The package was renamed or moved, by this editor, the library or the Finder (design §6.7): the name and the window
    /// follow it, and the session goes on writing into it. If it went into the trash or out of it, it opens again, for
    /// viewing only or editable (1c decision 36), once, after one look at where it is; a take that did not finish saving
    /// only switches between Recover and Restore. An editable one with changes that couldn't be saved stays as it is:
    /// opening again would lose them.
    func packageMayHaveMoved() {
        guard !closed else { return }
        if let session { noteLocation(session.packageURL) }
        switch state {
        case .ready, .unfinished: break
        case .opening, .recovering, .failed, .newerDocument: return
        }
        guard !isLookingAtTheTrash else { return }
        isLookingAtTheTrash = true
        let url = location, projectsFolder = projectsFolder, wasInTrash = isInTrash
        Task {
            let inTrash = await Task.detached { ProjectTrash.contains(url, projectsFolder: projectsFolder) }.value
            isLookingAtTheTrash = false
            guard !closed, location == url, isInTrash == wasInTrash, inTrash != wasInTrash else { return }
            switch state {
            case .ready:
                guard !(inTrash && losesEditsIfClosed) else { return }
                load()
            case .unfinished:
                isInTrash = inTrash
            case .opening, .recovering, .failed, .newerDocument:
                break
            }
        }
    }

    /// The package is at `url` now (this editor renamed or restored it).
    func follow(to url: URL) {
        noteLocation(url)
    }

    /// Restored from the trash to `url`: the session for viewing closes, and the project opens again there, editable.
    func reopen(at url: URL) {
        noteLocation(url)
        load()
    }

    /// The package is at `url`: the name and `location` follow it, and the window is told.
    private func noteLocation(_ url: URL) {
        let url = url.standardizedFileURL
        guard url != location.standardizedFileURL else { return }
        location = url
        name = url.deletingPathExtension().lastPathComponent
        onLocationChanged()
    }

    /// Waits until the journal confirmed every line handed to it so far (`EditSession.flushed()`): what the editor shows
    /// is on the disk, before a copy is made of it.
    func flushed() async {
        _ = await session?.flushed()
    }

    /// Some change is not on the disk yet (`EditSession.hasUnsavedChanges`): a copy made now would not have it.
    var hasUnsavedChanges: Bool { session?.hasUnsavedChanges ?? false }

    // MARK: - Closing

    /// The window closed, or the app quits: its state is written, playback stops, the export sheet ends if it is up, an
    /// export in progress is cancelled (the window asked first), and the session closes (its last lines, snapshot and lock), off the main thread (`closing`). An "Apply Default Style" waiting for room on a full disk gives up as
    /// the session closes, without applying anything (cancelling its task would apply Toma's gradient instead).
    func close() {
        guard !closed else { return }
        writeWindowState()
        stopAutosave()
        closed = true
        if let preferencesObserver { NotificationCenter.default.removeObserver(preferencesObserver) }
        preferencesObserver = nil
        openTask?.cancel()
        followCursorTask?.cancel()
        // An export sheet still over the window ends: its GIF preview and estimate stop, and the project it holds goes.
        endExportSheet()
        let export = exportTask
        export?.cancel()
        exportFinishedTask?.cancel()
        tearDownPreview()
        image.close()
        Task { [jobs] in await jobs.cancelAll() }
        session?.onChange = nil
        // Where it was last seen, for who looks at it once it closed.
        if let session { noteLocation(session.packageURL) }
        // A session still opening (at first, or again after Restore) closes itself once it has opened: waited for too, so
        // that once this ends no `edit.lock` of this editor is held.
        closing = Task { [session, openTask] in
            await openTask?.value
            await session?.close()
            await export?.value
        }
        session = nil
        packageHandle = nil
    }

    /// Returns once `close()` has closed the session and the export it cancelled has ended.
    func waitUntilClosed() async {
        await closing?.value
    }

    /// Closing the session now would lose edits that couldn't be saved (`EditorClosing.losesEdits`): quitting asks first.
    var losesEditsIfClosed: Bool {
        EditorClosing.losesEdits(hasUnsavedChanges: session?.hasUnsavedChanges ?? false, notices: session?.notices ?? [])
    }

    /// An export of this editor is running.
    var isExporting: Bool {
        if case .running = exportState { true } else { false }
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
