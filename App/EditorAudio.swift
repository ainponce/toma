// SPDX-License-Identifier: GPL-3.0-or-later
import AVFoundation
import AppKit
import Editing
import Export
import Observation
import ProjectFormat
import ProjectJobs
import os

/// The music of the editor (phase 3 design §7.4 to §7.7, plan 3c decisions 4, 6, 16 and 18): what the mix reads of it,
/// made once into the caches by `MusicAnalysis` and handed to the preview and the export through the base's seam
/// (`EditorModel.updateAnalysis(_:)`, `exportPreparations`), and the themes of the library heard before one is chosen.
///
/// - **Followed.** With each document whose needs change (its music's sources, the ducking and the takes its sequence
///   shows, the imported clips), what the caches hold is read (`MusicAnalysis.cached(for:)`, off the main thread) and
///   handed over at once; then what is missing is made (`prepare`) in a task, and handed over as it arrives (each rise of
///   its progress reads the caches again). A theme being made is "Preparing…" in the Music track and in the section,
///   with the progress there is (a theme's synthesis says none until it is done: up to two minutes in a Debug build,
///   under 3 s in Release), and the preview leaves it silent meanwhile.
/// - **Kept while it is needed.** Each theme of the document is asked of the library by a task of its own, which is only
///   cancelled once the theme leaves the document: so a new `prepare` (another edit) never starts its synthesis again,
///   and taking the theme out stops it (`MusicLibrary` stops work nobody waits for).
/// - **Drawn.** The length of each source once its file is there (a theme's 2:00, an imported sound's decoding) and the
///   waveform of each (`AudioFileWaveform`), and of each imported clip's file, for the Music and Imported Clips rows.
/// - **The export.** `prepareExport` waits for what the exported document's music needs, with its progress on the ring,
///   and gives it to the export; a file that cannot be written stops it with "Couldn't prepare the music: …".
/// - **Listening.** `listen(to:)` makes the theme if it is missing ("Preparing…") and plays it with `AVAudioPlayer`, one
///   at a time; it pauses the editor, and the editor playing stops it.
@MainActor @Observable
final class EditorAudio {
    /// The app's music library: one for every editor, so two asking for a theme at once wait for one synthesis.
    static let library = MusicLibrary.shared

    /// What the Music track and the Music section show of the music, as the caches have it now.
    struct Shown: Equatable {
        /// The length in ns of each source whose file is there, by `MusicItem.source`.
        var lengths: [String: Int64] = [:]
        /// The sources whose files are being made.
        var preparing: Set<String> = []
        /// How far the making is, 0 to 1, once it says (a theme's synthesis does not until it is done).
        var progress: Double?
        /// The imported sounds decoded to their limit (30 min, plan decision 6): "Only the first 30 minutes are used."
        var capped: Set<String> = []
        /// Counts the waveforms that arrived (`waveforms`).
        var waveforms = 0
    }

    /// What the document needs of the music, as the caches are read for it.
    private struct Needs: Equatable {
        /// Each source of the music once, in order.
        var sources: [String]
        var voice: Bool
        /// The takes the sequence shows.
        var takes: [String]
        /// The files of the imported clips (`assets/…` of a clip of the sequence or a clip annotation), each once.
        var clips: [String]

        init(_ document: EditDocument, project: LoadedProject) {
            var seen: Set<String> = []
            sources = document.music.items.compactMap { seen.insert($0.source).inserted ? $0.source : nil }
            voice = !document.music.items.isEmpty && document.music.ducking.enabled
            takes = voice ? project.takeRecords(shownBy: document).map(\.id) : []
            var assets: [String] = []
            for clip in document.sequence {
                if case let .media(media)? = clip.content, seen.insert(media.asset).inserted { assets.append(media.asset) }
            }
            for annotation in document.annotations.items {
                if case let .clip(clip) = annotation.kind, seen.insert(clip.asset).inserted { assets.append(clip.asset) }
            }
            clips = assets
        }
    }

    private(set) var shown = Shown()
    /// The waveform of each source of the music and of each imported clip's file, by its `source` or `asset`.
    @ObservationIgnored private(set) var waveforms: [String: WaveformLevels] = [:]
    /// The theme of the library being listened to (or made to be), and whether it is still being made.
    private(set) var listening: String?
    private(set) var listeningPreparing = false
    /// The list of the library is open (over "Add Music…" or "Replace Music…"), and the piece it replaces (`nil`: it adds).
    var showsLibrary = false
    var libraryReplaces: String?

