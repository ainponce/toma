// SPDX-License-Identifier: GPL-3.0-or-later
import AppKit
import AppSupport
import Editing
import Export
import Observation
import ProjectFormat
import SwiftUI
import os

/// What the export sheet (design §5.6, 1c design §7.1) has chosen. Its options are parameters of the export, never edits:
/// nothing of them goes into the document or its log, and a project of an earlier version is never upgraded by them.
/// Export As, the MP4's resolution and quality and the GIF's options start at what the sheet remembers
/// (`ExportPreferences`, in the app's settings); the MP4's frames per second at the project's, every time; the range at
/// its default for the kind (`ExportRangeRules.defaultRange`) until one is chosen.
///
/// For a GIF it also makes the preview and the estimate (1c design §7.3) as the options change (`optionsChanged(to:)`),
/// until the sheet ends (`stop()`).
@MainActor @Observable
final class ExportChoices {
    /// The sheet's Range.
    enum RangeChoice: Hashable {
        case whole
        /// Between the marks: only offered with both marks (`marked`).
        case marks
    }

    /// What the GIF's preview and estimate are made for: they are made again when it changes.
    struct GIFRequest: Hashable {
        var longSide: Int
        var fps: Int
        var quality: GIFQuality
        var dither: Bool
        var loops: Bool
        var start: Int64
        var end: Int64

        var settings: GIFSettings {
            GIFSettings(
                longSide: longSide, fps: fps, quality: quality, dither: dither, loops: loops,
                range: ExportRange(start: start, end: end))
        }
    }

    /// The document's format: shown, never chosen here (the bar and the Project menu change it).
    let aspect: Aspect
    /// The ratio "Like the Recording" follows (`StageLayout.contentRatio`); `nil` without a screen.
    let contentRatio: Double?
    /// What the output lasts, in nanoseconds and in seconds.
    let duration: Int64
    let durationSeconds: Double
    /// The range between the marks, cut to the video (`ExportRangeRules.markedRange`); `nil` without both marks.
    let marked: Range<Int64>?
    /// The shorter side of what was recorded of the screen, in pixels; `nil` when unknown.
    let recordedShortSide: Int?

    var kind: ExportKind {
        didSet { if kind != oldValue, !rangeWasChosen { rangeChoice = Self.defaultChoice(kind, marked: marked, duration: duration) } }
    }
    /// The Range shown; set through `chooseRange(_:)`, which the Range menu does.
    private(set) var rangeChoice: RangeChoice
    // The MP4's options.
    var resolution: ExportResolution
    var framesPerSecond: Int
    var quality: ExportQuality
    // The GIF's options.
    var gifLongSide: Int
    var gifFramesPerSecond: Int
    var gifQuality: GIFQuality
    var dither: Bool
    var loops: Bool

    /// The GIF's preview, once made; `nil` until then or when there is none to make.
    private(set) var preview: GIFPreviewImage?
    /// The preview of the current options is being made ("Making the preview…").
    private(set) var isMakingPreview = false
    /// The estimate of the current options: first from the preview alone, then refined; `nil` while it is being made
    /// ("Calculating…").
    private(set) var estimate: GIFEstimateResult?
    /// The preview or the estimate could not be made (logged): neither is shown.
    private(set) var estimateFailed = false

    @ObservationIgnored private let project: LoadedProject
    @ObservationIgnored private let document: EditDocument
    /// What the GIF's preview and estimate read of the analysis caches, as the export does (`EditorModel.analysis`):
    /// the editor's when the sheet opened, then as it changes (`analysisChanged(_:)`).
    @ObservationIgnored private var analysis: AnalysisInputs
    /// Where the preview starts if it is inside the range: the playhead, in output nanoseconds.
    @ObservationIgnored private let playhead: Int64
    /// The user chose a Range: changing Export As no longer moves it to the kind's default.
    @ObservationIgnored private var rangeWasChosen = false
    /// Counts the requests, so a request that was replaced never shows what it made.
    @ObservationIgnored private var generation = 0
    /// The preview and the estimate of the latest options: the first at once, each change 300 ms after it (1c design
    /// §7.3), a change cancelling the work before it; stopped when the sheet ends.
    @ObservationIgnored private let work = SettlingWork<GIFRequest>(settle: .milliseconds(300))
    private static let logger = Logger(subsystem: "dev.toma.Toma", category: "ExportSheet")

