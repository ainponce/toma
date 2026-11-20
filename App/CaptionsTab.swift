// SPDX-License-Identifier: GPL-3.0-or-later
import AppKit
import Analysis
import AppSupport
import Editing
import Foundation
import ProjectFormat
import SwiftUI
import Transcription

/// The panel's Captions tab ("Subtítulos", phase 2 design §5.1 to §5.4): without a transcript, what transcribing needs
/// (the language, its model, the Transcribe button and its progress, or why this Mac cannot); with one, the Text (the
/// words to edit the video by, `TranscriptTextView`, with Remove Filler Words and Shorten Pauses) above the Style
/// (`CaptionStyleSection`). The text fills the height of the panel the rest leaves it.
struct CaptionsTab: View {
    let model: EditorModel

    @State private var cache = TranscriptTextCache()

    var body: some View {
        if let document = model.document {
            if document.transcript == nil || CaptionsShowcase.forcesEmpty {
                CaptionsEmptyState(model: model, voice: model.voice)
            } else {
                CaptionsTranscript(model: model, document: document, cache: cache)
            }
        }
    }
}

// MARK: - Without a transcript

/// What transcribing needs (design §5.1 and §5.3): on macOS 15, "Transcription needs macOS 26."; on a Mac that cannot,
/// or a take without sound, why; otherwise the language (those on this Mac first), its model (Download Language, with
/// its progress) and Transcribe, which shows its progress with Cancel.
private struct CaptionsEmptyState: View {
    let model: EditorModel
    let voice: EditorVoice

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: "captions.bubble")
                    .font(.system(size: 22))
                    .foregroundStyle(.tint)
                    .accessibilityHidden(true)
                Text("Transcribe the audio to edit the video through its text and to show captions.")
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            switch transcription {
            case .needsMacOS26:
                CaptionsNote("Transcription needs macOS 26.")
            case .unavailable:
                CaptionsNote("This Mac can't transcribe.")
            case .noAudio:
                CaptionsNote("This recording has no audio.")
            case .queued:
                TranscribingRow(progress: 0, count: count) { voice.cancelTranscription() }
            case .running(let progress):
                TranscribingRow(progress: progress, count: count) { voice.cancelTranscription() }
            case .idle, .failed, .done:
                LanguageChoice(voice: voice)
                modelRow
                if case .failed(let reason) = transcription {
                    CaptionsNote(verbatim: reason, warning: true)
                }
            }
        }
        .animation(.panel(Motion.panelSwap, reduceMotion: reduceMotion), value: transcription)
        #if DEBUG
        .task { CaptionsShowcase.snapshotLater(model.window) }
        #endif
    }

    private var transcription: EditorVoice.Transcription {
        CaptionsShowcase.transcription ?? voice.transcription
    }

    private var count: EditorVoice.TakeCount? {
        CaptionsShowcase.count ?? voice.transcriptionCount
    }

    private var modelStatus: LanguageModelStatus {
        CaptionsShowcase.modelStatus ?? voice.modelStatus
    }

    @ViewBuilder
    private var modelRow: some View {
        switch modelStatus {
        case .installed, .unsupported:
            Button {
                voice.transcribe()
            } label: {
                Text("Transcribe")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .disabled(modelStatus != .installed || !model.canEdit)
        case .downloadable:
            VStack(alignment: .leading, spacing: 8) {
                Text("This language isn't on this Mac yet. It's downloaded once, from Apple.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Button {
                    voice.downloadLanguage()
                } label: {
                    Text("Download Language")
                        .frame(maxWidth: .infinity)
                }
                .controlSize(.large)
            }
        case .downloading:
            let progress = CaptionsShowcase.downloadProgress ?? voice.downloadProgress ?? 0
            ProgressLine(
                text: String(
                    format: String(localized: "Downloading the language… %lld %%", comment: "The Captions tab: a language's model downloading"),
                    Self.percent(progress)),
                progress: progress)
        }
    }

    static func percent(_ fraction: Double) -> Int {
        Int((min(max(fraction, 0), 1) * 100).rounded(.down))
    }
}

/// The language the next transcription is in, those whose model is on this Mac first.
private struct LanguageChoice: View {
    let voice: EditorVoice

