// SPDX-License-Identifier: GPL-3.0-or-later
import AppKit
import AppSupport
import SwiftUI

@main
struct TomaApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @State private var clock = MenuBarClock()

    var body: some Scene {
        MenuBarExtra {
            MenuContent(app: appDelegate, recording: appDelegate.recording, updater: appDelegate.updater, clock: clock)
        } label: {
            MenuBarIcon(recording: appDelegate.recording, clock: clock)
        }
        .commands {
            EditorCommands()
            ProjectCommands(app: appDelegate)
            LibraryCommands(app: appDelegate)
        }
    }
}

/// The time the menu bar shows, ticked once a second by a timer. A `TimelineView` in a `MenuBarExtra`
/// (its label or its menu) makes SwiftUI rebuild the status item without pause: the main thread spins at
/// ~100 % CPU and the island and Stop stop answering (macOS 26). A label that reads `now` while a take
/// records is redrawn once a second; at rest it doesn't read `now`, so the tick redraws nothing.
@MainActor @Observable final class MenuBarClock {
    private(set) var now = Date()
    @ObservationIgnored private var timer: Timer?

    init() {
        let timer = Timer(timeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.now = Date() }
        }
        timer.tolerance = 0.1
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }
}

/// `record.circle` at rest; `record.circle.fill` in red while a take is being recorded, followed by the
/// time it has recorded.
private struct MenuBarIcon: View {
    let recording: RecordingController
    let clock: MenuBarClock

    var body: some View {
        if case .recording = recording.phase {
            HStack(spacing: 4) {
                Image(nsImage: Self.recordingImage)
                Text(verbatim: recording.elapsed(at: clock.now).recordedTime)
                    .monospacedDigit()
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
    let app: AppDelegate
    let recording: RecordingController
    let updater: UpdaterController
    let clock: MenuBarClock

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
            Text(
                "Recording \(recording.elapsed(at: clock.now).formatted(.time(pattern: .hourMinuteSecond)))",
                comment: "Menu item while recording: the time recorded so far")
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
        Button("Open…") { app.openProject() }
            .keyboardShortcut("o")
        Button("Open Last Project") { recording.openLastProject() }
            .disabled(!recording.hasLastProject)
        Button("Library…") { app.showLibrary() }
            .keyboardShortcut("l", modifiers: [.command, .shift])
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
}

/// Window ▸ Library (⇧⌘L): while the app is active or the menu is open; not a global shortcut.
private struct LibraryCommands: Commands {
    let app: AppDelegate

    var body: some Commands {
        CommandGroup(after: .windowArrangement) {
            Button("Library") { app.showLibrary() }
                .keyboardShortcut("l", modifiers: [.command, .shift])
        }
    }
}
