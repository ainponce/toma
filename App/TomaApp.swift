// SPDX-License-Identifier: GPL-3.0-or-later
import AppKit
import AppSupport
import ProjectFormat
import SwiftUI
import os

@main
struct TomaApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        MenuBarExtra {
            MenuContent(app: appDelegate, recording: appDelegate.recording, updater: appDelegate.updater)
        } label: {
            MenuBarIcon(recording: appDelegate.recording)
        }
    }
}

/// `record.circle` at rest; `record.circle.fill` in red while a take is being recorded, followed by the
/// time it has recorded.
private struct MenuBarIcon: View {
    let recording: RecordingController

    var body: some View {
        if case .recording = recording.phase {
            TimelineView(.periodic(from: .now, by: 1)) { context in
                HStack(spacing: 4) {
                    Image(nsImage: Self.recordingImage)
                    Text(verbatim: recording.elapsed(at: context.date).recordedTime)
                        .monospacedDigit()
                }
            }
        } else if recording.isRecording {
            Image(nsImage: Self.recordingImage)
        } else {
            Image(systemName: "record.circle")
                .accessibilityLabel(Text(verbatim: AppIdentity.name))
        }
    }

    /// A template image would be drawn in the menu bar's color, so this one is not a template.
    @MainActor private static let recordingImage: NSImage = {
        let symbol = NSImage(
            systemSymbolName: "record.circle.fill",
            accessibilityDescription: String(localized: "Recording", comment: "A recording: the start of a new project's name, and the menu bar icon while recording"))
        let image = symbol?.withSymbolConfiguration(NSImage.SymbolConfiguration(paletteColors: [.systemRed])) ?? NSImage()
        image.isTemplate = false
        return image
    }()
}

private struct MenuContent: View {
    private static let logger = Logger(subsystem: "dev.toma.Toma", category: "App")

    let app: AppDelegate
    let recording: RecordingController
    let updater: UpdaterController

    var body: some View {
        switch recording.phase {
        case .idle:
            Button("New Recording") { app.newRecording() }
                .keyboardShortcut(app.hotKeys.bindings.combos[.islandOrStop]?.menuShortcut)
        case .countingDown:
            Text("Starting recording…")
            // Cancels the countdown: nothing is recorded.
            Button("Stop Recording") { recording.stopRecording() }
        case .starting:
            Text("Starting recording…")
        case .recording:
            TimelineView(.periodic(from: .now, by: 1)) { context in
                Text(
                    "Recording \(recording.elapsed(at: context.date).formatted(.time(pattern: .hourMinuteSecond)))",
                    comment: "Menu item while recording: the time recorded so far")
            }
            // The user's pause first: a lock during it changes nothing for the take.
            if recording.isUserPaused {
                Text("Paused", comment: "Menu item, and the open island, while the user has paused the take")
            } else if recording.isPaused {
                Text("Paused (screen locked or Mac asleep)", comment: "Menu item while a take is paused because the screen is locked or the Mac sleeps")
            }
            Button("Stop Recording") { recording.stopRecording() }
        case .stopping:
            Text("Saving recording…")
        }
        if !recording.notices.isEmpty {
            Divider()
            ForEach(Array(recording.notices.enumerated()), id: \.offset) { _, notice in
                Text(notice.text(closeError: recording.lastCloseError))
            }
        }
        Divider()
        Button("Open Last Project") { recording.openLastProject() }
            .disabled(!recording.hasLastProject)
        if recording.phase == .idle {
            Button("Show Trash in Finder") { showTrash() }
        }
        Button("Recover Recordings…") { app.recoverRecordings() }
        Button("Permissions…") { app.showOnboarding() }
        Button("Settings…") { app.showSettings() }
        Divider()
        Button("Check for Updates…") { updater.checkForUpdates() }
            .disabled(recording.isRecording || !updater.isCheckAvailable)
        Button("Acknowledgements…") { app.showThirdPartyNotices() }
        Divider()
        Button("Quit") { NSApplication.shared.terminate(nil) }
            .keyboardShortcut("q")
    }

    /// Opens the folder restarted takes go to, made empty if none has gone there yet.
    private func showTrash() {
        let trash = ProjectTrash.folder(in: recording.projectsFolder)
        do {
            try FileManager.default.createDirectory(at: trash, withIntermediateDirectories: true)
        } catch {
            Self.logger.error("Cannot create the trash folder \(trash.path, privacy: .public): \(String(describing: error), privacy: .public)")
            // Opening the projects folder instead still shows where to look.
            NSWorkspace.shared.open(recording.projectsFolder)
            return
        }
        NSWorkspace.shared.open(trash)
    }
}