    var body: some View {
        if voice.languages.isEmpty {
            ProgressView()
                .controlSize(.small)
        } else {
            Picker("Language", selection: Binding(get: { voice.language }, set: { voice.language = $0 })) {
                Self.options(voice.languages)
            }
            .panelTitled("Language")
        }
    }

    /// The languages as a picker's choices: those whose model is on this Mac, then those to download.
    @ViewBuilder
    static func options(_ languages: [EditorVoice.Language]) -> some View {
        let installed = languages.filter(\.installed)
        let others = languages.filter { !$0.installed }
        if !installed.isEmpty {
            Section("On This Mac") {
                ForEach(installed) { Text(verbatim: $0.name).tag($0.id) }
            }
        }
        if !others.isEmpty {
            Section("To Download") {
                ForEach(others) { Text(verbatim: $0.name).tag($0.id) }
            }
        }
    }
}

/// "Transcribing… 42 %" with its bar and Cancel; with several takes, "Transcribing 2 of 3…", the bar over all of them.
private struct TranscribingRow: View {
    /// Of the take it is on.
    let progress: Double
    /// Which take it is on, with more than one.
    let count: EditorVoice.TakeCount?
    let cancel: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline) {
                Text(verbatim: text)
                    .monospacedDigit()
                Spacer(minLength: 8)
                Button("Cancel", action: cancel)
                    .controlSize(.small)
            }
            ProgressView(value: overall)
                .progressViewStyle(.linear)
                .controlSize(.small)
        }
        .accessibilityElement(children: .contain)
    }

    private var text: String {
        if let count {
            String(
                format: String(
                    localized: "Transcribing %lld of %lld…",
                    comment: "The Captions tab: the transcription of several takes under way, which of them it is on"),
                count.take, count.of)
        } else {
            String(
                format: String(localized: "Transcribing… %lld %%", comment: "The Captions tab: the transcription under way"),
                CaptionsEmptyState.percent(progress))
        }
    }

    /// From 0 to 1, over every take being transcribed.
    private var overall: Double {
        let progress = min(max(progress, 0), 1)
        guard let count, count.of > 0 else { return progress }
        return min(max((Double(count.take - 1) + progress) / Double(count.of), 0), 1)
    }
}

/// A line with its bar.
private struct ProgressLine: View {
    let text: String
    let progress: Double

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(verbatim: text)
                .monospacedDigit()
            ProgressView(value: min(max(progress, 0), 1))
                .progressViewStyle(.linear)
                .controlSize(.small)
        }
        .accessibilityElement(children: .combine)
    }
}

/// A sentence of the tab that says why something is not there.
private struct CaptionsNote: View {
    private let text: Text
    private let warning: Bool

    init(_ key: LocalizedStringKey) {
        text = Text(key)
        warning = false
    }

    init(verbatim: String, warning: Bool) {
        text = Text(verbatim: verbatim)
        self.warning = warning
    }

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Image(systemName: warning ? "exclamationmark.triangle.fill" : "info.circle")
                .foregroundStyle(warning ? AnyShapeStyle(.orange) : AnyShapeStyle(.secondary))
                .accessibilityHidden(true)
            text
                .foregroundStyle(warning ? .primary : .secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .accessibilityElement(children: .combine)
    }
}

// MARK: - With a transcript

/// The Text and the Style (design §5.3 and §5.4).
private struct CaptionsTranscript: View {
    let model: EditorModel
    let document: EditDocument
    let cache: TranscriptTextCache

    @State private var selection: ClosedRange<Int>?
    @State private var request: TranscriptTextRequest?
    @State private var hovered: Hovered?
    @State private var threshold = TranscriptionPreferencesStore().preferences.pauseThreshold
    /// Why the last edit could not be made, for a few seconds.
    @State private var notice: LocalizedStringKey?
    @State private var noticeTask: Task<Void, Never>?
    /// The height of the panel's visible part (its scroll view's, from AppKit), and of what is not the text.
    @State private var viewport: CGFloat = 0
    @State private var chrome: CGFloat = 0
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private enum Hovered {
        case fillers, pauses
    }

    /// The text is never shorter than this; the panel scrolls if the rest needs more.
    private static let minimumTextHeight: CGFloat = 180
    /// The panel's padding, above and below.
    private static let panelPadding: CGFloat = 32

    private var voice: EditorVoice { model.voice }

