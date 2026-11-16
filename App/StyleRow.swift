// SPDX-License-Identifier: GPL-3.0-or-later
import AppSupport
import Editing
import ProjectFormat
import SwiftUI

/// What the row Style says under it after its last action, until the next one.
enum StyleRowNotice: Equatable {
    /// "Apply" left the background as it was: the style's image is not in its package (the rest was applied).
    case imageMissing
    /// "Apply" changed nothing: the disk refused the style's image.
    case applyFailed
    /// "Save as New Style…" or "Update" could not write the style.
    case saveFailed
}

/// The row Style above the panel's tabs (1c design §8): "Style [Tutorials ▾]", with the name of the saved style the
/// project has exactly, "Toma's Style" or "Custom". Its menu applies a style (one edit; the one new projects take is
/// starred), saves the project's look as a new style or over the one it came from, chooses the style of the new projects
/// and opens "Manage Styles…". Saving and managing work on a read-only project too; applying does not.
struct StyleRow: View {
    let model: EditorModel
    let document: EditDocument

    /// The last saved style the project had exactly in this window: what "Update" saves over once it changed.
    @State private var lastNamedID: String?
    @State private var notice: StyleRowNotice?
    @State private var working = false
    @State private var naming = false
    @State private var newName = ""
    @State private var managing = false

    private var catalog: StyleCatalog { .shared }

    var body: some View {
        let styles = catalog.styles
        let match = StyleCommands.matchingStyle(document, among: styles)
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                Text("Style")
                    .foregroundStyle(.secondary)
                Spacer(minLength: 8)
                if working {
                    ProgressView()
                        .controlSize(.small)
                }
                Menu {
                    menu(match: match, styles: styles)
                } label: {
                    title(match, styles)
                }
                .menuStyle(.button)
                .buttonStyle(.borderless)
                .fixedSize()
                .disabled(working)
                .accessibilityLabel(Text("Style"))
                .accessibilityValue(title(match, styles))
            }
            if let notice {
                Text(text(notice))
                    .font(.caption)
                    .foregroundStyle(notice == .imageMissing ? Color.orange : Color.red)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .onChange(of: match, initial: true) { _, match in
            if case let .named(id) = match { lastNamedID = id }
        }
        .alert("Save as New Style", isPresented: $naming) {
            TextField("Name", text: $newName)
            Button("Save", action: saveAsNewStyle)
                .disabled(StyleMenu.validName(newName) == nil)
            Button("Cancel", role: .cancel) {}
        }
        .sheet(isPresented: $managing) {
            ManageStylesSheet()
        }
    }

    // MARK: - The menu

    @ViewBuilder
    private func menu(match: StyleMatch, styles: [NamedStyle]) -> some View {
        let newProjects = catalog.newProjectsStyleID
        ForEach(styles, id: \.id) { style in
            Button {
                apply(style)
            } label: {
                label(Text(verbatim: style.name), starred: StyleMenu.isForNewProjects(style.id, newProjectsStyleID: newProjects, among: styles))
            }
            .disabled(!model.canEdit)
        }
        Button {
            apply(StyleCatalog.toma)
        } label: {
            label(Text("Toma's Style"), starred: StyleMenu.isForNewProjects(NamedStyle.tomaStyleID, newProjectsStyleID: newProjects, among: styles))
        }
        .disabled(!model.canEdit)
        Divider()
        Button("Save as New Style…") {
            newName = ""
            naming = true
        }
        if let target = StyleMenu.updateTarget(match, lastNamedID: lastNamedID, newProjectsStyleID: newProjects, among: styles) {
            Button("Update “\(target.style.name)” with This Project") { update(target.style) }
                .disabled(!target.changesIt)
        }
        Menu("Use for New Projects") {
            ForEach(styles, id: \.id) { style in
                Toggle(isOn: forNewProjects(style.id)) { Text(verbatim: style.name) }
            }
            Toggle(isOn: forNewProjects(nil)) { Text("Toma's Style") }
        }
        Divider()
        Button("Manage Styles…") { managing = true }
    }

    /// A style of the menu: with a star if new projects take it.
    @ViewBuilder
    private func label(_ name: Text, starred: Bool) -> some View {
        if starred {
            Label {
                name
            } icon: {
                Image(systemName: "star.fill")
            }
        } else {
            name
        }
    }

    private func title(_ match: StyleMatch, _ styles: [NamedStyle]) -> Text {
        switch StyleMenu.title(match, among: styles) {
        case let .named(name): Text(verbatim: name)
        case .toma: Text("Toma's Style")
        case .custom: Text("Custom")
        }
    }

    /// Whether new projects take the style of `id` (`nil`: Toma's); choosing it makes them.
    private func forNewProjects(_ id: String?) -> Binding<Bool> {
        Binding(
            get: { StyleMenu.isForNewProjects(id ?? NamedStyle.tomaStyleID, newProjectsStyleID: catalog.newProjectsStyleID, among: catalog.styles) },
            set: { chosen in if chosen { catalog.setNewProjectsStyle(id) } })
    }

    private func text(_ notice: StyleRowNotice) -> LocalizedStringKey {
        switch notice {
        case .imageMissing: "This style's image wasn't found: the background stays as it was."
        case .applyFailed: "Couldn't apply the style."
        case .saveFailed: "The style couldn't be saved."
        }
    }

    // MARK: - Actions

    /// "Apply": one edit, unless the project has the style already. What `EditSession.applyStyle` leaves unsaid is said
    /// here: an image that was not found, or a disk that refused it (a project that became read-only has its banner).
    private func apply(_ style: NamedStyle) {
        notice = nil
        guard !StyleMenu.has(document, style) else { return }
        working = true
        let model = model, imageDirectory = catalog.imageDirectory(of: style)
        Task {
            let result = await model.applyStyle(style, imageDirectory: imageDirectory)
            working = false
            if result.imageMissing {
                notice = .imageMissing
            } else if result.outcome == .refused, model.canEdit {
                notice = .applyFailed
            }
        }
    }

    /// "Save as New Style…": the project's look under the name asked for, as a new style.
    private func saveAsNewStyle() {
        guard let name = StyleMenu.validName(newName) else { return }
        let id = StyleMenu.newID(avoiding: Set(catalog.styles.map(\.id)))
        save(StyleMenu.style(of: document, id: id, name: name))
    }

    /// "Update “X” with This Project": the project's look over the style, which keeps its id and name.
    private func update(_ target: NamedStyle) {
        save(StyleMenu.style(of: document, id: target.id, name: target.name))
    }

    /// Saves `style` with the image of the project's background, read from its package.
    private func save(_ style: NamedStyle) {
        guard let session = model.panelSession else { return }
        notice = nil
        working = true
        let package = ProjectPackage(url: session.packageURL)
        Task {
            do {
                try await catalog.save(style, imageFrom: package)
                lastNamedID = style.id
            } catch {
                notice = .saveFailed
            }
            working = false
        }
    }
}