    @ObservationIgnored private weak var model: EditorModel?
    @ObservationIgnored private var project: LoadedProject?
    @ObservationIgnored private var caches: ProjectCaches?
    @ObservationIgnored private var analysis: MusicAnalysis?
    @ObservationIgnored private var document: EditDocument?
    @ObservationIgnored private var needs: Needs?
    /// Each theme of the document, asked of the library until it leaves it, and those whose asking returned.
    @ObservationIgnored private var themes: [String: Task<Void, Never>] = [:]
    @ObservationIgnored private var themesAsked: Set<String> = []
    @ObservationIgnored private var prepareTask: Task<Void, Never>?
    /// Counts the `prepare`s, so only the latest says how far it is and hands its result over.
    @ObservationIgnored private var preparing = 0
    @ObservationIgnored private var readTask: Task<Void, Never>?
    /// A reading of the caches was asked for while one ran: it runs again once that ends.
    @ObservationIgnored private var readAgain = false
    /// The files whose waveforms were asked for, by their path.
    @ObservationIgnored private var waveformsAsked: Set<String> = []
    @ObservationIgnored private var waveformWork: [Task<Void, Never>] = []
    @ObservationIgnored private var player: AVAudioPlayer?
    @ObservationIgnored private var playerEnd: ListenEnd?
    @ObservationIgnored private var listenTask: Task<Void, Never>?
    @ObservationIgnored private var closed = false

    /// The waveforms of the themes, the same for every project: made once in the app.
    private static var themeWaveforms: [String: WaveformLevels] = [:]
    private nonisolated static let logger = Logger(subsystem: "dev.toma.Toma", category: "EditorAudio")
    /// How long a theme asked to be heard may take before "Preparing…" says it is being made.
    private static let preparingDelay = Duration.milliseconds(250)

    /// The music of `model`'s project, which it holds weakly.
    init(model: EditorModel) {
        self.model = model
        followPlayback()
    }

    // MARK: - What the editor tells it

    /// The session opened `project` with its analysis caches `caches` and `document`: what was there before is
    /// forgotten, and what `document` needs is read and made.
    func opened(project: LoadedProject, caches: ProjectCaches, document: EditDocument) {
        guard !closed else { return }
        self.project = project
        self.caches = caches
        analysis = MusicAnalysis(project: project, caches: caches, library: Self.library)
        needs = nil
        for task in themes.values { task.cancel() }
        themes = [:]
        themesAsked = []
        prepareTask?.cancel()
        prepareTask = nil
        waveformsAsked = []
        for task in waveformWork { task.cancel() }
        waveformWork = []
        waveforms = Self.themeWaveforms
        shown = Shown(waveforms: shown.waveforms + 1)
        documentChanged(document)
    }

    /// The session's document changed: what it needs is read and made, if that changed.
    func documentChanged(_ document: EditDocument) {
        guard !closed, let project else { return }
        self.document = document
        let next = Needs(document, project: project)
        guard next != needs else { return }
        needs = next
        keepThemes(next)
        read()
        prepare(document)
    }

    /// What an export does first (`EditorModel.exportPreparations`): waits for the files and the voice the exported
    /// document's music needs (`MusicAnalysis.prepareExport`), reporting how far it is, and hands them to the export with
    /// what makes again a file macOS removes before the exporter opens it (`remaking(for:)`, `MP4Exporter.remakeMusic`);
    /// the preview reads the caches again. Nothing for a GIF, which has no sound, nor a document without music. `false`,
    /// which stops the export, when it was cancelled meanwhile (saying nothing) or a file could not be made ("Couldn't
    /// prepare the music: …").
    func prepareExport(_ model: EditorModel, _ export: ExportPreparation) async -> Bool {
        guard !closed, let caches else { return true }
        let document = export.document
        guard export.hasSound, !document.music.items.isEmpty else {
            export.analysis.musicFiles = [:]
            export.analysis.voiceActivity = [:]
            return true
        }
        // From where the package is now: the export reads the imported sounds there.
        let analysis = MusicAnalysis(project: export.project, caches: caches, library: Self.library)
        let report = RisingReport(export)
        do {
            let inputs = try await analysis.prepareExport(document, onto: export.analysis) { fraction in
                Task { @MainActor in report.send(fraction) }
            }
            report.finish()
            guard !Task.isCancelled, !closed else { return false }
            export.analysis = inputs
            // What macOS removes from the caches before the exporter opens it is made again then, once.
            export.remakeMusic = analysis.remaking(for: document)
            read()
            return true
        } catch {
            report.finish()
            // "Cancel Export", or the window closing: the export ends without a word.
            guard !Task.isCancelled, !closed else { return false }
            Self.logger.error("The music for the export failed: \(String(describing: error), privacy: .public)")
            showFailure(error, in: model)
            return false
        }
    }

