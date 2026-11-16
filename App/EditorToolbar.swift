// SPDX-License-Identifier: GPL-3.0-or-later
import AppSupport
import ProjectFormat
import SwiftUI

/// The editor's bar (design §5.2), in the window's unified toolbar: on the left the project's name and what the output
/// lasts, in the middle the format, on the right the panel's button and Export. Each item has the identifier
/// `-TomaDumpEditorStructure` prints.
struct EditorToolbar: CustomizableToolbarContent {
    let model: EditorModel
    /// Shows or hides the panel.
    let togglePanel: () -> Void

    var body: some CustomizableToolbarContent {
        ToolbarItem(id: "editor.name", placement: .navigation) {
            Text(verbatim: model.name)
                .font(.headline)
                .lineLimit(1)
                .help(Text(verbatim: model.name))
        }
        .customizationBehavior(.disabled)
        ToolbarItem(id: "editor.duration", placement: .navigation) {
            // A placeholder of the same width until the project opens: an empty item has no size.
            Text(verbatim: Timecode.duration(model.durationSeconds))
                .monospacedDigit()
                .foregroundStyle(.secondary)
                .opacity(model.document == nil ? 0 : 1)
        }
        .customizationBehavior(.disabled)
        ToolbarItem(id: "editor.format", placement: .principal) {
            FormatMenu(model: model)
        }
        ToolbarItem(id: "editor.panel", placement: .primaryAction) {
            Button(action: togglePanel) {
                Label(model.panelVisible ? LocalizedStringKey("Hide Panel") : LocalizedStringKey("Show Panel"), systemImage: "sidebar.right")
            }
            .help(model.panelVisible ? Text("Hide Panel") : Text("Show Panel"))
        }
        ToolbarItem(id: "editor.export", placement: .primaryAction) {
            ExportControl(model: model)
        }
        .customizationBehavior(.disabled)
    }
}

/// The format selector: 16:9, 9:16 and 1:1. Choosing one is an edit.
private struct FormatMenu: View {
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
            Label(title: { Text(verbatim: aspect.rawValue) }, icon: { Image(systemName: Self.symbol(aspect)) })
                .labelStyle(.titleAndIcon)
        }
        .menuIndicator(.visible)
        .fixedSize()
        .disabled(!model.canEdit)
        .help(Text("Format"))
        .accessibilityLabel(Text("Format"))
        .accessibilityValue(Text(Self.title(aspect)))
    }

    private static let aspects: [Aspect] = [.landscape, .portrait, .square]

    static func symbol(_ aspect: Aspect) -> String {
        switch aspect {
        case .landscape: "rectangle"
        case .portrait: "rectangle.portrait"
        case .square: "square"
        }
    }

    static func title(_ aspect: Aspect) -> LocalizedStringKey {
        switch aspect {
        case .landscape: "16:9 Landscape"
        case .portrait: "9:16 Portrait"
        case .square: "1:1 Square"
        }
    }
}

/// Export (⌘E), prominent; while exporting, a ring of its progress with "Cancel Export"; once done, "Export finished ·
/// Show in Finder" for a few seconds.
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
            }
            .fixedSize()
        case .idle:
            exportButton
        }
    }

    @ViewBuilder
    private var exportButton: some View {
        let button = Button("Export") { model.exportVideo() }
            .keyboardShortcut("e", modifiers: .command)
            .disabled(!model.canExport)
        if #available(macOS 26, *) {
            button.buttonStyle(.glassProminent)
        } else {
            button.buttonStyle(.borderedProminent)
        }
    }
}
