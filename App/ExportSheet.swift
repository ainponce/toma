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
/// For a GIF it also makes the preview and the estimate (1c design §7.3), as the sheet asks (`makePreviewAndEstimate`).
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
    /// Where the preview starts if it is inside the range: the playhead, in output nanoseconds.
    @ObservationIgnored private let playhead: Int64
    /// The user chose a Range: changing Export As no longer moves it to the kind's default.
    @ObservationIgnored private var rangeWasChosen = false
    /// Counts the requests, so a request that was replaced never shows what it made.
    @ObservationIgnored private var generation = 0
    /// A preview was asked for already: the next ones wait for the options to settle.
    @ObservationIgnored private var askedBefore = false

    /// How long after the last change the preview and the estimate are made again (1c design §7.3).
    private static let settleDelay = Duration.milliseconds(300)
    private static let logger = Logger(subsystem: "dev.toma.Toma", category: "ExportSheet")

    init(document: EditDocument, project: LoadedProject, marks: TimelineMarks, playhead: Int64, remembered: ExportPreferences) {
        self.document = document
        self.project = project
        self.playhead = playhead
        aspect = document.aspect
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

    /// Whether the range lasts at least a frame of the export, as the exporters check it (`ExportRange.lastsAFrame`):
    /// without it, Export is disabled and the sheet says "The range has to last at least one frame." The sheet's rule in
    /// AppSupport, `ExportRangeRules.canExport`, is the same (tested on every pair of marks on the grid).
    var lastsAFrame: Bool {
        let lasts = exportRange.lastsAFrame(fps: exportFramesPerSecond)
        assert(lasts == ExportRangeRules.canExport(range, fps: exportFramesPerSecond), "the sheet's rule and the exporters' differ")
        return lasts
    }

    /// The MP4 these choices make of the document.
    var settings: ExportSettings {
        ExportSettings(aspect: aspect, resolution: resolution, framesPerSecond: framesPerSecond, quality: quality)
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
        GIFSettings(longSide: longSide, range: exportRange).outputSize(aspect: aspect)
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

    /// Makes the GIF's preview and estimate for `request`, as the sheet's task for it: the first time at once, then
    /// `settleDelay` after the last change (a change cancels the task and asks again, and closing the sheet cancels it).
    /// The preview first, 3 s from the playhead; then the estimate, first from the preview alone and then refined
    /// (`GIFEstimate.estimates`). For `nil`, nothing is shown.
    func makePreviewAndEstimate(for request: GIFRequest?) async {
        generation += 1
        let current = generation
        estimate = nil
        estimateFailed = false
        guard let request else {
            preview = nil
            isMakingPreview = false
            return
        }
        isMakingPreview = true
        let settings = request.settings
        do {
            if askedBefore { try await Task.sleep(for: Self.settleDelay) }
            askedBefore = true
            let data = try await GIFEstimate.preview(project: project, document: document, settings: settings, playhead: playhead)
            guard current == generation, !Task.isCancelled else { return }
            preview = GIFPreviewImage(data, id: current)
            isMakingPreview = false
            for try await result in GIFEstimate.estimates(project: project, document: document, settings: settings, preview: data) {
                guard current == generation, !Task.isCancelled else { return }
                estimate = result
            }
        } catch {
            guard current == generation, !Task.isCancelled, !(error is CancellationError),
                (error as? GIFExportError) != .cancelled
            else { return }
            Self.logger.error("The GIF's preview or estimate failed: \(String(describing: error), privacy: .public)")
            isMakingPreview = false
            estimateFailed = true
        }
    }

    /// "About 3.1 MB · 0:10 · 156 frames", once there is an estimate.
    var estimateText: String? {
        estimate.map { estimate in
            String(
                format: String(localized: "About %1$@ · %2$@ · %3$d frames", comment: "The export sheet: the GIF's estimated size, how long it lasts and its frames"),
                ByteCountFormatter.string(fromByteCount: estimate.bytes, countStyle: .file), Timecode.duration(estimate.seconds),
                Int32(clamping: estimate.frames))
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

/// The preview GIF as `NSImageView` plays it: decoded by ImageIO (`NSImage`), set to loop whatever "Loop Forever" says
/// (the preview plays in a loop, 1c design §7.3), with its size in pixels.
struct GIFPreviewImage {
    /// Which request made it.
    let id: Int
    let image: NSImage
    let pixels: CGSize

    init?(_ data: Data, id: Int) {
        guard let image = NSImage(data: data), let rep = image.representations.first as? NSBitmapImageRep else { return nil }
        rep.setProperty(.loopCount, withValue: 0)
        self.id = id
        self.image = image
        pixels = CGSize(width: rep.pixelsWide, height: rep.pixelsHigh)
    }
}

/// The export sheet over the editor's window (design §5.6, 1c design §7.1): Export As (MP4 Video · Animated GIF), the
/// format (shown) and the Range (Whole Video · Between the Marks, only with both marks); for an MP4, 1b's resolution with
/// "Higher than the recording", frames per second and quality, and its estimated size; for a GIF, the preview with
/// Actual Size beside its options (size, frames per second, quality, dithering, loop forever), the estimate and its
/// warnings, and "GIFs have no sound."; then "Export…", which goes on to the save panel. A range shorter than a frame
/// disables it.
struct ExportSheet: View {
    @Bindable var choices: ExportChoices
    let model: EditorModel
    /// Called with `true` for "Export…", `false` for Cancel.
    let finish: (Bool) -> Void

    var body: some View {
        let request = choices.gifRequest
        VStack(alignment: .leading, spacing: 0) {
            Text("Export")
                .font(.headline)
                .padding([.top, .horizontal], 20)
            Form {
                Picker("Export As", selection: $choices.kind) {
                    Text("MP4 Video", comment: "The export sheet: Export As a video").tag(ExportKind.mp4)
                    Text("Animated GIF", comment: "The export sheet: Export As a GIF").tag(ExportKind.gif)
                }
                .pickerStyle(.segmented)
                LabeledContent("Format") {
                    Text(FormatMenu.title(choices.aspect))
                }
                Picker("Range", selection: Binding(get: { choices.rangeChoice }, set: { choices.chooseRange($0) })) {
                    Text("Whole Video", comment: "The export sheet's Range: all of the video").tag(ExportChoices.RangeChoice.whole)
                    if let marksTitle = choices.marksTitle {
                        Text(verbatim: marksTitle).tag(ExportChoices.RangeChoice.marks)
                    }
                }
                .disabled(choices.marked == nil)
            }
            .formStyle(.grouped)
            switch choices.kind {
            case .mp4: mp4Options
            case .gif: gifOptions
            }
            footer
        }
        .frame(width: choices.kind == .gif ? 740 : 440)
        .fixedSize(horizontal: false, vertical: true)
        .task(id: request) { await choices.makePreviewAndEstimate(for: request) }
        .onChange(of: choices.estimateText) { _, text in
            // VoiceOver says the estimate as it changes (1c design §11).
            if let text { AccessibilityNotification.Announcement(text).post() }
        }
    }

    private var mp4Options: some View {
        Form {
            Picker("Resolution", selection: $choices.resolution) {
                ForEach(ExportResolution.allCases, id: \.self) { resolution in
                    resolutionLabel(resolution).tag(resolution)
                }
            }
            .pickerStyle(.radioGroup)
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
        .formStyle(.grouped)
    }

    private var gifOptions: some View {
        HStack(alignment: .top, spacing: 0) {
            GIFPreviewBox(choices: choices)
                .padding(.leading, 20)
                .padding(.top, 10)
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

    private var footer: some View {
        VStack(alignment: .leading, spacing: 6) {
            if !choices.lastsAFrame {
                Text("The range has to last at least one frame.", comment: "The export sheet: a range shorter than a frame; Export is disabled")
                    .foregroundStyle(.red)
            } else if choices.kind == .mp4 {
                Text("About \(choices.estimatedSize)", comment: "The export sheet: the MP4's estimated size, as “120 MB”")
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            } else if !choices.estimateFailed {
                Group {
                    if let text = choices.estimateText {
                        Text(verbatim: text)
                    } else {
                        Text("Calculating…", comment: "The export sheet: while the GIF's size is being estimated")
                    }
                }
                .foregroundStyle(.secondary)
                .monospacedDigit()
                ForEach(choices.estimate?.warnings ?? [], id: \.self) { warning in
                    Label(ExportChoices.text(warning), systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.secondary)
                }
            }
            if choices.kind == .gif {
                Text("GIFs have no sound.", comment: "The export sheet: a GIF exports no audio")
                    .foregroundStyle(.secondary)
            }
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { finish(false) }
                    .keyboardShortcut(.cancelAction)
                Button("Export…") { finish(true) }
                    .keyboardShortcut(.defaultAction)
                    .disabled(!model.canExport || !choices.lastsAFrame)
            }
            .padding(.top, 6)
        }
        .fixedSize(horizontal: false, vertical: true)
        .padding([.bottom, .horizontal], 20)
    }

    private func resolutionLabel(_ resolution: ExportResolution) -> some View {
        HStack(spacing: 8) {
            Text(verbatim: Self.name(resolution))
            if choices.exceedsRecording(resolution) {
                Text("Higher than the recording", comment: "The export sheet: beside a resolution above what was recorded of the screen")
                    .foregroundStyle(.secondary)
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

/// The GIF's preview (1c design §7.3): the real GIF, in a loop, fitted to 320 × 180 pt; Actual Size shows it 1:1 with
/// the screen's pixels in a view that scrolls (the dither is only judged so). With "Reduce motion" it does not start by
/// itself: the first frame, and a button to play it. "Making the preview…" over it while it is made again. VoiceOver
/// calls it "GIF Preview" and says whether it plays.
private struct GIFPreviewBox: View {
    let choices: ExportChoices
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var actualSize = false
    /// Played or paused with the button; `nil`: as "Reduce motion" says.
    @State private var playing: Bool?

    private var isPlaying: Bool { playing ?? !reduceMotion }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ZStack {
                Rectangle().fill(.quaternary)
                GIFPreviewView(preview: choices.preview, actualSize: actualSize, playing: isPlaying)
                    .opacity(choices.isMakingPreview ? 0.4 : 1)
                if choices.isMakingPreview {
                    Text("Making the preview…", comment: "The export sheet: while the GIF's preview is made")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .transition(.opacity)
                }
            }
            .frame(width: 320, height: 180)
            .clipShape(RoundedRectangle(cornerRadius: 6))
            .animation(.panel(Motion.panelSwap, reduceMotion: reduceMotion), value: choices.isMakingPreview)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(Text("GIF Preview", comment: "VoiceOver: the export sheet's preview of the GIF"))
            .accessibilityValue(
                isPlaying
                    ? Text("Playing", comment: "VoiceOver: the GIF's preview while it plays")
                    : Text("Paused"))
            .accessibilityAddTraits(.isImage)
            HStack(spacing: 8) {
                Toggle(isOn: $actualSize) {
                    Text("Actual Size", comment: "The export sheet: the GIF's preview 1:1 with the screen's pixels")
                }
                .toggleStyle(.button)
                if reduceMotion {
                    Button {
                        playing = !isPlaying
                    } label: {
                        Label(isPlaying ? LocalizedStringKey("Pause") : LocalizedStringKey("Play"), systemImage: isPlaying ? "pause.fill" : "play.fill")
                    }
                }
            }
        }
    }
}

/// The preview in an `NSImageView`, which plays the GIF, inside a scroll view: fitted to it, or 1:1 with the screen's
/// pixels and scrolled to the middle.
private struct GIFPreviewView: NSViewRepresentable {
    let preview: GIFPreviewImage?
    let actualSize: Bool
    let playing: Bool

    final class Coordinator {
        /// The `GIFPreviewImage.id` shown.
        var shown: Int?
        var wasActualSize = false
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> NSScrollView {
        let imageView = NSImageView()
        imageView.imageFrameStyle = .none
        imageView.imageAlignment = .alignCenter
        imageView.isEditable = false
        // The SwiftUI view around it is the accessibility element ("GIF Preview").
        imageView.setAccessibilityElement(false)
        let scroll = NSScrollView()
        scroll.drawsBackground = false
        scroll.borderType = .noBorder
        scroll.autohidesScrollers = true
        scroll.documentView = imageView
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        guard let imageView = scroll.documentView as? NSImageView else { return }
        let coordinator = context.coordinator
        if coordinator.shown != preview?.id {
            coordinator.shown = preview?.id
            imageView.image = preview?.image
        }
        imageView.animates = playing
        if !playing, let rep = preview?.image.representations.first as? NSBitmapImageRep {
            // Paused, the first frame.
            rep.setProperty(.currentFrame, withValue: 0)
            imageView.needsDisplay = true
        }
        let box = scroll.contentSize
        if actualSize, let preview {
            // One pixel of the GIF on one pixel of the screen.
            let scale = scroll.window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 1
            let size = NSSize(width: preview.pixels.width / scale, height: preview.pixels.height / scale)
            preview.image.size = size
            imageView.imageScaling = .scaleNone
            imageView.autoresizingMask = []
            imageView.frame = NSRect(x: 0, y: 0, width: max(size.width, box.width), height: max(size.height, box.height))
            scroll.hasHorizontalScroller = size.width > box.width
            scroll.hasVerticalScroller = size.height > box.height
            if !coordinator.wasActualSize {
                let middle = NSPoint(x: (imageView.frame.width - box.width) / 2, y: (imageView.frame.height - box.height) / 2)
                scroll.contentView.scroll(to: middle)
                scroll.reflectScrolledClipView(scroll.contentView)
            }
        } else {
            imageView.imageScaling = .scaleProportionallyUpOrDown
            imageView.autoresizingMask = [.width, .height]
            imageView.frame = NSRect(origin: .zero, size: box)
            scroll.hasHorizontalScroller = false
            scroll.hasVerticalScroller = false
        }
        coordinator.wasActualSize = actualSize && preview != nil
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
            remembered: SettingsStore().settings.export)
        let host = NSHostingController(
            rootView: ExportSheet(choices: choices, model: self) { [weak self, weak window] export in
                // The sheet is the window's only one: the save panel comes after it.
                guard let window, let sheet = window.attachedSheet else { return }
                // The document as it is when "Export…" is chosen.
                let document = export ? self?.panelSession?.document : nil
                window.endSheet(sheet)
                guard let self, let document else { return }
                chooseDestination(of: document, job: choices.job, kind: choices.kind, remembering: choices.preferences)
            })
        // Sized by its content (the hosting controller's standard bounds).
        let sheet = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 440, height: 300), styleMask: [.titled], backing: .buffered, defer: true)
        sheet.isReleasedWhenClosed = false
        sheet.contentViewController = host
        window.beginSheet(sheet)
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