    init(
        document: EditDocument, project: LoadedProject, marks: TimelineMarks, playhead: Int64, remembered: ExportPreferences,
        contentRatio: Double? = nil, analysis: AnalysisInputs = .none
    ) {
        self.document = document
        self.project = project
        self.analysis = analysis
        self.playhead = playhead
        aspect = document.aspect
        self.contentRatio = contentRatio
        let timeMap = TimeMap(sequence: document.sequence)
        duration = timeMap.duration
        durationSeconds = timeMap.durationSeconds
        marked = ExportRangeRules.markedRange(marks, duration: duration)
        recordedShortSide = ExportPreferences.recordedShortSide(of: project.take)
        kind = remembered.kind
        rangeChoice = Self.defaultChoice(remembered.kind, marked: marked, duration: duration)
        resolution = ExportResolution(rawValue: remembered.shortSide) ?? .p1080
        framesPerSecond = StyleCommands.frameRates.contains(document.frameRate) ? document.frameRate : 60
        quality = remembered.highQuality ? .high : .standard
        let gif = remembered.gif
        gifLongSide = GIFSettings.longSides.contains(gif.longSide) ? gif.longSide : 800
        gifFramesPerSecond = GIFSettings.framesPerSecond.contains(gif.fps) ? gif.fps : 15
        gifQuality = GIFQuality(rawValue: gif.quality) ?? .balanced
        dither = gif.dither
        loops = gif.loops
    }

    /// The Range menu: `choice`, which stays when Export As changes.
    func chooseRange(_ choice: RangeChoice) {
        rangeWasChosen = true
        rangeChoice = choice
    }

    /// `kind`'s default Range: between the marks when that is `ExportRangeRules.defaultRange`, else the whole video.
    private static func defaultChoice(_ kind: ExportKind, marked: Range<Int64>?, duration: Int64) -> RangeChoice {
        ExportRangeRules.defaultRange(kind: kind, marks: marked, duration: duration) == 0..<max(0, duration) ? .whole : .marks
    }

    /// What is exported, in output nanoseconds.
    var range: Range<Int64> {
        switch rangeChoice {
        case .whole: 0..<max(0, duration)
        case .marks: marked ?? 0..<max(0, duration)
        }
    }

    var exportRange: ExportRange { ExportRange(start: range.lowerBound, end: range.upperBound) }

    /// What the range lasts, in seconds.
    var rangeSeconds: Double { Double(range.upperBound - range.lowerBound) / 1e9 }

    /// The frames per second of what is exported: the MP4's or the GIF's.
    var exportFramesPerSecond: Int { kind == .gif ? gifFramesPerSecond : framesPerSecond }

    /// Whether what the exporter draws of the range lasts at least a frame of the export
    /// (`ExportRangeRules.canExport(kind:range:duration:fps:)`: the MP4 of a part cut where `MP4Exporter` cuts it, then
    /// `TimeMap.lastsAFrame`, the one rule `ExportRange.lastsAFrame` is too). Without it, Export is disabled and the sheet
    /// says "The range has to last at least one frame."
    var lastsAFrame: Bool {
        ExportRangeRules.canExport(kind: kind, range: range, duration: duration, fps: exportFramesPerSecond)
    }

    /// The MP4 these choices make of the document.
    var settings: ExportSettings {
        ExportSettings(
            aspect: aspect, resolution: resolution, framesPerSecond: framesPerSecond, quality: quality, contentRatio: contentRatio)
    }

    /// The GIF these choices make of the document.
    var gifSettings: GIFSettings {
        GIFSettings(
            longSide: gifLongSide, fps: gifFramesPerSecond, quality: gifQuality, dither: dither, loops: loops, range: exportRange)
    }

