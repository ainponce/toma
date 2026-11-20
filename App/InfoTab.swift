// SPDX-License-Identifier: GPL-3.0-or-later
import AppSupport
import LocalAI
import ProjectFormat
import SwiftUI

/// The panel's Info tab («Información», fases 4 y 5 design §9, plan 5b decision 11): the project's Title and Summary
/// (`EditDocument.info`), each with «Suggest», which writes Apple Intelligence's in one step that undoes; under them,
/// why the AI can't (dimmed) or, without a transcript, «Transcribe»; then «Propose Chapters…» and «Copy Description
/// for YouTube». The title is saved on Return or as its field loses the focus; the summary as it loses the focus. A field
/// follows the document (an undo, a suggestion) while it doesn't have the focus.
struct InfoTab: View {
    let model: EditorModel
    let ai: EditorAI
    let voice: EditorVoice

    @State private var title = ""
    @State private var summary = ""
    @FocusState private var focus: EditorAI.Field?

    /// The summary's height: five lines of the body's font (16.5 pt each, measured) and the padding around them, so
    /// no sixth line peeks in.
    private static let summaryHeight: CGFloat = 5 * 16.5 + 9

    var body: some View {
        let info = model.document?.info
        VStack(alignment: .leading, spacing: 20) {
            PanelSection("Info") {
                VStack(alignment: .leading, spacing: 14) {
                    titleField
                    summaryField
                    status
                }
            }
            Divider()
            PanelSection("Chapters") {
                Button {
                    commit()
                    ai.proposeChapters()
                } label: {
                    Label("Propose Chapters…", systemImage: "sparkles")
                        .frame(maxWidth: .infinity)
                }
                .controlSize(.large)
                .disabled(!ai.canPropose)
                caption("Apple Intelligence proposes them from the transcript, to review before they are added.")
            }
            // The button's own name is short, to fit the panel's 260 pt in Spanish; VoiceOver reads the menu's whole name.
            PanelSection("YouTube") {
                Button {
                    commit()
                    ai.copyYouTubeDescription()
                } label: {
                    Label("Copy Description", systemImage: "doc.on.clipboard")
                        .frame(maxWidth: .infinity)
                }
                .controlSize(.large)
                .disabled(!ai.canCopyYouTubeDescription)
                .accessibilityLabel(Text("Copy Description for YouTube"))
                caption("The summary and the chapters, ready to paste in YouTube.")
            }
        }
        .onAppear {
            ai.refreshAvailability()
            title = info?.title ?? ""
            summary = info?.summary ?? ""
        }
        .onDisappear { commit() }
        .onChange(of: info) { _, info in
            if focus != .title { title = info?.title ?? "" }
            if focus != .summary { summary = info?.summary ?? "" }
        }
        // What «Suggest» wrote shows even in the field with the focus (its text was saved as «Suggest» was pressed).
        .onChange(of: ai.work) { old, new in
            guard new == .idle else { return }
            if old == .title { title = model.document?.info?.title ?? "" }
            if old == .summary { summary = model.document?.info?.summary ?? "" }
        }
        .onChange(of: model.document?.transcript?.language) { ai.refreshAvailability() }
        .onChange(of: focus) { old, new in
            if old == .title, new != .title { ai.setTitle(title) }
            if old == .summary, new != .summary { ai.setSummary(summary) }
        }
        .onChange(of: title) { _, text in
            if text.count > ProjectInfo.titleLimit { title = String(text.prefix(ProjectInfo.titleLimit)) }
        }
        .onChange(of: summary) { _, text in
            if text.count > ProjectInfo.summaryLimit { summary = String(text.prefix(ProjectInfo.summaryLimit)) }
        }
        #if DEBUG
        .task { CaptionsShowcase.snapshotLater(model.window) }
        #endif
    }

    // MARK: - The fields

    private var titleField: some View {
        VStack(alignment: .leading, spacing: 6) {
            fieldHeader("Title", field: .title, work: .title, suggest: ai.suggestTitle, label: "Suggest Title")
            TextField(text: $title, prompt: Text("A title for the video")) {
                Text("Title")
            }
            .labelsHidden()
            .textFieldStyle(.roundedBorder)
            .focused($focus, equals: .title)
            .onSubmit { ai.setTitle(title) }
            .accessibilityLabel(Text("Title"))
            error(of: .title)
        }
    }