    private var textHeight: CGFloat {
        guard viewport > 0 else { return 320 }
        return max(Self.minimumTextHeight, (viewport - Self.panelPadding - chrome).rounded(.down))
    }

    var body: some View {
        let derived = cache.derived(for: document, threshold: threshold)
        let text = derived.text
        let height = textHeight
        VStack(alignment: .leading, spacing: 10) {
            header
            if text.words.isEmpty {
                CaptionsNote("No words were heard.")
                    .frame(maxWidth: .infinity, minHeight: height, alignment: .topLeading)
            } else {
                TranscriptBox(
                    model: model, text: text, kept: derived.kept, marks: marks(derived), selection: $selection,
                    request: $request, actions: actions(text)
                ) { visible in
                    if abs(visible - viewport) > 0.5 { viewport = visible }
                }
                .frame(height: height)
                selectionRow(text)
                cleanup(derived)
            }
            Divider()
            CaptionStyleSection(model: model, captions: document.captions)
        }
        .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { total in
            let rest = max(total - height, 0)
            if abs(rest - chrome) > 0.5 { chrome = rest }
        }
        .onChange(of: text.words.count) { _, _ in selection = nil }
        .onChange(of: threshold) { _, new in
            let store = TranscriptionPreferencesStore()
            var preferences = store.preferences
            preferences.pauseThreshold = new
            store.preferences = preferences
        }
        .onChange(of: voice.revealed, initial: true) { _, ref in
            guard let ref, let word = text.index(of: ref) else { return }
            request = .reveal(word)
            voice.revealed = nil
        }
        .task { showcase(text) }
    }

    // MARK: The header

