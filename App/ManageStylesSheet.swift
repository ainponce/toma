// SPDX-License-Identifier: GPL-3.0-or-later
import AppKit
import AppSupport
import Editing
import SwiftUI

/// A line the sheet says at its foot after its last actions, until the next one.
enum ManageStylesNotice: Equatable {
    case imported(StyleImportNotice)
    case saveFailed
    case trashFailed

    var isFailure: Bool {
        switch self {
        case let .imported(notice): notice.isFailure
        case .saveFailed, .trashFailed: true
        }
    }
}

/// "Manage Styles…" (1c design §8): Toma's style and the library's, each renamed in place, duplicated, moved to the macOS
/// Trash (after asking), shown in Finder or chosen for new projects (the star); "Import…" adds `.tomastyle` files.
/// Moving the style of the new projects to the Trash makes Toma's style theirs. The library is read again when the sheet
/// opens, so what Finder changed meanwhile shows. Its actions run one after another, never two at once.
struct ManageStylesSheet: View {
    @Environment(\.dismiss) private var dismiss

    @State private var selection: String?
    /// The names being typed, by style: a name is saved when it is submitted, when its field loses the focus or on
    /// Done; Escape puts it back.
    @State private var drafts: [String: String] = [:]
    @FocusState private var editing: String?
    @State private var deleting: NamedStyle?
    @State private var notices: [ManageStylesNotice] = []
    /// The actions not finished yet, and the last one, which the next one waits for (`run`).
    @State private var pending = 0
    @State private var lastAction: Task<Void, Never>?