    /// The editor closed: nothing more is made, read, handed over or heard.
    func close() {
        guard !closed else { return }
        closed = true
        stopListening()
        for task in Array(themes.values) + waveformWork + [prepareTask, readTask].compactMap({ $0 }) { task.cancel() }
        themes = [:]
        waveformWork = []
        prepareTask = nil
        readTask = nil
        analysis = nil
        project = nil
        caches = nil
        document = nil
    }

    // MARK: - Listening

    /// Plays theme `id` of the library from its start, made first if it is not there ("Preparing…" after a moment): the
    /// editor pauses, and the theme heard before stops.
    func listen(to id: String) {
        guard !closed else { return }
        stopListening()
        model?.pause()
        listening = id
        listenTask = Task { [weak self] in
            let notice = Task { @MainActor [weak self] in
                try? await Task.sleep(for: Self.preparingDelay)
                guard !Task.isCancelled, let self, self.listening == id, self.player == nil else { return }
                self.listeningPreparing = true
            }
            defer { notice.cancel() }
            let url: URL
            do {
                url = try await Self.library.file(for: id)
            } catch {
                guard !Task.isCancelled, let self, self.listening == id else { return }
                Self.logger.error("Theme \(id, privacy: .public) can't be heard: \(String(describing: error), privacy: .public)")
                self.stopListening()
                NSSound.beep()
                return
            }
            // Opening the file reads it: never on the main thread.
            let made = await Task.detached(priority: .userInitiated) { () -> PlayerBox? in
                guard let player = try? AVAudioPlayer(contentsOf: url) else { return nil }
                player.prepareToPlay()
                return PlayerBox(player: player)
            }.value
            guard !Task.isCancelled, let self, self.listening == id else { return }
            guard let player = made?.player else {
                self.stopListening()
                NSSound.beep()
                return
            }
            let identity = ObjectIdentifier(player)
            let end = ListenEnd { [weak self] in
                guard let self, let current = self.player, ObjectIdentifier(current) == identity else { return }
                self.stopListening()
            }
            player.delegate = end
            self.player = player
            self.playerEnd = end
            self.listeningPreparing = false
            player.play()
        }
    }

    /// The theme heard (or being made to be) stops; what it was making goes on only if someone else waits for it.
    func stopListening() {
        listenTask?.cancel()
        listenTask = nil
        player?.stop()
        player = nil
        playerEnd = nil
        if listening != nil { listening = nil }
        if listeningPreparing { listeningPreparing = false }
    }

    // MARK: - Words

    /// The name of theme `id` of the library (plan decision 2): Calm, Focus, Drive, Piano, Pulse, Breeze.
    static func name(ofTheme id: String) -> String {
        switch id {
        case "calm": String(localized: "Calm", comment: "A theme of the music library (ambient)")
        // Not "Focus", which is a zoom's (Enfoque).
        case "focus": String(localized: "theme.focus", comment: "A theme of the music library (lo-fi): Focus")
        case "drive": String(localized: "Drive", comment: "A theme of the music library (upbeat pop)")
        case "piano": String(localized: "Piano", comment: "A theme of the music library (minimal piano)")
        case "pulse": String(localized: "Pulse", comment: "A theme of the music library (electronic)")
        case "breeze": String(localized: "Breeze", comment: "A theme of the music library (plucked strings)")
        default: id
        }
    }

    /// What theme `id` sounds like, under its name in the list.
    static func style(ofTheme id: String) -> String {
        switch id {
        case "calm": String(localized: "Ambient", comment: "The style of a theme of the music library")
        case "focus": String(localized: "Lo-fi", comment: "The style of a theme of the music library")
        case "drive": String(localized: "Upbeat Pop", comment: "The style of a theme of the music library")
        case "piano": String(localized: "Minimal Piano", comment: "The style of a theme of the music library")
        case "pulse": String(localized: "Electronic", comment: "The style of a theme of the music library")
        case "breeze": String(localized: "Plucked Strings", comment: "The style of a theme of the music library")
        default: ""
        }
    }

    /// What a piece of music is called in the track and the section: its theme's name, or "Imported Audio" for a file
    /// of the user's (its name in the package is its content's hash).
    static func name(ofSource source: String) -> String {
        if let id = MusicThemes.id(ofSource: source) { return name(ofTheme: id) }
        return String(localized: "Imported Audio", comment: "A piece of music of the Music track that is a file of the user's, not a theme of the library")
    }

