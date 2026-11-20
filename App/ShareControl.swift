// SPDX-License-Identifier: GPL-3.0-or-later
import AppKit
import AppSupport
import Sharing
import SwiftUI

/// Share, in the editor's bar (plan 5a, Task S4; design §8.3): a button that opens a little window (a popover) with what
/// sharing is now (not set up, ready, exporting or uploading, the link, or why it failed) and the project's earlier
/// links. While a share runs, the button is a ring of its progress.
struct ShareControl: View {
    let model: EditorModel

    var body: some View {
        @Bindable var share = model.share
        Button {
            share.isPresented.toggle()
        } label: {
            if case let .running(progress) = share.state {
                ProgressView(value: progress.fraction)
                    .progressViewStyle(.circular)
                    .controlSize(.small)
            } else {
                Label {
                    Text("Share", comment: "The editor's bar: the button that shares a link to the video")
                } icon: {
                    Image(systemName: "square.and.arrow.up")
                }
            }
        }
        .help(Text("Share a Link", comment: "The help of the editor's Share button"))
        .accessibilityLabel(Text("Share", comment: "The editor's bar: the button that shares a link to the video"))
        .accessibilityValue(accessibilityValue(share.state))
        .disabled(model.document == nil)
        .popover(isPresented: $share.isPresented, arrowEdge: .bottom) {
            SharePopover(model: model, share: share)
        }
    }

    private func accessibilityValue(_ state: EditorShare.State) -> Text {
        guard case let .running(progress) = state else { return Text(verbatim: "") }
        return Text(progress.fraction, format: .percent.precision(.fractionLength(0)))
    }
}

/// The little window of Share.
private struct SharePopover: View {
    let model: EditorModel
    let share: EditorShare
    @State private var confirming: ShareRecord?

    static let width: CGFloat = 340

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            current
            let earlier = earlierLinks
            if !earlier.isEmpty || share.historyProblem != nil {
                Divider()
                history(earlier)
            }
        }
        .padding(16)
        .frame(width: Self.width, alignment: .leading)
        .onAppear { share.refresh() }
        .alert(
            Text("Delete from storage?", comment: "Asking before deleting a shared link's video, poster and page from the storage"),
            isPresented: Binding(get: { confirming != nil }, set: { if !$0 { confirming = nil } }),
            presenting: confirming
        ) { record in
            Button(role: .destructive) {
                share.delete(record)
            } label: {
                Text("Delete from Storage", comment: "Deletes a shared link's video, poster and page from the storage")
            }
            Button("Cancel", role: .cancel) {}
        } message: { record in
            Text(
                "The video, the poster and the page are deleted from “\(record.bucket)”. The link stops working. This can't be undone.",
                comment: "Asking before deleting a shared link from the storage; the bucket's name in quotes")
        }
    }

    /// The links of before: all of them but the one just shared, shown above.
    private var earlierLinks: [ShareRecord] {
        guard case let .finished(shared) = share.state else { return share.records }
        return share.records.filter { $0.id != shared.id }
    }

    // MARK: - What sharing is now

    @ViewBuilder
    private var current: some View {
        switch share.state {
        case let .running(progress):
            running(progress)
        case let .finished(record):
            finished(record)
        case let .failed(reason):
            failed(reason)
        case .idle:
            if !share.isLoaded {
                ProgressView()
                    .controlSize(.small)
                    .frame(maxWidth: .infinity)
            } else if share.isConfigured {
                ready
            } else {
                notSetUp
            }
        }
    }

    private var notSetUp: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Share uploads the video to your storage: R2, S3, B2 or MinIO.", comment: "Share, before it is set up")
                .fixedSize(horizontal: false, vertical: true)
            Button {
                share.isPresented = false
                (NSApp.delegate as? AppDelegate)?.showShareSettings()
            } label: {
                Text("Set Up…", comment: "Share, before it is set up: opens Settings ▸ Share")
            }
        }
    }

    private var ready: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(verbatim: title)
                .font(.headline)
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
            Text(
                "Uploads to \(share.preferences.bucket.trimmingCharacters(in: .whitespaces)) on \(host)",
                comment: "Share, before sharing: the bucket and the storage's host it uploads to")
                .foregroundStyle(.secondary)
                .lineLimit(2)
                .truncationMode(.middle)
            Text(verbatim: ShareTexts.lifetime(of: share.preferences))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack(alignment: .firstTextBaseline) {
                if share.waitsForAnExport {
                    Text("Wait for the export to finish.", comment: "Share: another export is running")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 8)
                shareButton
            }
            .padding(.top, 8)
        }
    }

    @ViewBuilder
    private var shareButton: some View {
        let button = Button {
            share.start()
        } label: {
            Text("Share", comment: "The editor's bar: the button that shares a link to the video")
        }
        .keyboardShortcut(.defaultAction)
        .disabled(!share.canStart)
        if #available(macOS 26, *) {
            button.buttonStyle(.glassProminent)
        } else {
            button.buttonStyle(.borderedProminent)
        }
    }

    private func running(_ progress: ShareProgress) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Group {
                if share.isCancelling {
                    Text("Canceling…", comment: "Share: cancelled, removing what was uploaded")
                } else if progress.phase == .exporting {
                    Text("Exporting…")
                } else {
                    Text("Uploading…", comment: "Share: the video, its poster and its page are being uploaded")
                }
            }
            .font(.headline)
            ProgressView(value: progress.fraction)
                .progressViewStyle(.linear)
            HStack {
                Spacer()
                Button("Cancel") { share.cancel() }
                    .disabled(share.isCancelling)
            }
        }
    }

    private func finished(_ record: ShareRecord) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Label {
                Text("Link ready", comment: "Share: the video was uploaded and its link is ready")
            } icon: {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(.green)
            }
            .font(.headline)
            Text(verbatim: record.url)
                .font(.callout.monospaced())
                .lineLimit(3)
                .truncationMode(.middle)
                .textSelection(.enabled)
                .padding(.horizontal, 8)
                .padding(.vertical, 6)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(.quaternary.opacity(0.6), in: RoundedRectangle(cornerRadius: 6))
                .accessibilityLabel(Text("Link", comment: "A shared link, for VoiceOver"))
            HStack {
                Button("Copy") { share.copy(record) }
                    .keyboardShortcut("c", modifiers: [.command, .shift])
                Button("Open") { share.open(record) }
                Spacer()
            }
            Text(verbatim: noteText(for: record))
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            ForEach(share.notices, id: \.self) { notice in
                Text(verbatim: notice)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func failed(_ reason: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Label {
                Text("Couldn't share the video", comment: "Share failed; why follows")
            } icon: {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.yellow)
            }
            .font(.headline)
            Text(verbatim: reason)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
            HStack {
                Spacer()
                Button {
                    share.start()
                } label: {
                    Text("Retry", comment: "Share failed: try sharing again")
                }
                .disabled(!share.canStart)
            }
        }
    }

    /// What is said of the link shown: once copied, that it was and whether it is public or when it expires; before,
    /// whether it is public or when it expires.
    private func noteText(for record: ShareRecord) -> String {
        if let copied = share.copied, copied.id == record.id { return ShareTexts.copied(copied.note) }
        switch ShareRules.note(for: record, now: Date()) {
        case .permanent:
            return String(localized: "The link is public: anyone with the link can watch it.", comment: "Share: a public link, before it is copied")
        case let note:
            return ShareTexts.status(note)
        }
    }

    // MARK: - The links of before

    private func history(_ records: [ShareRecord]) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Earlier Links", comment: "Share: the project's links shared before")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.secondary)
            if let problem = share.historyProblem {
                Text(verbatim: problem)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(records.enumerated()), id: \.element.id) { index, record in
                        if index > 0 { Divider() }
                        ShareRecordRow(share: share, record: record) { confirming = record }
                    }
                }
            }
            .frame(maxHeight: 236)
            .fixedSize(horizontal: false, vertical: records.count <= 4)
        }
    }

    // MARK: - Words

    /// What is shared: the document's title, or the project's name.
    private var title: String {
        let title = (model.document?.info?.title ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        return title.isEmpty ? model.name : title
    }

    /// The storage's host, from Settings ▸ Share's endpoint.
    private var host: String {
        let endpoint = share.preferences.endpoint.trimmingCharacters(in: .whitespacesAndNewlines)
        return URLComponents(string: endpoint)?.host ?? endpoint
    }
}