    /// What Export… exports: the MP4 of the range, `nil` for the whole video (1b's export), or the GIF.
    var job: EditorModel.ExportJob {
        switch kind {
        case .mp4: .mp4(settings, range: rangeChoice == .marks ? exportRange : nil)
        case .gif: .gif(gifSettings)
        }
    }

    /// The options as chosen, for the sheet to remember those of the kind it exports
    /// (`ExportPreferences.remembering(_:chosen:)`).
    var preferences: ExportPreferences {
        ExportPreferences(
            shortSide: resolution.rawValue, highQuality: quality == .high, kind: kind,
            gif: GIFPreferences(
                longSide: gifLongSide, fps: gifFramesPerSecond, quality: gifQuality.rawValue, dither: dither, loops: loops))
    }

    /// About how big the MP4 of the range is, as a file size ("120 MB").
    var estimatedSize: String {
        ByteCountFormatter.string(fromByteCount: settings.estimatedBytes(durationSeconds: rangeSeconds), countStyle: .file)
    }

    /// Whether `resolution` has more pixels on its shorter side than what was recorded of the screen.
    func exceedsRecording(_ resolution: ExportResolution) -> Bool {
        recordedShortSide.map { ExportSettings.exceedsRecording(resolution, recordedShortSide: $0) } ?? false
    }

    /// The GIF's size with `longSide` on its longer side, in the document's format.
    func gifSize(longSide: Int) -> SIMD2<Int> {
        GIFSettings(longSide: longSide, range: exportRange).outputSize(aspect: aspect, contentRatio: contentRatio)
    }

    /// Whether the GIF of `longSide` has more pixels on its shorter side than what was recorded of the screen, as the
    /// MP4's resolutions are compared.
    func gifExceedsRecording(longSide: Int) -> Bool {
        let size = gifSize(longSide: longSide)
        return recordedShortSide.map { min(size.x, size.y) > $0 } ?? false
    }

    /// What the preview and the estimate are made for now: `nil` for an MP4, and for a range that does not last a frame.
    var gifRequest: GIFRequest? {
        guard kind == .gif, lastsAFrame else { return nil }
        return GIFRequest(
            longSide: gifLongSide, fps: gifFramesPerSecond, quality: gifQuality, dither: dither, loops: loops,
            start: range.lowerBound, end: range.upperBound)
    }

    /// The options are now `request` (and when the sheet appears): what was shown for the options before goes, and the
    /// preview and the estimate are made for it, the first time at once and from then on 300 ms after the last change
    /// (`SettlingWork`). The preview first, 3 s from the playhead; then the estimate, first from the preview alone and
    /// then refined (`GIFEstimate.estimates`). For `nil` (an MP4, or a range that does not last a frame), nothing.
    func optionsChanged(to request: GIFRequest?) {
        generation += 1
        let current = generation
        estimate = nil
        estimateFailed = false
        isMakingPreview = request != nil
        if request == nil { preview = nil }
        work.run(for: request) { [weak self] request in
            await self?.makePreviewAndEstimate(for: request, generation: current)
        }
    }

    /// The editor's analysis is now `analysis` (a camera's mask or face arrived): the GIF's preview and estimate are made
    /// again with it, as the export will draw. Nothing once the sheet ended.
    func analysisChanged(_ analysis: AnalysisInputs) {
        guard analysis != self.analysis else { return }
        self.analysis = analysis
        if let request = gifRequest { optionsChanged(to: request) }
    }

    /// The sheet ended: the preview and the estimate under way are cancelled, and none is made again. The work holds
    /// these choices weakly, so they go, with the project and its package's open folder, as soon as it notices.
    func stop() {
        generation += 1
        work.stop()
    }

    private func makePreviewAndEstimate(for request: GIFRequest, generation current: Int) async {
        let settings = request.settings, analysis = analysis
        do {
            let data = try await GIFEstimate.preview(
                project: project, document: document, settings: settings, playhead: playhead, analysis: analysis)
            guard current == generation, !Task.isCancelled else { return }
            preview = GIFPreviewImage(data, id: current)
            isMakingPreview = false
            for try await result in GIFEstimate.estimates(
                project: project, document: document, settings: settings, preview: data, analysis: analysis
            ) {
                guard current == generation, !Task.isCancelled else { return }
                estimate = result
            }
        } catch {
            guard current == generation, !Task.isCancelled, !(error is CancellationError),
                (error as? GIFExportError) != .cancelled
            else { return }
            Self.logger.error("The GIF's preview or estimate failed: \(String(describing: error), privacy: .public)")
            // Neither the preview nor the estimate of other options is shown for these.
            isMakingPreview = false
            preview = nil
            estimateFailed = true
        }
    }