    /// "Preparing…": a theme or an imported sound being made into the caches.
    static var preparingText: String {
        String(localized: "Preparing…", comment: "A theme of the music library or an imported sound being made before it can be heard")
    }

    // MARK: - Private

    /// The editor playing stops the theme heard.
    private func followPlayback() {
        guard !closed else { return }
        withObservationTracking {
            if model?.isPlaying == true, listening != nil { stopListening() }
        } onChange: { [weak self] in
            Task { @MainActor in self?.followPlayback() }
        }
    }

    /// A task for each theme `next` has and none yet asks the library for (it reads the caches again once the theme is
    /// there); those of themes no longer there are cancelled.
    private func keepThemes(_ next: Needs) {
        let ids = Set(next.sources.compactMap(MusicThemes.id(ofSource:)))
        for (id, task) in themes where !ids.contains(id) {
            task.cancel()
            themes[id] = nil
            themesAsked.remove(id)
        }
        for id in ids where themes[id] == nil {
            themes[id] = Task { [weak self] in
                do {
                    _ = try await Self.library.file(for: id)
                } catch {
                    guard !Task.isCancelled else { return }
                    Self.logger.error("Theme \(id, privacy: .public) could not be made: \(String(describing: error), privacy: .public)")
                }
                guard !Task.isCancelled, let self, self.themes[id] != nil else { return }
                self.themesAsked.insert(id)
                self.read()
            }
        }
    }

    /// Makes what `document` needs that is missing, in a task: each rise of its progress reads the caches again, so
    /// what arrives is heard as it arrives; its result is handed over once it is done.
    private func prepare(_ document: EditDocument) {
        guard let analysis else { return }
        prepareTask?.cancel()
        preparing += 1
        let current = preparing
        shown.progress = nil
        let rise: @Sendable (Double) -> Void = { [weak self] fraction in
            Task { @MainActor [weak self] in self?.rose(to: fraction, preparing: current) }
        }
        prepareTask = Task { [weak self] in
            do {
                _ = try await analysis.prepare(document, progress: rise)
            } catch is CancellationError {
                return
            } catch {
                Self.logger.error("The music could not be prepared: \(String(describing: error), privacy: .public)")
            }
            guard let self, current == self.preparing, !self.closed else { return }
            self.prepareTask = nil
            self.shown.progress = nil
            self.read()
        }
    }

    /// `prepare` number `current` is `fraction` done: shown, and the caches read again for what it made, if it rose and is
    /// still the latest.
    private func rose(to fraction: Double, preparing current: Int) {
        guard current == preparing, !closed, fraction > max(shown.progress ?? 0, 0), 1 > fraction else { return }
        if !shown.preparing.contains(where: { MusicThemes.id(ofSource: $0) != nil }) { shown.progress = fraction }
        read()
    }

    /// Reads what the caches hold for the latest document off the main thread, and hands it over: the files and the
    /// voice to the preview, the lengths and what is still being made to the track and the section, and asks for the
    /// waveforms not drawn yet. One reading at a time; one asked for meanwhile runs once it ends.
    private func read() {
        guard !closed, let analysis, let document, let project else { return }
        guard readTask == nil else {
            readAgain = true
            return
        }
        readAgain = false
        // What is read depends only on the needs: an edit that keeps them (a piece moved) keeps the reading.
        let needs = self.needs
        readTask = Task { [weak self] in
            let cached = await analysis.cached(for: document)
            let sizes = await Task.detached(priority: .utility) { Self.lengths(of: cached.musicFiles) }.value
            guard let self, !self.closed else { return }
            self.readTask = nil
            if self.needs == needs {
                self.hand(cached, lengths: sizes, project: project)
            }
            if self.readAgain || self.needs != needs { self.read() }
        }
    }

    /// Hands `cached` over (see `read`).
    private func hand(_ cached: MusicAnalysis.Prepared, lengths: (lengths: [String: Int64], capped: Set<String>), project: LoadedProject) {
        guard let model, let needs else { return }
        model.updateAnalysis { analysis in
            analysis.musicFiles = cached.musicFiles
            analysis.voiceActivity = cached.voiceActivity
        }
        model.exportSheetAnalysisChanged()
        var next = shown
        next.lengths = lengths.lengths
        next.capped = lengths.capped
        // Missing and being made: a theme the library has not given yet, or anything while `prepare` runs.
        next.preparing = Set(needs.sources.filter { source in
            guard cached.musicFiles[source] == nil else { return false }
            if let id = MusicThemes.id(ofSource: source), themes[id] != nil, !themesAsked.contains(id) { return true }
            return prepareTask != nil
        })
        // A theme's synthesis says nothing until it is done: with one being made, how far is not known.
        if next.preparing.isEmpty || next.preparing.contains(where: { MusicThemes.id(ofSource: $0) != nil }) { next.progress = nil }
        if next != shown { shown = next }
        for (source, url) in cached.musicFiles { askWaveform(source, url: url) }
        for asset in needs.clips {
            askWaveform(asset, url: nil, project: project)
        }
    }