    private var header: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 6) {
                Text("Text")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .accessibilityAddTraits(.isHeader)
                Spacer()
                Menu {
                    Button("Transcribe Again") { voice.transcribe() }
                        .disabled(!canTranscribeAgain)
                    if !voice.languages.isEmpty {
                        Picker("Language", selection: Binding(get: { voice.language }, set: { voice.language = $0 })) {
                            LanguageChoice.options(voice.languages)
                        }
                    }
                    if voice.modelStatus == .downloadable {
                        Button("Download Language") { voice.downloadLanguage() }
                    }
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
                .help(Text("Transcript Options"))
                .accessibilityLabel(Text("Transcript Options"))
            }
            switch CaptionsShowcase.transcription ?? voice.transcription {
            case .queued:
                TranscribingRow(progress: 0, count: CaptionsShowcase.count ?? voice.transcriptionCount) { voice.cancelTranscription() }
            case .running(let progress):
                TranscribingRow(progress: progress, count: CaptionsShowcase.count ?? voice.transcriptionCount) {
                    voice.cancelTranscription()
                }
            case .failed(let reason):
                CaptionsNote(verbatim: reason, warning: true)
            default:
                if voice.modelStatus == .downloading {
                    ProgressLine(
                        text: String(
                            format: String(localized: "Downloading the language… %lld %%"),
                            CaptionsEmptyState.percent(voice.downloadProgress ?? 0)),
                        progress: voice.downloadProgress ?? 0)
                }
            }
        }
    }

    private var canTranscribeAgain: Bool {
        guard model.canEdit, voice.modelStatus == .installed else { return false }
        switch voice.transcription {
        case .idle, .done, .failed: return true
        case .queued, .running, .needsMacOS26, .unavailable, .noAudio: return false
        }
    }

    // MARK: Under the text

    /// With words selected, Cut and Restore; without, how to cut, or why the last edit could not be made.
    @ViewBuilder
    private func selectionRow(_ text: TranscriptText) -> some View {
        HStack(spacing: 8) {
            if let notice {
                Text(notice)
                    .font(.caption)
                    .foregroundStyle(.orange)
            } else if let selection, text.words.indices.contains(selection.upperBound) {
                if text.hasKept(selection) {
                    Button("Cut") { cut(selection, in: text) }
                        .controlSize(.small)
                }
                if text.hasCut(selection) {
                    Button("Restore") { model.restoreWords(selection, in: text) }
                        .controlSize(.small)
                }
            } else {
                Text("⌫ cuts the selected words from the video.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.9)
            }
            Spacer(minLength: 0)
        }
        .frame(minHeight: 22)
        .disabled(!model.canEdit)
    }

    /// Remove Filler Words and Shorten Pauses, each one step; with the pointer over one, what it takes out is marked in
    /// the text.
    private func cleanup(_ derived: TranscriptTextCache.Derived) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Button {
                show(model.removeFillerWords())
            } label: {
                Text("Remove Filler Words (\(derived.fillers.count))")
                    .frame(maxWidth: .infinity)
            }
            .disabled(derived.fillers.isEmpty)
            .onHover { hovered = $0 ? .fillers : (hovered == .fillers ? nil : hovered) }
            HStack(spacing: 6) {
                Button {
                    show(model.shortenPauses(threshold: threshold))
                } label: {
                    Text("Shorten Pauses (\(derived.pauses.count))")
                        .frame(maxWidth: .infinity)
                }
                .disabled(derived.pauses.isEmpty)
                .onHover { hovered = $0 ? .pauses : (hovered == .pauses ? nil : hovered) }
                // Which pauses: "> 1 s", with "Longer Than" 0.5, 1 or 2 s in its menu.
                Menu {
                    Picker("Longer Than", selection: $threshold) {
                        ForEach(TranscriptCommands.pauseThresholds, id: \.self) { value in
                            Text(verbatim: Self.seconds(value)).tag(value)
                        }
                    }
                    .pickerStyle(.inline)
                } label: {
                    Text(verbatim: "> " + Self.seconds(threshold))
                        .monospacedDigit()
                }
                .fixedSize()
                .help(Text("Longer Than"))
                .accessibilityLabel(Text("Longer Than"))
                .accessibilityValue(Text(verbatim: Self.seconds(threshold)))
            }
        }
        .disabled(!model.canEdit)
    }

    private static func seconds(_ nanoseconds: Int64) -> String {
        (Double(nanoseconds) / 1e9).formatted(.number.precision(.fractionLength(0...1))) + " s"
    }

    private func marks(_ derived: TranscriptTextCache.Derived) -> TranscriptMarks {
        #if DEBUG
        switch CaptionsShowcase.variant {
        case "fillers": return .fillers(derived.fillerWords)
        case "pauses": return .pauses(derived.pauseWords)
        default: break
        }
        #endif
        switch hovered {
        case .fillers?: return .fillers(derived.fillerWords)
        case .pauses?: return .pauses(derived.pauseWords)
        case nil: return .none
        }
    }

    // MARK: The commands

    private func actions(_ text: TranscriptText) -> TranscriptTextActions {
        TranscriptTextActions(
            seek: { word in model.seekToWord(text.words[word].ref) },
            cut: { words in cut(words, in: text) },
            restore: { words in model.restoreWords(words, in: text) },
            correct: { word, corrected in model.correctWord(text.words[word].ref, corrected) },
            toggleBreak: { word in model.toggleCaptionBreak(text.words[word].ref) },
            playPause: { if model.canPlay { model.togglePlay() } })
    }

    private func cut(_ words: ClosedRange<Int>, in text: TranscriptText) {
        show(model.cutWords(words, in: text))
    }

    /// Says why an edit could not be made, under the text, for a few seconds.
    private func show(_ outcome: EditorModel.TextEdit) {
        switch outcome {
        case .done: return
        case .nothing: NSSound.beep()
        case .lastClip:
            NSSound.beep()
            noticeTask?.cancel()
            withAnimation(.panel(Motion.hover, reduceMotion: reduceMotion)) { notice = "There has to be at least one clip." }
            noticeTask = Task {
                try? await Task.sleep(for: .seconds(4))
                guard !Task.isCancelled else { return }
                withAnimation(.panel(Motion.hover, reduceMotion: reduceMotion)) { notice = nil }
            }
        }
    }

    // MARK: Screenshots

    private func showcase(_ text: TranscriptText) {
        #if DEBUG
        guard let variant = CaptionsShowcase.variant, !CaptionsShowcase.done, text.words.count > 24 else { return }
        CaptionsShowcase.done = true
        switch variant {
        case "cuts", "style":
            // Three words cut, the filler of the first sentences cut, and three words selected with the playhead after.
            _ = model.cutWords(4...6, in: text)
            if let filler = model.document.flatMap({ TranscriptCommands.fillers(in: $0).first }), let word = text.index(of: filler) {
                _ = model.cutWords(word...word, in: text)
            }
            if let document = model.document, let step = TranscriptCommands.toggleBreak(document, text.words[16].ref) {
                model.perform(step)
            }
            selection = 9...11
            model.seekToWord(text.words[14].ref)
        case "correct":
            model.seekToWord(text.words[2].ref)
            request = .edit(7)
        case "playing":
            // At 2×, without sound: the word being said moves and the text follows it.
            model.seekToWord(text.words[0].ref)
            model.shuttle(2)
        default:
            model.seekToWord(text.words[2].ref)
        }
        CaptionsShowcase.snapshotLater(model.window)
        #endif
    }
}