    private var summaryField: some View {
        VStack(alignment: .leading, spacing: 6) {
            fieldHeader("Summary", field: .summary, work: .summary, suggest: ai.suggestSummary, label: "Suggest Summary")
            TextEditor(text: $summary)
                .font(.body)
                .scrollContentBackground(.hidden)
                .padding(.horizontal, 3)
                .padding(.vertical, 5)
                .frame(height: Self.summaryHeight)
                .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(Color(nsColor: .textBackgroundColor)))
                .overlay(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .strokeBorder(focus == .summary ? Color.accentColor.opacity(0.7) : Color.primary.opacity(0.14))
                )
                .overlay(alignment: .topLeading) {
                    if summary.isEmpty {
                        Text("What the video is about, in 2 to 4 sentences.")
                            .foregroundStyle(.tertiary)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 5)
                            .allowsHitTesting(false)
                            .accessibilityHidden(true)
                    }
                }
                .focused($focus, equals: .summary)
                .accessibilityLabel(Text("Summary"))
            error(of: .summary)
        }
    }

    /// The field's name and its «Suggest», which shows a small progress and «Cancel» while the model writes it.
    private func fieldHeader(
        _ name: LocalizedStringKey, field: EditorAI.Field, work: EditorAI.Work, suggest: @escaping () -> Void,
        label: LocalizedStringKey
    ) -> some View {
        HStack(spacing: 6) {
            Text(name)
                .accessibilityHidden(true)
            Spacer(minLength: 4)
            if ai.work == work {
                ProgressView()
                    .controlSize(.small)
                Button("Cancel") { ai.cancel() }
                    .controlSize(.small)
            } else {
                Button {
                    commit()
                    focus = nil
                    suggest()
                } label: {
                    Label("Suggest", systemImage: "sparkles")
                }
                .controlSize(.small)
                .disabled(!ai.canSuggest)
                .help(Text(label))
                .accessibilityLabel(Text(label))
            }
        }
    }

    @ViewBuilder
    private func error(of field: EditorAI.Field) -> some View {
        if ai.infoErrorField == field, let sentence = ai.infoError {
            Label {
                Text(verbatim: sentence)
                    .fixedSize(horizontal: false, vertical: true)
            } icon: {
                Image(systemName: "exclamationmark.triangle")
                    .foregroundStyle(.orange)
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        }
    }

    // MARK: - Why not

    /// Why the AI can't (decision 9), or, without a transcript, «Transcribe» (or how far it is).
    @ViewBuilder
    private var status: some View {
        if case .unavailable(let reason) = ai.availability {
            note(EditorAI.text(reason), symbol: "sparkles")
        } else if model.document?.transcript == nil {
            switch voice.transcription {
            case .running(let progress):
                note(transcribing(progress), symbol: "captions.bubble")
            case .queued:
                note(transcribing(0), symbol: "captions.bubble")
            default:
                HStack(spacing: 8) {
                    note(String(localized: "No transcript.", comment: "The Info tab: the project has no transcript to suggest from"), symbol: "captions.bubble")
                    Spacer(minLength: 4)
                    Button("Transcribe") { ai.transcribeFirst() }
                        .controlSize(.small)
                        .disabled(!model.canEdit)
                }
            }
        }
    }

    private func transcribing(_ progress: Double) -> String {
        String(
            format: String(localized: "Transcribing… %lld %%", comment: "The Captions tab: the transcription under way"),
            Int((min(max(progress, 0), 1) * 100).rounded(.down)))
    }

    private func note(_ text: String, symbol: String) -> some View {
        Label {
            Text(verbatim: text)
                .fixedSize(horizontal: false, vertical: true)
        } icon: {
            Image(systemName: symbol)
                .foregroundStyle(.tertiary)
        }
        .font(.callout)
        .foregroundStyle(.secondary)
    }

    private func caption(_ text: LocalizedStringKey) -> some View {
        Text(text)
            .font(.caption)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
    }

    /// What the focused field shows, saved (its step) before something else uses the document.
    private func commit() {
        switch focus {
        case .title?: ai.setTitle(title)
        case .summary?: ai.setSummary(summary)
        case nil: break
        }
    }
}
