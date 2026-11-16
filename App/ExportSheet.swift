// SPDX-License-Identifier: GPL-3.0-or-later
import AppKit
import AppSupport
import Editing
import Export
import Observation
import ProjectFormat
import SwiftUI

/// What the export sheet (design §5.6) has chosen. Its options are parameters of the export, never edits: nothing of them
/// goes into the document or its log, and a project of an earlier version is never upgraded by them. The resolution and
/// the quality start at what the sheet remembers (`ExportPreferences`, in the app's settings); the frames per second at
/// the project's, every time.
@MainActor @Observable
final class ExportChoices {
    /// The document's format: shown, never chosen here (the bar and the Project menu change it).
    let aspect: Aspect
    /// What the output lasts, in seconds.
    let durationSeconds: Double
    /// The shorter side of what was recorded of the screen, in pixels; `nil` when unknown.
    let recordedShortSide: Int?
    var resolution: ExportResolution
    var framesPerSecond: Int
    var quality: ExportQuality

    init(document: EditDocument, take: TakeRecord, remembered: ExportPreferences) {
        aspect = document.aspect
        durationSeconds = TimeMap(sequence: document.sequence).durationSeconds
        recordedShortSide = ExportPreferences.recordedShortSide(of: take)
        resolution = ExportResolution(rawValue: remembered.shortSide) ?? .p1080
        framesPerSecond = StyleCommands.frameRates.contains(document.frameRate) ? document.frameRate : 60
        quality = remembered.highQuality ? .high : .standard
    }

    /// The export these choices make of the document.
    var settings: ExportSettings {
        ExportSettings(aspect: aspect, resolution: resolution, framesPerSecond: framesPerSecond, quality: quality)
    }

    /// What the sheet remembers of these choices once they are exported.
    var preferences: ExportPreferences {
        ExportPreferences(shortSide: resolution.rawValue, highQuality: quality == .high)
    }

    /// About how big the MP4 is, as a file size ("120 MB").
    var estimatedSize: String {
        ByteCountFormatter.string(fromByteCount: settings.estimatedBytes(durationSeconds: durationSeconds), countStyle: .file)
    }

    /// Whether `resolution` has more pixels on its shorter side than what was recorded of the screen.
    func exceedsRecording(_ resolution: ExportResolution) -> Bool {
        recordedShortSide.map { ExportSettings.exceedsRecording(resolution, recordedShortSide: $0) } ?? false
    }
}

/// The export sheet over the editor's window (design §5.6): the format (shown), the resolution with "Higher than the
/// recording" beside those above what was recorded, the frames per second, the quality, the estimated size, and
/// "Export…", which goes on to the save panel.
struct ExportSheet: View {
    @Bindable var choices: ExportChoices
    let model: EditorModel
    /// Called with `true` for "Export…", `false` for Cancel.
    let finish: (Bool) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Export Video")
                .font(.headline)
                .padding([.top, .horizontal], 20)
            Form {
                LabeledContent("Format") {
                    Text(FormatMenu.title(choices.aspect))
                }
                Picker("Resolution", selection: $choices.resolution) {
                    ForEach(ExportResolution.allCases, id: \.self) { resolution in
                        resolutionLabel(resolution).tag(resolution)
                    }
                }
                .pickerStyle(.radioGroup)
                Picker("Frame Rate", selection: $choices.framesPerSecond) {
                    ForEach(StyleCommands.frameRates, id: \.self) { fps in
                        Text(fps, format: .number).tag(fps)
                    }
                }
                Picker("Quality", selection: $choices.quality) {
                    Text("Standard", comment: "The export sheet: the quality of 0.08 bits per pixel").tag(ExportQuality.standard)
                    Text("High", comment: "The export sheet: the quality of 0.14 bits per pixel (Spanish: feminine, la calidad)")
                        .tag(ExportQuality.high)
                }
                .pickerStyle(.segmented)
            }
            .formStyle(.grouped)
            HStack {
                Text("About \(choices.estimatedSize)", comment: "The export sheet: the MP4's estimated size, as “120 MB”")
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
                Spacer()
                Button("Cancel", role: .cancel) { finish(false) }
                    .keyboardShortcut(.cancelAction)
                Button("Export…") { finish(true) }
                    .keyboardShortcut(.defaultAction)
                    .disabled(!model.canExport)
            }
            .padding([.bottom, .horizontal], 20)
        }
        .frame(width: 440)
        .fixedSize(horizontal: false, vertical: true)
    }

    private func resolutionLabel(_ resolution: ExportResolution) -> some View {
        HStack(spacing: 8) {
            Text(verbatim: Self.name(resolution))
            if choices.exceedsRecording(resolution) {
                Text("Higher than the recording", comment: "The export sheet: beside a resolution above what was recorded of the screen")
                    .foregroundStyle(.secondary)
            }
        }
    }

    /// 720p, 1080p, 1440p and 4K, the same in every language.
    static func name(_ resolution: ExportResolution) -> String {
        resolution == .p2160 ? "4K" : "\(resolution.rawValue)p"
    }
}