    private var catalog: StyleCatalog { .shared }
    private var working: Bool { pending > 0 }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Manage Styles")
                .font(.headline)
            List(selection: $selection) {
                row(nil)
                    .tag(NamedStyle.tomaStyleID)
                ForEach(catalog.styles, id: \.id) { style in
                    row(style)
                        .tag(style.id)
                }
            }
            .frame(minHeight: 240)
            .disabled(working)
            ForEach(Array(notices.enumerated()), id: \.offset) { _, notice in
                Text(text(notice))
                    .font(.caption)
                    .foregroundStyle(notice.isFailure ? Color.red : Color.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack {
                Button("Import…", action: chooseFiles)
                    .disabled(working)
                if working {
                    ProgressView()
                        .controlSize(.small)
                }
                Spacer()
                // No key: Return belongs to the name being typed (it saves it), and Escape is `exitCommand`.
                Button("Done", action: done)
            }
        }
        .padding(20)
        .frame(width: 440)
        .task { await catalog.reload() }
        .onChange(of: editing) { previous, _ in
            if let previous, drafts[previous] != nil { run { _ = await commitName(previous) } }
        }
        .onExitCommand(perform: exitCommand)
        .alert(
            deleting.map { Text("Delete the style “\($0.name)”?") } ?? Text(verbatim: ""),
            isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } }), presenting: deleting
        ) { style in
            Button("Move to the Trash", role: .destructive) { delete(style) }
            Button("Cancel", role: .cancel) {}
        } message: { _ in
            Text("It goes to the Trash.")
        }
    }

    // MARK: - Rows

    /// The row of `style`, or of Toma's style with `nil`: a star if new projects take it, its name (in a field, for the
    /// library's styles) and its actions.
    private func row(_ style: NamedStyle?) -> some View {
        let id = style?.id ?? NamedStyle.tomaStyleID
        let starred = StyleMenu.isForNewProjects(id, newProjectsStyleID: catalog.newProjectsStyleID, among: catalog.styles)
        return HStack(spacing: 8) {
            Image(systemName: "star.fill")
                .foregroundStyle(.secondary)
                .opacity(starred ? 1 : 0)
                .accessibilityLabel(Text("Use for New Projects"))
                .accessibilityHidden(!starred)
            if let style {
                TextField("Name", text: name(of: style))
                    .textFieldStyle(.plain)
                    .focused($editing, equals: style.id)
                    .onSubmit {
                        if drafts[style.id] != nil { run { _ = await commitName(style.id) } }
                    }
            } else {
                Text("Toma's Style")
            }
            Spacer(minLength: 8)
            Menu {
                actions(style)
            } label: {
                Image(systemName: "ellipsis.circle")
            }
            .menuStyle(.button)
            .buttonStyle(.borderless)
            .menuIndicator(.hidden)
            .fixedSize()
        }
        .contextMenu { actions(style) }
    }

    @ViewBuilder
    private func actions(_ style: NamedStyle?) -> some View {
        let id = style?.id ?? NamedStyle.tomaStyleID
        let can = StyleMenu.actions(for: id, newProjectsStyleID: catalog.newProjectsStyleID, among: catalog.styles, canEdit: false)
        if let style, can.canChangeFile {
            Button("Rename") { editing = style.id }
            Button("Duplicate") { duplicate(style) }
            Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([catalog.packageURL(of: style)]) }
        }
        Button("Use for New Projects") { catalog.setNewProjectsStyle(style?.id) }
            .disabled(!can.canUseForNewProjects)
        if let style, can.canChangeFile {
            Divider()
            Button("Move to the Trash…") { deleting = style }
        }
    }

    /// The name in the field of `style`: what is being typed, else its name.
    private func name(of style: NamedStyle) -> Binding<String> {
        Binding(get: { drafts[style.id] ?? style.name }, set: { drafts[style.id] = $0 })
    }

    private func text(_ notice: ManageStylesNotice) -> String {
        switch notice {
        case let .imported(notice): StyleCatalog.text(notice)
        case .saveFailed: String(localized: "The style couldn't be saved.")
        case .trashFailed: String(localized: "The style couldn't be moved to the Trash.")
        }
    }

    // MARK: - Actions

    /// "Done": once the actions under way end, the name being typed is saved as if it had been submitted, and the sheet
    /// closes, unless a name could not be saved: then it stays open and says so.
    private func done() {
        run {
            var saved = !notices.contains(.saveFailed)
            for id in Array(drafts.keys) {
                if await !commitName(id) { saved = false }
            }
            if saved { dismiss() }
        }
    }

    /// Escape: the name being typed goes back to what it was; with none, "Done".
    private func exitCommand() {
        if let id = editing {
            drafts[id] = nil
            editing = nil
        } else {
            done()
        }
    }

    /// Saves the name typed for the style of `id`, if it is one (not empty) and another; otherwise the field shows its
    /// name again. `false` if it could not be saved, which the sheet says.
    private func commitName(_ id: String) async -> Bool {
        guard let draft = drafts[id] else { return true }
        guard let style = catalog.styles.first(where: { $0.id == id }), let name = StyleMenu.validName(draft), name != style.name
        else {
            drafts[id] = nil
            return true
        }
        do {
            try await catalog.rename(id, to: name)
            drafts[id] = nil
            return true
        } catch {
            drafts[id] = nil
            notices.append(.saveFailed)
            return false
        }
    }

    private func duplicate(_ style: NamedStyle) {
        run {
            do {
                selection = try await catalog.duplicate(style).id
            } catch {
                notices.append(.saveFailed)
            }
        }
    }

    private func delete(_ style: NamedStyle) {
        deleting = nil
        run {
            do {
                try await catalog.delete(style.id)
                if selection == style.id { selection = nil }
            } catch {
                notices.append(.trashFailed)
            }
        }
    }

    /// "Import…": `.tomastyle` packages chosen in an open panel, each copied into the library. Every file that could not
    /// be imported is said, never hidden behind one that could (`StyleMenu.importNotices`).
    private func chooseFiles() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [StyleCatalog.fileType]
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.begin { response in
            guard response == .OK else { return }
            let urls = panel.urls
            run {
                let imported = await catalog.importStyles(urls)
                notices += imported.map(ManageStylesNotice.imported)
                // The first style it brought (or found there already) is selected.
                for notice in imported {
                    if case let .added(style) = notice.result { selection = style.id }
                    if case let .alreadyInLibrary(style) = notice.result { selection = style.id }
                    if !notice.isFailure { break }
                }
            }
        }
    }

    /// Runs `work` once the actions before it end, one at a time: the sheet shows it is busy until the last one ends. A
    /// new action takes away what the ones before said.
    private func run(_ work: @escaping @MainActor () async -> Void) {
        notices = []
        pending += 1
        let previous = lastAction
        lastAction = Task {
            await previous?.value
            await work()
            pending -= 1
        }
    }
}