/// A link of before: when it was shared, whether it is public, expires or expired, its size; "Copy", "Open" (not once
/// it expired) and "Delete from Storage", which asks first.
private struct ShareRecordRow: View {
    let share: EditorShare
    let record: ShareRecord
    let confirmDelete: () -> Void

    var body: some View {
        let note = ShareRules.note(for: record, now: Date())
        let expired = if case .expired = note { true } else { false }
        HStack(alignment: .center, spacing: 8) {
            VStack(alignment: .leading, spacing: 2) {
                Text(record.createdAt, format: .dateTime.day().month(.abbreviated).year().hour().minute())
                    .font(.callout)
                    .lineLimit(1)
                Text(verbatim: "\(ShareTexts.status(note)) · \(record.bytes.formatted(.byteCount(style: .file)))")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                if let copied = share.copied, copied.id == record.id {
                    Text(verbatim: ShareTexts.copied(copied.note))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if let problem = share.deleteProblem, problem.id == record.id {
                    Text(verbatim: problem.text)
                        .font(.caption)
                        .foregroundStyle(.red)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 4)
            if share.deleting.contains(record.id) {
                ProgressView()
                    .controlSize(.small)
                    .accessibilityLabel(Text("Deleting from storage…", comment: "A shared link being deleted from the storage"))
            } else {
                HStack(spacing: 2) {
                    Button { share.copy(record) } label: { Image(systemName: "doc.on.doc") }
                        .help(Text("Copy"))
                        .accessibilityLabel(Text("Copy"))
                    if !expired {
                        Button { share.open(record) } label: { Image(systemName: "safari") }
                            .help(Text("Open"))
                            .accessibilityLabel(Text("Open"))
                    }
                    Button(action: confirmDelete) { Image(systemName: "trash") }
                        .help(Text("Delete from Storage", comment: "Deletes a shared link's video, poster and page from the storage"))
                        .accessibilityLabel(Text("Delete from Storage", comment: "Deletes a shared link's video, poster and page from the storage"))
                }
                .buttonStyle(.borderless)
                .imageScale(.medium)
            }
        }
        .padding(.vertical, 6)
    }
}
