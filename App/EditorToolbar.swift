// SPDX-License-Identifier: GPL-3.0-or-later
import AppSupport
import Library
import ProjectFormat
import SwiftUI

/// The editor's bar (design §5.2), in the window's unified toolbar: on the left the project's name (which a click edits,
/// design §6.7) and what the output lasts, in the middle the format, on the right the Takes and Markers menus (phase 3
/// design §8.1 and §8.3), the panel's button, Share (plan 5a) and Export. Each item
/// has the identifier `-TomaDumpEditorStructure` prints. On macOS 26 the name and the duration are the window's title, not
/// a glass capsule (`TitledEditorToolbar`).
struct EditorToolbar: CustomizableToolbarContent {
    let model: EditorModel
    /// Shows or hides the panel.
    let togglePanel: () -> Void

    var body: some CustomizableToolbarContent {
        nameItem
        durationItem
        formatItem
        takesItem
        markersItem
        panelItem
        shareItem
        exportItem
    }

    var nameItem: some CustomizableToolbarContent {
        ToolbarItem(id: "editor.name", placement: .navigation) {
            if let actions = model.projectActions {
                EditorNameField(model: model, actions: actions)
            } else {
                EditorNameField.name(model.name)
            }
        }
        .customizationBehavior(.disabled)
    }

    /// What the output lasts, secondary to the name and apart from it.
    var durationItem: some CustomizableToolbarContent {
        ToolbarItem(id: "editor.duration", placement: .navigation) {
            // A placeholder of the same width until the project opens: an empty item has no size.
            Text(verbatim: Timecode.duration(model.durationSeconds))
                .monospacedDigit()
                .foregroundStyle(.secondary)
                .padding(.leading, 4)
                .opacity(model.document == nil ? 0 : 1)
                .help(Text("Duration"))
        }
        .customizationBehavior(.disabled)
    }

    var formatItem: some CustomizableToolbarContent {
        ToolbarItem(id: "editor.format", placement: .principal) {
            FormatMenu(model: model)
        }
    }

    /// The project's takes (phase 3 design §8.1).
    var takesItem: some CustomizableToolbarContent {
        ToolbarItem(id: "editor.takes", placement: .primaryAction) {
            TakesMenu(model: model)
        }
    }

    /// The project's markers (phase 3 design §8.3).
    var markersItem: some CustomizableToolbarContent {
        ToolbarItem(id: "editor.markers", placement: .primaryAction) {
            MarkersMenu(model: model)
        }
    }

    var panelItem: some CustomizableToolbarContent {
        ToolbarItem(id: "editor.panel", placement: .primaryAction) {
            Button(action: togglePanel) {
                Label(model.panelVisible ? LocalizedStringKey("Hide Panel") : LocalizedStringKey("Show Panel"), systemImage: "sidebar.right")
            }
            .help(model.panelVisible ? Text("Hide Panel") : Text("Show Panel"))
        }
    }

    /// Share (plan 5a, Task S4): a link to a page of the video, uploaded to the person's own storage.
    var shareItem: some CustomizableToolbarContent {
        ToolbarItem(id: "editor.share", placement: .primaryAction) {
            ShareControl(model: model)
        }
    }

    var exportItem: some CustomizableToolbarContent {
        ToolbarItem(id: "editor.export", placement: .primaryAction) {
            ExportControl(model: model)
        }
        .customizationBehavior(.disabled)
    }
}

/// `EditorToolbar` on macOS 26: the same items, the name and the duration without the glass they would share, so they
/// read as the window's title (plain text, as the system's title is), the duration apart and secondary.
@available(macOS 26, *)
struct TitledEditorToolbar: CustomizableToolbarContent {
    let toolbar: EditorToolbar

    var body: some CustomizableToolbarContent {
        toolbar.nameItem.sharedBackgroundVisibility(.hidden)
        toolbar.durationItem.sharedBackgroundVisibility(.hidden)
        toolbar.formatItem
        toolbar.takesItem
        toolbar.markersItem
        toolbar.panelItem
        toolbar.shareItem
        toolbar.exportItem
    }
}

/// The project's name in the bar (design §6.7): a click on it edits it, as File ▸ Rename does; ↩ renames the package, Esc
/// and leaving it with a name that cannot be used leave it as it was; beside the field, what is wrong with the name as it
/// is typed, or what the disk said (the library's words). Renaming is not an edit of the document: what is typed is
/// undone in the field, never in the editor's history.
private struct EditorNameField: View {
    let model: EditorModel
    let actions: EditorProjectActions

    var body: some View {
        if actions.isRenaming {
            EditorNameEditor(actions: actions, name: model.name)
        } else {
            HStack(spacing: 6) {
                Self.name(model.name)
                    .contentShape(Rectangle())
                    .onTapGesture { actions.startRenaming() }
                    .accessibilityAddTraits(actions.canRename ? .isButton : [])
                    .accessibilityAction(named: Text(verbatim: LibraryActions.title(.startRenaming, items: []))) {
                        actions.startRenaming()
                    }
                if actions.isBusy {
                    // A copy, the trash or a restore under way.
                    ProgressView()
                        .controlSize(.small)
                }
            }
        }
    }

    /// The name as the bar shows it while it is not edited.
    static func name(_ name: String) -> some View {
        Text(verbatim: name)
            .font(.headline)
            .lineLimit(1)
            .help(Text(verbatim: name))
    }
}