/// The text, the box it is in and the word being said, read from the playhead ten times a second while playing: only
/// this view follows the clock.
private struct TranscriptBox: View {
    let model: EditorModel
    let text: TranscriptText
    let kept: [KeptWord]
    let marks: TranscriptMarks
    @Binding var selection: ClosedRange<Int>?
    @Binding var request: TranscriptTextRequest?
    let actions: TranscriptTextActions
    /// The height of the panel's visible part, as it changes.
    let panelHeight: (CGFloat) -> Void

    var body: some View {
        let output = Int64((model.currentSeconds * 1e9).rounded())
        let playing = TranscriptText.playingWord(atOutput: output, in: kept).flatMap(text.index(of:))
        let shape = RoundedRectangle(cornerRadius: 8, style: .continuous)
        TranscriptTextView(
            text: text, playing: playing, isPlaying: model.isPlaying, marks: marks, canEdit: model.canEdit,
            selection: $selection, request: $request, actions: actions, panelHeight: panelHeight
        )
        .background(shape.fill(Color.primary.opacity(0.035)))
        .clipShape(shape)
        .overlay(shape.strokeBorder(Color.primary.opacity(0.1)))
    }
}

// MARK: - What the text is made of

/// The text of the document's transcript and what the tab derives from it, made again only when the transcript or the
/// clips change (the pauses also with their threshold): a change of the style, a play, a hover make nothing again.
@MainActor
final class TranscriptTextCache {
    struct Derived {
        var text: TranscriptText
        /// The words not cut, in output order, for the word being said.
        var kept: [KeptWord]
        /// The fillers not cut, and their words in the text.
        var fillers: [TranscriptWordRef]
        var fillerWords: [Int]
        /// The pauses as long as the threshold, and the words they are after in the text.
        var pauses: [SourceRange]
        var pauseWords: [Int]
    }

    private var transcript: Transcript?
    private var sequence: [Clip] = []
    private var threshold: Int64 = -1
    private var made: Derived?

    func derived(for document: EditDocument, threshold: Int64) -> Derived {
        if var made, document.transcript == transcript, document.sequence == sequence {
            guard threshold != self.threshold else { return made }
            made.pauses = TranscriptCommands.pauses(in: document, threshold: threshold)
            made.pauseWords = made.text.wordsBefore(pauses: made.pauses, in: document)
            self.threshold = threshold
            self.made = made
            return made
        }
        let text = TranscriptText(document: document)
        let fillers = TranscriptCommands.fillers(in: document)
        let pauses = TranscriptCommands.pauses(in: document, threshold: threshold)
        let derived = Derived(
            text: text, kept: TranscriptTiming.keptWords(of: document, timeMap: TimeMap(sequence: document.sequence)),
            fillers: fillers, fillerWords: fillers.compactMap(text.index(of:)), pauses: pauses,
            pauseWords: text.wordsBefore(pauses: pauses, in: document))
        transcript = document.transcript
        sequence = document.sequence
        self.threshold = threshold
        made = derived
        return derived
    }
}

// MARK: - The commands of the text

extension EditorModel {
    /// What an edit of the text did.
    enum TextEdit {
        case done
        /// Nothing to do: the words are cut already, there are none, or the project cannot be edited now.
        case nothing
        /// It would leave no clip ("There has to be at least one clip.").
        case lastClip
    }

    /// ⌫: the words `words` of `text` cut out of the video (`transcript.cut`), a step for each take they are of.
    func cutWords(_ words: ClosedRange<Int>, in text: TranscriptText) -> TextEdit {
        guard canEdit, !isGesturing else { return .nothing }
        var outcome = TextEdit.nothing
        for run in text.takeRuns(words) {
            guard let document,
                let result = TranscriptCommands.cut(
                    document, take: run.take, words: run.words, takeBounds: takeBounds, makeID: Self.newID)
            else { continue }
            switch result {
            case .success(let step):
                if perform(step) != .refused { outcome = .done }
            case .failure(.lastClip):
                if outcome == .nothing { outcome = .lastClip }
            }
        }
        return outcome
    }

