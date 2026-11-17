// SPDX-License-Identifier: GPL-3.0-or-later
import Darwin
import Editing
import Library
import SwiftUI

/// The strip above the preview (design §5.9) with the model's banner, if there is one: its sentence, "Apply Default
/// Style" on a project of an earlier version, Restaurar on one in the trash (1c design §6.4), and a button to close the
/// ones that can be closed. A change that could not be saved is amber.
struct EditorBanners: View {
    let model: EditorModel

    var body: some View {
        if let banner = model.banner {
            VStack(spacing: 0) {
                HStack(alignment: .firstTextBaseline, spacing: 10) {
                    Image(systemName: Self.symbol(banner))
                        .foregroundStyle(Self.isWarning(banner) ? Color.orange : Color.secondary)
                        .accessibilityHidden(true)
                    Text(Self.text(banner))
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    if Self.isWarning(banner), model.isApplyingDefaultStyle {
                        // "Apply Default Style" is still under way, waiting to save.
                        ProgressView()
                            .controlSize(.small)
                    }
                    if banner == .legacyLook {
                        if model.isApplyingDefaultStyle {
                            ProgressView()
                                .controlSize(.small)
                        }
                        Button("Apply Default Style") { model.applyDefaultStyle() }
                            .disabled(!model.canEdit || model.isApplyingDefaultStyle)
                    }
                    if banner == .readOnly(.inTrash), let actions = model.projectActions {
                        if actions.isBusy {
                            ProgressView()
                                .controlSize(.small)
                        }
                        Button(LibraryActions.title(.restore, items: [])) { actions.restore() }
                            .disabled(!actions.canRestore)
                    }
                    if Self.canClose(banner) {
                        Button {
                            model.dismissBanner()
                        } label: {
                            Image(systemName: "xmark")
                        }
                        .buttonStyle(.borderless)
                        .help(Text("Close"))
                        .accessibilityLabel(Text("Close"))
                    }
                }
                .font(.callout)
                .padding(.horizontal, 16)
                .padding(.vertical, 8)
                .background(Self.isWarning(banner) ? Color.orange.opacity(0.18) : Color(nsColor: .controlBackgroundColor))
                Divider()
            }
            .accessibilityElement(children: .contain)
        }
    }

    private static func isWarning(_ banner: EditorBanner) -> Bool {
        switch banner {
        case .saveFailed, .waitingForSpace: true
        case .readOnly, .reopenedAfterOtherApp, .recovered, .legacyLook, .videoGap: false
        }
    }

    private static func canClose(_ banner: EditorBanner) -> Bool {
        switch banner {
        case .legacyLook, .recovered, .reopenedAfterOtherApp: true
        case .saveFailed, .waitingForSpace, .readOnly, .videoGap: false
        }
    }

    private static func symbol(_ banner: EditorBanner) -> String {
        switch banner {
        case .saveFailed, .waitingForSpace: "exclamationmark.triangle.fill"
        case .readOnly: "lock"
        case .reopenedAfterOtherApp, .recovered, .legacyLook, .videoGap: "info.circle"
        }
    }

    /// The banner's sentence (design §5.11, and plan decision 15 for edit files that can't be used safely).
    static func text(_ banner: EditorBanner) -> String {
        switch banner {
        case let .saveFailed(code) where code == .ENOSPC || code == .EDQUOT:
            String(localized: "The last change couldn't be saved: the disk is full. Changes are saved as soon as there is space.")
        case .saveFailed:
            String(localized: "The last change couldn't be saved yet. Saving it is tried again every few seconds.")
        case .waitingForSpace(defaultStyle: true):
            String(localized: "Waiting for space on the disk to apply the default style…")
        case .waitingForSpace(defaultStyle: false):
            String(localized: "Waiting for space on the disk to apply the style…", comment: "Editor banner (amber): applying a style of the row Style waits for room on a full disk to bring its image in")
        case let .readOnly(reason):
            text(reason)
        case .reopenedAfterOtherApp:
            String(localized: "Another app changed this project: it was opened again and the last change wasn't applied.")
        case let .recovered(date):
            String(localized: "The edit was recovered up to \(date.formatted(date: .omitted, time: .shortened)). What couldn't be read was kept apart.")
        case .legacyLook:
            String(localized: "This project was recorded with an earlier version and keeps its look.")
        case .videoGap:
            String(localized: "This part of the recording couldn't be read: the frame before it is shown.")
        }
    }

    static func text(_ reason: ReadOnlyReason) -> String {
        switch reason {
        case .openElsewhere:
            String(localized: "This project is open in another app: it opens read-only.")
        case .otherAppStartedEditing:
            String(localized: "Another app started editing this project first: the last change wasn't applied and the project is now read-only.")
        case .diskNotWritable:
            String(localized: "This project is on a disk that can't be written to: changes can't be saved.")
        case .unsafeEditFiles:
            String(localized: "This project's edit files can't be used safely: it opens read-only.")
        case .newerDocument:
            String(localized: "This project was edited with a newer version of Toma. Update Toma to open it.")
        case .unreadable:
            String(localized: "Another app changed this project, and this version of Toma can't open it now.")
        case .inTrash:
            String(
                localized: "This project is in the trash: it opens read-only.",
                comment: "Editor banner: a project of the trash, which can be looked at, not edited; Restore is beside it")
        }
    }
}