    /// "About 3.1 MB · 0:10 · 156 frames" ("1 frame" for one), once there is an estimate.
    var estimateText: String? {
        estimate.map { estimate in
            // The catalog's plural of argument 3 (`%#@frames@`) is chosen by the formatting with the locale.
            String.localizedStringWithFormat(
                String(localized: "About %1$@ · %2$@ · %3$d frames", comment: "The export sheet: the GIF's estimated size, how long it lasts and its frames"),
                ByteCountFormatter.string(fromByteCount: estimate.bytes, countStyle: .file), Timecode.duration(estimate.seconds),
                estimate.frames)
        }
    }

    /// "Between the Marks (0:12.00–0:22.40)", with the marks' times as the transport shows them.
    var marksTitle: String? {
        marked.map { marked in
            func time(_ ns: Int64) -> String { Timecode.precise(Double(ns) / 1e9, total: durationSeconds, locale: .current) }
            return String(
                format: String(localized: "Between the Marks (%1$@–%2$@)", comment: "The export sheet's Range: from the in mark to the out"),
                time(marked.lowerBound), time(marked.upperBound))
        }
    }

    /// What a warning of the estimate says (1c design §7.1).
    static func text(_ warning: GIFWarning) -> String {
        switch warning {
        case .longerThanAMinute:
            String(
                localized: "A GIF longer than a minute is heavy. Mark a range (I and O) or export MP4.",
                comment: "The export sheet: a GIF of more than 60 s")
        case .over10MB:
            String(localized: "Over 10 MB, some sites don't show it.", comment: "The export sheet: a GIF estimated at more than 10 MB")
        case .over50MB:
            String(localized: "A GIF this heavy is better exported as MP4.", comment: "The export sheet: a GIF estimated at more than 50 MB")
        }
    }
}

/// The export sheet over the editor's window (design §5.6, 1c design §7.1), under "Export" and the project's name: Export
/// As (MP4 Video · Animated GIF), the format (shown) and the Range (Whole Video · Between the Marks, only with both marks);
/// for an MP4, 1b's resolution (a segmented control, "Higher than the recording" for the chosen one), frames per second and
/// quality, and its estimated size; for a GIF, the preview with Actual Size beside its options (size, frames per second,
/// quality, dithering, loop forever), the estimate and its warnings, and "GIFs have no sound."; then, beside the estimate,
/// "Export…", which goes on to the save panel. A range shorter than a frame disables it.
struct ExportSheet: View {
    @Bindable var choices: ExportChoices
    let model: EditorModel
    /// Called with `true` for "Export…", `false` for Cancel.
    let finish: (Bool) -> Void

    var body: some View {
        let request = choices.gifRequest
        VStack(alignment: .leading, spacing: 0) {
            header
            switch choices.kind {
            case .mp4:
                // One form: its sections apart by the system's spacing, not two forms' margins.
                Form {
                    whatSection
                    mp4Section
                }
                .formStyle(.grouped)
            case .gif:
                Form { whatSection }
                    .formStyle(.grouped)
                gifOptions
                    .padding(.top, -12)
            }
            footer
        }
        .frame(width: choices.kind == .gif ? 740 : 440)
        .fixedSize(horizontal: false, vertical: true)
        // The preview and the estimate follow the options; the sheet's end stops them (`EditorModel.endExportSheet`), and
        // so does its view going, whichever comes first.
        .onChange(of: request, initial: true) { _, request in choices.optionsChanged(to: request) }
        .onDisappear { choices.stop() }
        .onChange(of: choices.estimateText) { _, text in
            // VoiceOver says the estimate as it changes (1c design §11).
            if let text { AccessibilityNotification.Announcement(text).post() }
        }
    }

