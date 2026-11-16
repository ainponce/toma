// SPDX-License-Identifier: GPL-3.0-or-later
import AppKit
import AppSupport
import Editing
import SwiftUI

/// What the sheet says at its foot after its last action, until the next one.
enum ManageStylesNotice: Equatable {
    case added(String)
    case importDamaged
    case importFailed
    case saveFailed
    case trashFailed
}

/// "Manage Styles…" (1c design §8): Toma's style and the library's, each renamed in place, duplicated, deleted (to the
/// macOS Trash, after asking), shown in Finder or chosen for new projects (the star); "Import…" adds `.tomastyle` files.
/// Deleting the style of the new projects makes Toma's style theirs.
struct ManageStylesSheet: View {
    @Environment(\.dismiss) private var dismiss

    @State private var selection: String?
    /// The names being typed, by style: a name is saved when it is submitted or its field loses the focus.
    @State private var drafts: [String: String] = [:]
    @FocusState private var editing: String?
    @State private var deleting: NamedStyle?
    @State private var notice: ManageStylesNotice?
    @State private var working = false

    private var catalog: StyleCatalog { .shared }

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
            if let notice {
                Text(text(notice))
                    .font(.caption)
                    .foregroundStyle(isFailure(notice) ? Color.red : Color.secondary)
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
                Button("Done") {
                    // A name still being typed is saved as if it had been submitted.
                    for id in drafts.keys { commitName(id) }
                    dismiss()
                }
                // Return belongs to the name being typed (it saves it); Escape closes the sheet.
                .keyboardShortcut(.cancelAction)
            }
        }
        .padding(20)
        .frame(width: 440)
        .onChange(of: editing) { previous, _ in
            if let previous { commitName(previous) }
        }
        .alert(
            deleting.map { Text("Delete the style “\($0.name)”?") } ?? Text(verbatim: ""),
            isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } }), presenting: deleting
        ) { style in
            Button("Move to Trash", role: .destructive) { delete(style) }
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
                    .onSubmit { commitName(style.id) }
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
            Button("Delete…") { deleting = style }
        }
    }

    /// The name in the field of `style`: what is being typed, else its name.
    private func name(of style: NamedStyle) -> Binding<String> {
        Binding(get: { drafts[style.id] ?? style.name }, set: { drafts[style.id] = $0 })
    }

    private func text(_ notice: ManageStylesNotice) -> LocalizedStringKey {
        switch notice {
        case let .added(name): "Style “\(name)” was added."
        case .importDamaged: "Couldn't import the style: the file is damaged."
        case .importFailed: "Couldn't import the style."
        case .saveFailed: "The style couldn't be saved."
        case .trashFailed: "The style couldn't be moved to the Trash."
        }
    }

    private func isFailure(_ notice: ManageStylesNotice) -> Bool {
        if case .added = notice { false } else { true }
    }

    // MARK: - Actions

    /// Saves the name typed for the style of `id`, if it is one (not empty) and another; otherwise the field shows its
    /// name again.
    private func commitName(_ id: String) {
        guard let draft = drafts.removeValue(forKey: id), let style = catalog.styles.first(where: { $0.id == id }),
            let name = StyleMenu.validName(draft), name != style.name
        else { return }
        run {
            do {
                try await catalog.rename(id, to: name)
            } catch {
                notice = .saveFailed
            }
        }
    }

    private func duplicate(_ style: NamedStyle) {
        run {
            do {
                selection = try await catalog.duplicate(style).id
            } catch {
                notice = .saveFailed
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
                notice = .trashFailed
            }
        }
    }

    /// "Import…": `.tomastyle` packages chosen in an open panel, each copied into the library.
    private func chooseFiles() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [StyleCatalog.fileType]
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.begin { response in
            guard response == .OK else { return }
            let urls = panel.urls
            run {
                for url in urls {
                    switch await catalog.importStyle(url) {
                    case let .added(style):
                        notice = .added(style.name)
                        selection = style.id
                    case .alreadyInLibrary: break
                    case .damaged: notice = .importDamaged
                    case .failed: notice = .importFailed
                    }
                }
            }
        }
    }

    /// Runs `work`, one at a time: the sheet waits meanwhile, and the last action's notice goes.
    private func run(_ work: @escaping @MainActor () async -> Void) {
        notice = nil
        working = true
        Task {
            await work()
            working = false
        }
    }
}
