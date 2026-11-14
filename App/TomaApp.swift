// SPDX-License-Identifier: GPL-3.0-or-later
import AppKit
import SwiftUI

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

/// `record.circle` at rest; `record.circle.fill` in red while a take is being recorded.
private struct MenuBarIcon: View {
    let recording: RecordingController

    var body: some View {
        if recording.isRecording {
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
    let app: AppDelegate
    let recording: RecordingController
    let updater: UpdaterController

    var body: some View {
        switch recording.phase {
        case .idle:
            Button("Record Main Display") { recording.startRecording() }
        case .starting:
            Text("Starting recording…")
        case .recording:
            Text("Recording \(recording.elapsed.formatted(.time(pattern: .hourMinuteSecond)))", comment: "Menu item while recording: the time recorded so far")
            Button("Stop Recording") { recording.stopRecording() }
        case .stopping:
            Text("Saving recording…")
        }
        if !recording.warnings.isEmpty {
            Divider()
            ForEach(Array(recording.warnings.enumerated()), id: \.offset) { _, warning in
                Text(warning)
            }
        }
        Divider()
        Button("Open Last Project") { recording.openLastProject() }
            .disabled(!recording.hasLastProject)
        Button("Recover Recordings…") { app.recoverRecordings() }
        Button("Permissions…") { app.showOnboarding() }
        Divider()
        Button("Check for Updates…") { updater.checkForUpdates() }
            .disabled(recording.isRecording || !updater.isCheckAvailable)
        Button("Acknowledgements…") { app.showThirdPartyNotices() }
        Divider()
        Button("Quit") { NSApplication.shared.terminate(nil) }
            .keyboardShortcut("q")
    }
}