    /// "Export", and under it the project's name.
    private var header: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("Export")
                .font(.headline)
            Text(verbatim: model.name)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
        }
        .padding([.top, .horizontal], 20)
    }

    /// What is exported: Export As, the format and the Range (with how to mark a part, while there are no marks).
    private var whatSection: some View {
        Section {
            Picker("Export As", selection: $choices.kind) {
                Text("MP4 Video", comment: "The export sheet: Export As a video").tag(ExportKind.mp4)
                Text("Animated GIF", comment: "The export sheet: Export As a GIF").tag(ExportKind.gif)
            }
            .pickerStyle(.segmented)
            LabeledContent("Format") {
                Text(FormatMenu.title(choices.aspect))
            }
            Picker(selection: Binding(get: { choices.rangeChoice }, set: { choices.chooseRange($0) })) {
                Text("Whole Video", comment: "The export sheet's Range: all of the video").tag(ExportChoices.RangeChoice.whole)
                if let marksTitle = choices.marksTitle {
                    Text(verbatim: marksTitle).tag(ExportChoices.RangeChoice.marks)
                }
            } label: {
                Text("Range")
                if choices.marked == nil {
                    Text("To export a part, mark it with I and O.", comment: "The export sheet: under Range, while the timeline has no marks")
                }
            }
            .disabled(choices.marked == nil)
        }
    }

    /// The MP4's resolution (a segmented control, "Higher than the recording" under its name for the chosen one only),
    /// frames per second and quality.
    private var mp4Section: some View {
        Section {
            Picker(selection: $choices.resolution) {
                ForEach(ExportResolution.allCases, id: \.self) { resolution in
                    Text(verbatim: Self.name(resolution)).tag(resolution)
                }
            } label: {
                Text("Resolution")
                if choices.exceedsRecording(choices.resolution) {
                    Text("Higher than the recording", comment: "The export sheet: beside a resolution above what was recorded of the screen")
                }
            }
            .pickerStyle(.segmented)
            Picker("Frame Rate", selection: $choices.framesPerSecond) {
                ForEach(StyleCommands.frameRates, id: \.self) { fps in
                    Text(fps, format: .number).tag(fps)
                }
            }
            Picker("Quality", selection: $choices.quality) {
                Text("Standard", comment: "The export sheet: the quality of 0.08 bits per pixel").tag(ExportQuality.standard)
                Text("High", comment: "The export sheet: the quality of 0.14 bits per pixel (Spanish: feminine, la calidad)")
                    .tag(ExportQuality.high)
            }
            .pickerStyle(.segmented)
        }
    }

    private var gifOptions: some View {
        HStack(alignment: .top, spacing: 0) {
            // Its top level with the options' section.
            GIFPreviewBox(choices: choices)
                .padding(.leading, 20)
                .padding(.top, 21)
            Form {
                Picker("Size", selection: $choices.gifLongSide) {
                    ForEach(GIFSettings.longSides, id: \.self) { longSide in
                        gifSizeLabel(longSide).tag(longSide)
                    }
                }
                Picker("Frame Rate", selection: $choices.gifFramesPerSecond) {
                    ForEach(GIFSettings.framesPerSecond, id: \.self) { fps in
                        Text(fps, format: .number).tag(fps)
                    }
                }
                Picker("Quality", selection: $choices.gifQuality) {
                    Text(String(localized: "Light (GIF quality)", defaultValue: "Light", comment: "The export sheet: a GIF of up to 128 colours per frame (Spanish: feminine, la calidad)"))
                        .tag(GIFQuality.light)
                    Text("Balanced", comment: "The export sheet: a GIF of up to 256 colours per frame (Spanish: feminine, la calidad)")
                        .tag(GIFQuality.balanced)
                    Text("High", comment: "The export sheet: the quality of 0.14 bits per pixel (Spanish: feminine, la calidad)")
                        .tag(GIFQuality.high)
                }
                .pickerStyle(.segmented)
                Toggle(isOn: $choices.dither) {
                    Text("Dithering", comment: "The export sheet: the GIF's ordered dither")
                }
                Toggle(isOn: $choices.loops) {
                    Text("Loop Forever", comment: "The export sheet: the GIF plays in a loop; otherwise once")
                }
            }
            .formStyle(.grouped)
        }
    }

    /// What there is to say about the export (a range too short, the GIF's warnings, that a GIF has no sound), then one
    /// row: the estimate on the left, Cancel and Export… on the right.
    private var footer: some View {
        VStack(alignment: .leading, spacing: 6) {
            if !choices.lastsAFrame {
                Label {
                    Text("The range has to last at least one frame.", comment: "The export sheet: a range shorter than a frame; Export is disabled")
                } icon: {
                    Image(systemName: "exclamationmark.triangle.fill")
                }
                .foregroundStyle(.red)
            } else if choices.kind == .gif, !choices.estimateFailed {
                ForEach(choices.estimate?.warnings ?? [], id: \.self) { warning in
                    Label(ExportChoices.text(warning), systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.secondary)
                }
            }
            if choices.kind == .gif {
                Label {
                    Text("GIFs have no sound.", comment: "The export sheet: a GIF exports no audio")
                } icon: {
                    Image(systemName: "speaker.slash")
                }
                .foregroundStyle(.secondary)
            }
            HStack(spacing: 12) {
                estimate
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
                    .lineLimit(1)
                Spacer(minLength: 12)
                Button("Cancel", role: .cancel) { finish(false) }
                    .keyboardShortcut(.cancelAction)
                Button("Export…") { finish(true) }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
                    .disabled(!model.canExport || !choices.lastsAFrame)
            }
            .controlSize(.large)
            .padding(.top, 6)
        }
        .fixedSize(horizontal: false, vertical: true)
        .padding([.bottom, .horizontal], 20)
        .padding(.top, 4)
    }

    /// "About 120 MB · 0:12" for an MP4; the GIF's estimate ("Calculating…" until there is one); nothing for a range too
    /// short, or a GIF whose estimate failed.
    @ViewBuilder
    private var estimate: some View {
        if !choices.lastsAFrame {
            EmptyView()
        } else if choices.kind == .mp4 {
            Text("About \(choices.estimatedSize)", comment: "The export sheet: the MP4's estimated size, as “120 MB”")
                + Text(verbatim: " · " + Timecode.duration(choices.rangeSeconds))
        } else if !choices.estimateFailed {
            if let text = choices.estimateText {
                Text(verbatim: text)
            } else {
                Text("Calculating…", comment: "The export sheet: while the GIF's size is being estimated")
            }
        }
    }

    /// "800 × 450", and "Higher than the recording" beside a size above what was recorded: one text, as a menu shows it.
    private func gifSizeLabel(_ longSide: Int) -> Text {
        let size = choices.gifSize(longSide: longSide)
        let name = Text(verbatim: "\(size.x) × \(size.y)")
        guard choices.gifExceedsRecording(longSide: longSide) else { return name }
        return name + Text(verbatim: "  ")
            + Text("Higher than the recording", comment: "The export sheet: beside a resolution above what was recorded of the screen")
            .foregroundStyle(.secondary)
    }

    /// 720p, 1080p, 1440p and 4K, the same in every language.
    static func name(_ resolution: ExportResolution) -> String {
        resolution == .p2160 ? "4K" : "\(resolution.rawValue)p"
    }
}