extension Notification.Name {
    /// The export sheet remembers another resolution or quality: each editor draws its paused preview at the resolution
    /// (plan decision 11).
    static let exportPreferencesChanged = Notification.Name("dev.toma.Toma.exportPreferencesChanged")
}

extension EditorModel {
    /// Export, the bar's button (⌘E) and the keyboard's `EditorCommand.export` (Task 42): the export sheet over the
    /// window. Its "Export…" takes a copy of the document as it is then and goes on to the save panel, with
    /// `<project>.mp4` in the project's folder; what is edited while it exports is not in the MP4.
    func openExportSheet() {
        guard canExport, let window, window.attachedSheet == nil, let session = panelSession else { return }
        let choices = ExportChoices(
            document: session.document, take: session.project.take, remembered: SettingsStore().settings.export)
        let host = NSHostingController(
            rootView: ExportSheet(choices: choices, model: self) { [weak self, weak window] export in
                // The sheet is the window's only one: the save panel comes after it.
                guard let window, let sheet = window.attachedSheet else { return }
                // The document as it is when "Export…" is chosen.
                let document = export ? self?.panelSession?.document : nil
                window.endSheet(sheet)
                guard let self, let document else { return }
                chooseDestination(of: document, settings: choices.settings, remembering: choices.preferences)
            })
        // Sized by its content (the hosting controller's standard bounds).
        let sheet = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 440, height: 300), styleMask: [.titled], backing: .buffered, defer: true)
        sheet.isReleasedWhenClosed = false
        sheet.contentViewController = host
        window.beginSheet(sheet)
    }

    /// The save panel, as a sheet, then the export of `document` with `settings`; once it starts, the sheet remembers
    /// `preferences`.
    private func chooseDestination(
        of document: EditDocument, settings: ExportSettings, remembering preferences: ExportPreferences
    ) {
        guard canExport, let window, let current = panelSession?.packageURL else { return }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.mpeg4Movie]
        panel.canCreateDirectories = true
        panel.nameFieldStringValue = current.deletingPathExtension().lastPathComponent + ".mp4"
        panel.directoryURL = current.deletingLastPathComponent()
        Task {
            guard await panel.beginSheetModal(for: window) == .OK, let destination = panel.url,
                startExport(document, settings: settings, to: destination)
            else { return }
            Self.remember(preferences)
        }
    }

    /// Keeps `preferences` in the app's settings and tells every editor.
    private static func remember(_ preferences: ExportPreferences) {
        let store = SettingsStore()
        var settings = store.settings
        guard settings.export != preferences else { return }
        settings.export = preferences
        store.settings = settings
        NotificationCenter.default.post(name: .exportPreferencesChanged, object: nil)
    }
}