    /// Restore: the cut words among `words` of `text` given back (`transcript.restore`), a step for each take they are
    /// of, each within the editable timeline of its own take (plan 3d decision 17). Those of the session's take at once;
    /// another take's timeline is found off the main thread (its events are read the first time), and its words given
    /// back if the document is still the one they were asked on.
    func restoreWords(_ words: ClosedRange<Int>, in text: TranscriptText) {
        guard canEdit, !isGesturing, let project = overlayProject, let document, let transcript = document.transcript else {
            return
        }
        let runs = text.takeRuns(words)
        let takes = Set(runs.compactMap { transcript.takes.indices.contains($0.take) ? transcript.takes[$0.take].take : nil })
        guard takes.contains(where: { $0 != project.take.id }) else {
            return restore(runs, bounds: Self.editableBounds(of: [project]))
        }
        Task {
            let bounds = await Task.detached(priority: .userInitiated) {
                Self.editableBounds(of: takes.compactMap { project.focused(on: $0) })
            }.value
            guard self.document == document else { return }
            restore(runs, bounds: bounds)
        }
    }

    /// The editable timeline of each of `takes` (`TakeTimeline.editableBounds`), by its id; reads the events of a take
    /// that has not read them yet.
    private nonisolated static func editableBounds(of takes: [LoadedProject]) -> [String: ClosedRange<HostTime>] {
        var bounds: [String: ClosedRange<HostTime>] = [:]
        for take in takes {
            let editable = TakeTimeline.editableBounds(take: take.take, events: take.events)
            if editable.start <= editable.end { bounds[take.take.id] = editable.start...editable.end }
        }
        return bounds
    }

    /// The cut words of `runs` given back, a step for each, each within the timeline of its take in `bounds` (a take
    /// without one is left as it is).
    private func restore(_ runs: [TranscriptText.TakeRun], bounds: [String: ClosedRange<HostTime>]) {
        guard canEdit, !isGesturing else { return }
        for run in runs {
            guard let document, let takes = document.transcript?.takes, takes.indices.contains(run.take),
                let editable = bounds[takes[run.take].take],
                let step = TranscriptCommands.restore(document, take: run.take, words: run.words, bounds: editable, makeID: Self.newID)
            else { continue }
            perform(step)
        }
    }

    /// The word `ref` corrected to `text` (`transcript.word`): the captions change, the sound does not.
    func correctWord(_ ref: TranscriptWordRef, _ text: String) {
        guard canEdit, !isGesturing, let document, let step = TranscriptCommands.correct(document, ref, text: text) else { return }
        perform(step)
    }

    /// Start a Caption Here, on or off (`transcript.break`).
    func toggleCaptionBreak(_ ref: TranscriptWordRef) {
        guard canEdit, !isGesturing, let document, let step = TranscriptCommands.toggleBreak(document, ref) else { return }
        perform(step)
    }

    /// The playhead on the first frame that shows the word `ref`; for a cut word, the first kept after it, or the end.
    func seekToWord(_ ref: TranscriptWordRef) {
        guard let document else { return }
        let map = TimeMap(sequence: document.sequence)
        guard let output = TranscriptText.seekOutput(of: ref, in: document, timeMap: map) else { return seekToEnd() }
        let rate = document.frameRate
        seek(frame: TranscriptText.firstFrame(atOrAfter: output, frameRate: rate, frameCount: map.frameCount(frameRate: rate)))
    }

    /// Remove Filler Words (`transcript.fillers`), in one step.
    func removeFillerWords() -> TextEdit {
        guard canEdit, !isGesturing, let document,
            let result = TranscriptCommands.removeFillers(document, takeBounds: takeBounds, makeID: Self.newID)
        else { return .nothing }
        return outcome(of: result)
    }

    /// Shorten Pauses longer than `threshold` (`transcript.pauses`), in one step.
    func shortenPauses(threshold: Int64) -> TextEdit {
        guard canEdit, !isGesturing, let document,
            let result = TranscriptCommands.shortenPauses(document, threshold: threshold, takeBounds: takeBounds, makeID: Self.newID)
        else { return .nothing }
        return outcome(of: result)
    }