extension Notification.Name {
    /// The export sheet remembers another resolution or quality: each editor draws its paused preview at the resolution
    /// (plan decision 11).
    static let exportPreferencesChanged = Notification.Name("dev.toma.Toma.exportPreferencesChanged")
}

extension EditorModel {
    /// Export, the bar's button (⌘E) and the keyboard's `EditorCommand.export` (Task 42): the export sheet over the
    /// window. Its "Export…" takes a copy of the document as it is then and goes on to the save panel, with
    /// `<project>.mp4` or `<project>.gif` in the project's folder; what is edited while it exports is not in the file.
    func openExportSheet() {
        guard canExport, let window, window.attachedSheet == nil, let session = panelSession, let project = exportProject else { return }
        let choices = ExportChoices(
            document: session.document, project: project, marks: timelineMarks, playhead: playheadNanoseconds,
            remembered: SettingsStore().settings.export, contentRatio: contentRatio(of: session.document), analysis: analysis)
        let host = NSHostingController(
            rootView: ExportSheet(choices: choices, model: self) { [weak self, weak window] export in
                // The sheet is the window's only one: the save panel comes after it.
                guard let window, let sheet = window.attachedSheet else { return }
                // The document as it is when "Export…" is chosen.
                let document = export ? self?.panelSession?.document : nil
                let job = choices.job, kind = choices.kind, preferences = choices.preferences
                Self.end(sheet, of: window, choices: choices)
                guard let self, let document else { return }
                chooseDestination(of: document, job: job, kind: kind, remembering: preferences)
            })
        // Sized by its content (the hosting controller's standard bounds).
        let sheet = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 440, height: 300), styleMask: [.titled], backing: .buffered, defer: true)
        sheet.isReleasedWhenClosed = false
        sheet.contentViewController = host
        window.beginSheet(sheet)
    }

    /// The analysis changed (`EditorImage`): an export sheet over the window makes its GIF preview and estimate again with
    /// it (`ExportChoices.analysisChanged(_:)`).
    func exportSheetAnalysisChanged() {
        (window?.attachedSheet?.contentViewController as? NSHostingController<ExportSheet>)?.rootView.choices
            .analysisChanged(analysis)
    }

    /// The window closes with the export sheet over it (the library's Move to Trash, quitting): the sheet ends as Cancel
    /// ends it (`end(_:of:choices:)`).
    func endExportSheet() {
        guard let window, let sheet = window.attachedSheet,
            let host = sheet.contentViewController as? NSHostingController<ExportSheet>
        else { return }
        Self.end(sheet, of: window, choices: host.rootView.choices)
    }

    #if DEBUG
    /// `-TomaShowcase export` with `TOMA_SHOWCASE_EXPORT=gif`: the open sheet exports a GIF.
    func showcaseExportSheetGIF() {
        (window?.attachedSheet?.contentViewController as? NSHostingController<ExportSheet>)?.rootView.choices.kind = .gif
    }
    #endif

    /// Ends the export sheet: its GIF preview and estimate stop at once (`ExportChoices.stop()`), and, on the next turn
    /// (out of the button's action that may have called this), its content goes and it closes. `endSheet` alone would keep
    /// the sheet's window, its view, its choices and the project they hold (its package's open folder) for as long as the
    /// app runs.
    private static func end(_ sheet: NSWindow, of window: NSWindow, choices: ExportChoices) {
        choices.stop()
        window.endSheet(sheet)
        Task { @MainActor in
            sheet.contentViewController = nil
            sheet.close()
        }
    }

    /// The save panel, as a sheet, then the export of `document` as `job` says; once it starts, the sheet remembers what
    /// was exported and its options (`ExportPreferences.remembering`).
    private func chooseDestination(
        of document: EditDocument, job: ExportJob, kind: ExportKind, remembering chosen: ExportPreferences
    ) {
        guard canExport, let window, let current = panelSession?.packageURL else { return }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [kind == .gif ? .gif : .mpeg4Movie]
        panel.canCreateDirectories = true
        panel.nameFieldStringValue = current.deletingPathExtension().lastPathComponent + (kind == .gif ? ".gif" : ".mp4")
        panel.directoryURL = current.deletingLastPathComponent()
        Task {
            guard await panel.beginSheetModal(for: window) == .OK, let destination = panel.url,
                startExport(document, job, to: destination)
            else { return }
            Self.remember(kind, chosen: chosen)
        }
    }

    /// Keeps what an export of `kind` with the options `chosen` leaves remembered in the app's settings, and tells every
    /// editor.
    private static func remember(_ kind: ExportKind, chosen: ExportPreferences) {
        let store = SettingsStore()
        var settings = store.settings
        let remembered = settings.export.remembering(kind, chosen: chosen)
        guard settings.export != remembered else { return }
        settings.export = remembered
        store.settings = settings
        NotificationCenter.default.post(name: .exportPreferencesChanged, object: nil)
    }
}
