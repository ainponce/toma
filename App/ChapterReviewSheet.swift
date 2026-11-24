// SPDX-License-Identifier: GPL-3.0-or-later
import Analysis
import AppSupport
import Editing
import LocalAI
import SwiftUI

/// The chapters Apple Intelligence proposed, to review before they enter the document (fases 4 y 5 design §9, plan 5b
/// decisions 11 to 13): while it reads the transcript, which part it is on; then a row per chapter, each with its box
/// (all checked), its time (a click takes the playhead there) and its title, which can be edited; «Add N Chapters» adds
/// the checked ones as markers in one step that undoes (`EditorAI.addChapters`). Without a transcript it offers to
/// transcribe; a video too short, one without words, the model unavailable or failing, each says so.
struct ChapterReviewSheet: View {
    static let size = CGSize(width: 520, height: 460)

    let model: EditorModel
    let ai: EditorAI

    /// The rows proposed, with what was checked; the titles as typed are in `titles` until «Add» (a marker's name is
    /// trimmed, which typing must not be).
    @State private var rules = ChapterReviewRules([])
    @State private var titles: [Int: String] = [:]

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
                .padding([.horizontal, .top], 20)
                .padding(.bottom, 14)
            Divider()
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            Divider()
            footer
                .padding(20)
        }
        .frame(width: Self.size.width, height: Self.size.height)
        .onChange(of: ai.review, initial: true) { _, review in
            guard case .proposed(let suggestions)? = review else { return }
            rules = ChapterReviewRules(suggestions.asChapters)
            titles = Dictionary(uniqueKeysWithValues: rules.rows.map { ($0.id, $0.title) })
        }
    }

    /// `rules` with the titles as typed.
    private var reviewed: ChapterReviewRules {
        var reviewed = rules
        for (id, title) in titles { reviewed.setTitle(title, of: id) }
        return reviewed
    }

    private var hasRows: Bool {
        if case .proposed(let suggestions)? = ai.review { !suggestions.chapters.isEmpty } else { false }
    }

    // MARK: - Header

    private var header: some View {
        HStack(alignment: .center, spacing: 12) {
            Image(systemName: "sparkles")
                .font(.system(size: 17, weight: .medium))
                .foregroundStyle(.tint)
                .frame(width: 36, height: 36)
                .background(Circle().fill(Color.accentColor.opacity(0.16)))
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                (hasRows ? Text("Proposed Chapters") : Text("Propose Chapters"))
                    .font(.title3.weight(.semibold))
                    .accessibilityAddTraits(.isHeader)
                if hasRows {
                    Text("Edit a title, or uncheck a chapter to leave it out.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    // MARK: - Content

    @ViewBuilder
    private var content: some View {
        switch ai.review {
        case .working(let progress)?:
            working(progress)
        case .proposed(let suggestions)?:
            if suggestions.chapters.isEmpty {
                message("No chapters were proposed.", symbol: "text.badge.xmark")
            } else {
                list
            }
        case .noTranscript?:
            message("This project has no transcript.", symbol: "captions.bubble")
        case .tooShort?:
            message("The video is too short for chapters.", symbol: "timer")
        case .noWords?:
            message("Nothing said is left in the video.", symbol: "text.badge.xmark")
        case .unavailable(let reason)?:
            message(verbatim: EditorAI.text(reason), symbol: "sparkles")
        case .failed(let sentence)?:
            message(verbatim: sentence, symbol: "exclamationmark.triangle", warning: true)
        case nil:
            Color.clear
        }
    }

    private func working(_ progress: AIProgress?) -> some View {
        VStack(spacing: 12) {
            if let progress, progress.parts > 1 {
                // Halfway through the part it is on: the bar moves from the first part.
                ProgressView(value: Double(progress.part) - 0.5, total: Double(progress.parts))
                    .frame(width: 280)
                Text("Reading the transcript… part \(progress.part) of \(progress.parts)")
            } else {
                ProgressView()
                    .progressViewStyle(.linear)
                    .frame(width: 280)
                Text("Reading the transcript…")
            }
            Text("Apple Intelligence reads it on this Mac. It can take half a minute.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(32)
        .accessibilityElement(children: .combine)
    }

    private func message(_ text: LocalizedStringKey, symbol: String, warning: Bool = false) -> some View {
        message(Text(text), symbol: symbol, warning: warning)
    }

    private func message(verbatim text: String, symbol: String, warning: Bool = false) -> some View {
        message(Text(verbatim: text), symbol: symbol, warning: warning)
    }

    private func message(_ text: Text, symbol: String, warning: Bool) -> some View {
        VStack(spacing: 12) {
            Image(systemName: symbol)
                .font(.system(size: 28))
                .foregroundStyle(warning ? AnyShapeStyle(.orange) : AnyShapeStyle(.tertiary))
                .accessibilityHidden(true)
            text
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(32)
    }

    private var list: some View {
        ScrollView {
            VStack(spacing: 0) {
                ForEach(Array(rules.rows.enumerated()), id: \.element.id) { position, row in
                    if position > 0 { Divider().padding(.leading, 40) }
                    ChapterReviewRow(
                        row: row, title: title(of: row.id), seek: { ai.seek(toOutput: row.start) },
                        toggle: { rules.toggle(row.id) })
                }
            }
            .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Color.primary.opacity(0.045)))
            .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(Color.primary.opacity(0.08)))
            .padding(20)
        }
        .accessibilityElement(children: .contain)
    }

    private func title(of id: Int) -> Binding<String> {
        Binding(get: { titles[id] ?? "" }, set: { titles[id] = String($0.prefix(MarkerCommands.maximumNameLength)) })
    }

    // MARK: - Footer

    private var footer: some View {
        HStack(spacing: 12) {
            if case .proposed(let suggestions)? = ai.review, suggestions.skippedParts > 0 {
                Label {
                    Text(Self.skipped(suggestions.skippedParts))
                        .fixedSize(horizontal: false, vertical: true)
                } icon: {
                    Image(systemName: "exclamationmark.triangle")
                        .foregroundStyle(.orange)
                }
                .font(.callout)
                .foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
            buttons
        }
        .controlSize(.large)
    }

    @ViewBuilder
    private var buttons: some View {
        switch ai.review {
        case .working?, nil:
            Button("Cancel") { ai.cancelReview() }
                .keyboardShortcut(.cancelAction)
        case .proposed?:
            if hasRows {
                let count = reviewed.count
                Button("Cancel") { ai.cancelReview() }
                    .keyboardShortcut(.cancelAction)
                Button {
                    ai.addChapters(reviewed.chapters)
                } label: {
                    Text(Self.addTitle(count))
                        .frame(minWidth: 96)
                }
                .keyboardShortcut(.defaultAction)
                .disabled(count == 0 || !model.canEdit)
            } else {
                okButton
            }
        case .noTranscript?:
            Button("Cancel") { ai.cancelReview() }
                .keyboardShortcut(.cancelAction)
            Button {
                ai.transcribeFirst()
            } label: {
                Text("Transcribe")
                    .frame(minWidth: 96)
            }
            .keyboardShortcut(.defaultAction)
            .disabled(!model.canEdit)
        case .tooShort?, .noWords?, .unavailable?, .failed?:
            okButton
        }
    }

    /// «Aceptar» closes the sheet with Return, and with Esc too: a button of its own takes Esc, unseen behind it.
    private var okButton: some View {
        Button {
            ai.cancelReview()
        } label: {
            Text("OK")
                .frame(minWidth: 64)
        }
        .keyboardShortcut(.defaultAction)
        .background {
            Button("Cancel") { ai.cancelReview() }
                .keyboardShortcut(.cancelAction)
                .opacity(0)
                .accessibilityHidden(true)
        }
    }

    /// «Agregar 1 capítulo», «Agregar 12 capítulos»; «Agregar capítulos» (dimmed) with none checked.
    static func addTitle(_ count: Int) -> String {
        switch count {
        case 0: String(localized: "Add Chapters")
        case 1: String(localized: "Add 1 Chapter", comment: "The chapters' sheet: the button that adds the one chapter checked")
        default: String(localized: "Add \(count) Chapters", comment: "The chapters' sheet: the button that adds the chapters checked")
        }
    }

    /// The parts of the transcript the model would not read (its guardrails, or too long).
    static func skipped(_ parts: Int) -> String {
        parts == 1
            ? String(localized: "One part couldn't be read.", comment: "The chapters' sheet: a part of the transcript the model declined or couldn't fit")
            : String(localized: "\(parts) parts couldn't be read.", comment: "The chapters' sheet: parts of the transcript the model declined or couldn't fit")
    }
}

/// A chapter of the sheet: its box, its time (a click takes the playhead there) and its title, editable. VoiceOver reads
/// the box as "1:05, Instalar Toma".
private struct ChapterReviewRow: View {
    let row: ChapterReviewRules.Row
    @Binding var title: String
    let seek: () -> Void
    let toggle: () -> Void

    var body: some View {
        let time = Timecode.duration(Double(row.start) / 1e9)
        HStack(spacing: 10) {
            Toggle(isOn: Binding(get: { row.included }, set: { _ in toggle() })) {
                EmptyView()
            }
            .toggleStyle(.checkbox)
            .labelsHidden()
            .accessibilityLabel(Text(verbatim: title.isEmpty ? time : "\(time), \(title)"))
            Button(action: seek) {
                Text(verbatim: time)
                    .monospacedDigit()
                    .frame(minWidth: 40, alignment: .leading)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .foregroundStyle(.tint)
            .help(Text("Go to \(time)"))
            .accessibilityLabel(Text("Go to \(time)"))
            TextField(text: $title, prompt: Text("Chapter Title")) {
                Text("Chapter Title")
            }
            .textFieldStyle(.roundedBorder)
            .opacity(row.included ? 1 : 0.45)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }
}