    /// Works out the waveform of `key`'s file off the main thread, once per file: `url`, or the imported clip `key` of
    /// `project`'s package (`ProjectPackage.mediaAsset(_:as:)`, which reads nothing through a link).
    private func askWaveform(_ key: String, url: URL?, project: LoadedProject? = nil) {
        if let theme = Self.themeWaveforms[key] {
            if waveforms[key] == nil {
                waveforms[key] = theme
                shown.waveforms += 1
            }
            return
        }
        let asked = url?.path ?? "clip \(key)"
        guard waveformsAsked.insert(asked).inserted else { return }
        let package = project?.package
        let isTheme = MusicThemes.id(ofSource: key) != nil
        waveformWork.append(Task { [weak self] in
            var file = url
            if file == nil { file = await Task.detached(priority: .utility) { package?.mediaAsset(key, as: .video) }.value }
            guard let file else { return }
            let waveform = await AudioFileWaveform.waveform(of: file)
            let levels = await Task.detached(priority: .utility) { WaveformLevels(waveform) }.value
            guard !Task.isCancelled, let self, !self.closed, !waveform.pairs.isEmpty else { return }
            if isTheme { Self.themeWaveforms[key] = levels }
            self.waveforms[key] = levels
            self.shown.waveforms += 1
        })
    }

    /// The length of each file of `files` and the imported sounds decoded to their limit: a theme's from the library's
    /// rule (2:00), an imported sound's from its size (`MusicFile`: 68 bytes, then 8 a frame at 48 kHz). Reads each one's
    /// `lstat`: never on the main thread.
    private nonisolated static func lengths(of files: [String: URL]) -> (lengths: [String: Int64], capped: Set<String>) {
        var lengths: [String: Int64] = [:]
        var capped: Set<String> = []
        for (source, url) in files {
            let frames: Int
            if MusicThemes.id(ofSource: source) != nil {
                frames = MusicThemes.loopFrames
            } else {
                var info = stat()
                guard lstat(url.path, &info) == 0, info.st_size > MusicFile.headerBytes else { continue }
                frames = (Int(info.st_size) - MusicFile.headerBytes) / MusicFile.frameBytes
                if frames >= ImportedAudio.maximumFrames { capped.insert(source) }
            }
            lengths[source] = Int64(frames) * 1_000_000_000 / Int64(MusicFile.sampleRate)
        }
        return (lengths, capped)
    }

    /// "Couldn't prepare the music: …" for `error`, over the editor's window.
    private func showFailure(_ error: any Error, in model: EditorModel) {
        let reason =
            switch error {
            case let error as JobError: EditorImage.reason(of: error.problem)
            default: String(localized: "an unexpected error occurred")
            }
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = String(
            format: String(
                localized: "Couldn't prepare the music: %@",
                comment: "An alert: an export stopped because a theme of the music library or an imported sound could not be made, and why"),
            reason)
        if let window = model.window, window.isVisible {
            alert.beginSheetModal(for: window)
        } else {
            alert.runModal()
        }
    }
}

/// The progress of the music's preparation to the export's ring, only rising, and nothing once it is done (a report
/// that arrives late is not the export's any more).
@MainActor
private final class RisingReport {
    private let export: ExportPreparation
    private var last = 0.0
    private var done = false

    init(_ export: ExportPreparation) {
        self.export = export
    }

    func send(_ fraction: Double) {
        guard !done, fraction > last else { return }
        last = fraction
        export.report(fraction)
    }

    func finish() {
        done = true
    }
}

/// A player made off the main thread, handed to it once.
///
/// Unchecked because `AVAudioPlayer` is not marked `Sendable`: it is made and prepared on one thread, then only used on
/// the main thread.
private final class PlayerBox: @unchecked Sendable {
    let player: AVAudioPlayer

    init(player: AVAudioPlayer) {
        self.player = player
    }
}

/// Says when the theme heard has played to its end.
private final class ListenEnd: NSObject, AVAudioPlayerDelegate {
    private let ended: @MainActor @Sendable () -> Void

    init(_ ended: @escaping @MainActor @Sendable () -> Void) {
        self.ended = ended
    }

    func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        Task { @MainActor [ended] in ended() }
    }
}