/// The field of `EditorNameField`, made anew each time the name starts being edited, with the name it has.
private struct EditorNameEditor: View {
    let actions: EditorProjectActions
    @State private var text: String
    @FocusState private var isFocused: Bool

    init(actions: EditorProjectActions, name: String) {
        self.actions = actions
        _text = State(initialValue: name)
    }

    var body: some View {
        HStack(spacing: 6) {
            TextField(text: $text) {
                Text("Name", comment: "A name: a field, a column or an order")
            }
            .labelsHidden()
            .textFieldStyle(.roundedBorder)
            .frame(width: 220)
            .focused($isFocused)
            .onSubmit { actions.commitRename(text, leaving: false) }
            .onExitCommand { actions.cancelRenaming() }
            .onChange(of: text) { actions.nameEdited() }
            .onChange(of: isFocused) { _, focused in
                if !focused { actions.commitRename(text, leaving: true) }
            }
            .onAppear { isFocused = true }
            if let problem = actions.problem(with: text) {
                Text(verbatim: LibraryActions.help(problem))
                    .font(.caption)
                    .foregroundStyle(.red)
                    .lineLimit(1)
                    .help(Text(verbatim: LibraryActions.help(problem)))
            }
        }
    }
}

/// The format selector: the seven formats, 16:9, 9:16, 1:1, 4:5, 4:3, 3:4 and Like the Recording. Choosing one is an edit. Its formats, titles and symbols are also the
/// Project menu's (`ProjectCommands`).
struct FormatMenu: View {
    let model: EditorModel

    var body: some View {
        let aspect = model.document?.aspect ?? model.previewAspect
        Menu {
            Picker(selection: Binding(get: { aspect }, set: { model.setAspect($0) })) {
                ForEach(Self.aspects, id: \.self) { aspect in
                    Label(Self.title(aspect), systemImage: Self.symbol(aspect)).tag(aspect)
                }
            } label: {
                Text("Format")
            }
            .pickerStyle(.inline)
            .labelsHidden()
        } label: {
            Label(title: { aspect == .auto ? Text(Self.title(aspect)) : Text(verbatim: aspect.rawValue) }, icon: { Image(systemName: Self.symbol(aspect)) })
                .labelStyle(.titleAndIcon)
        }
        .menuIndicator(.visible)
        .fixedSize()
        .disabled(!model.canEdit)
        .help(Text("Format"))
        .accessibilityLabel(Text("Format"))
        .accessibilityValue(Text(Self.title(aspect)))
    }

    static let aspects = Aspect.allCases

    #if DEBUG
    /// The choices as the menu lists them, for `-TomaShowcase formats`.
    static var showcase: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(aspects, id: \.self) { aspect in
                Label(title(aspect), systemImage: symbol(aspect))
            }
            Divider()
            Label(title: { Text(title(.auto)) }, icon: { Image(systemName: symbol(.auto)) })
                .labelStyle(.titleAndIcon)
        }
        .padding(16)
        .frame(width: 260, alignment: .leading)
    }
    #endif

    static func symbol(_ aspect: Aspect) -> String {
        switch aspect {
        case .landscape: "rectangle"
        case .portrait: "rectangle.portrait"
        case .square: "square"
        case .fourByFive: "rectangle.portrait"
        case .fourByThree: "rectangle"
        case .threeByFour: "rectangle.portrait"
        case .auto: "rectangle.dashed"
        }
    }

    static func title(_ aspect: Aspect) -> LocalizedStringKey {
        switch aspect {
        case .landscape: "16:9 Landscape"
        case .portrait: "9:16 Portrait"
        case .square: "1:1 Square"
        case .fourByFive: "4:5 Portrait"
        case .fourByThree: "4:3 Landscape"
        case .threeByFour: "3:4 Portrait"
        case .auto: "Like the Recording"
        }
    }
}

/// Export (⌘E), prominent, which opens the export sheet (`ExportSheet`); while exporting, a ring of its progress with
/// "Cancel Export"; once done, "Export finished · Show in Finder · Copy" for 8 seconds, for an MP4 and a GIF alike (1c
/// decision 24: Copy puts the file on the clipboard).
private struct ExportControl: View {
    let model: EditorModel

    var body: some View {
        switch model.exportState {
        case let .running(progress):
            Menu {
                Button("Cancel Export") { model.cancelExport() }
            } label: {
                ProgressView(value: progress)
                    .progressViewStyle(.circular)
                    .controlSize(.small)
            }
            .menuIndicator(.hidden)
            .fixedSize()
            .help(Text("Exporting…"))
            .accessibilityLabel(Text("Exporting…"))
            .accessibilityValue(Text(progress, format: .percent.precision(.fractionLength(0))))
        case .finished:
            HStack(spacing: 8) {
                Text("Export finished")
                    .foregroundStyle(.secondary)
                Button("Show in Finder") { model.showExportInFinder() }
                Button {
                    model.copyExport()
                } label: {
                    Text("Copy", comment: "The editor's bar after an export: puts the exported file on the clipboard")
                }
            }
            .fixedSize()
        case .idle:
            exportButton
        }
    }

    @ViewBuilder
    private var exportButton: some View {
        let button = Button("Export") { model.openExportSheet() }
            .keyboardShortcut("e", modifiers: .command)
            .disabled(!model.canExport)
        if #available(macOS 26, *) {
            button.buttonStyle(.glassProminent)
        } else {
            button.buttonStyle(.borderedProminent)
        }
    }
}