    private func outcome(of result: Result<EditStep, SequenceError>) -> TextEdit {
        switch result {
        case .success(let step): perform(step) != .refused ? .done : .nothing
        case .failure(.lastClip): .lastClip
        }
    }
}

// MARK: - Screenshots

/// `TOMA_SHOWCASE_CAPTIONS=<variant>` (Debug, with `TOMA_SHOWCASE_TAB=6`), for screenshots of the tab: `empty`,
/// `download`, `downloading`, `transcribing`, `queued`, `failed`, `macos15`, `unavailable` and `noaudio` show the tab
/// without a transcript in that state (`takes`: transcribing the second of three takes); `cuts` cuts three words and a
/// filler, starts a caption and selects three words; `style` does that with the Style open; `fillers` and `pauses` mark
/// them as their buttons do; `correct` edits a word; `playing` plays at 2× without sound from the first word.
@MainActor
enum CaptionsShowcase {
    #if DEBUG
    static let variant = ProcessInfo.processInfo.environment["TOMA_SHOWCASE_CAPTIONS"]
    static var done = false
    #else
    static let variant: String? = nil
    #endif

    static var forcesEmpty: Bool {
        ["empty", "download", "downloading", "transcribing", "queued", "failed", "macos15", "unavailable", "noaudio", "takes"]
            .contains(variant ?? "")
    }

    static var transcription: EditorVoice.Transcription? {
        switch variant {
        case "empty"?, "download"?, "downloading"?: .idle
        case "transcribing"?, "takes"?: .running(0.42)
        case "queued"?: .queued
        case "failed"?:
            .failed(String(format: String(localized: "Couldn't transcribe: %@"), String(localized: "its audio can't be read")))
        case "macos15"?: .needsMacOS26
        case "unavailable"?: .unavailable
        case "noaudio"?: .noAudio
        default: nil
        }
    }

    static var modelStatus: LanguageModelStatus? {
        switch variant {
        case "empty"?: .installed
        case "download"?: .downloadable
        case "downloading"?: .downloading
        default: nil
        }
    }

    static var count: EditorVoice.TakeCount? {
        variant == "takes" ? EditorVoice.TakeCount(take: 2, of: 3) : nil
    }

    static var downloadProgress: Double? {
        variant == "downloading" ? 0.37 : nil
    }

    #if DEBUG
    /// `TOMA_SHOWCASE_PANEL_PNG=<path>`: two seconds later, the window's content, the panel and the panel's whole content
    /// drawn into `<path>-window.png`, `<path>-panel.png` and `<path>-panel-whole.png` by the views themselves, without the window server (which captures nothing while the screen
    /// is locked). The preview's Metal layer is not drawn.
    static func snapshotLater(_ window: NSWindow?) {
        guard let path = ProcessInfo.processInfo.environment["TOMA_SHOWCASE_PANEL_PNG"], !snapshotting else { return }
        snapshotting = true
        Task { @MainActor [weak window] in
            try? await Task.sleep(for: .seconds(2))
            guard let content = window?.contentView else { return }
            func inspector(_ view: NSView) -> NSView? {
                view.identifier?.rawValue == "inspector" ? view : view.subviews.lazy.compactMap(inspector).first
            }
            func scrolled(_ view: NSView) -> NSView? {
                (view as? NSScrollView)?.documentView ?? view.subviews.lazy.compactMap(scrolled).first
            }
            let panel = inspector(content)
            for (view, name) in [(content, "window"), (panel, "panel"), (panel.flatMap(scrolled), "panel-whole")] {
                guard let view, let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds),
                    let context = NSGraphicsContext(bitmapImageRep: rep)
                else { continue }
                // Over the window's background, which the views leave to the window server.
                NSGraphicsContext.saveGraphicsState()
                NSGraphicsContext.current = context
                view.effectiveAppearance.performAsCurrentDrawingAppearance {
                    NSColor.windowBackgroundColor.setFill()
                    view.bounds.fill()
                }
                NSGraphicsContext.restoreGraphicsState()
                view.effectiveAppearance.performAsCurrentDrawingAppearance {
                    view.displayIgnoringOpacity(view.bounds, in: context)
                }
                try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: "\(path)-\(name).png"))
            }
        }
    }

    private static var snapshotting = false
    #endif
}
