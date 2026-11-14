// SPDX-License-Identifier: GPL-3.0-or-later
import AppKit
import AppSupport
import ProjectFormat
import os

/// Owns the recording, the windows and the app's life: the recovery prompt at launch, the permissions
/// window, editors (also for projects opened from Finder), the Dock icon, and closing a take before quitting.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let recording: RecordingController
    private let probe: any PermissionProbe = SystemPermissionProbe()
    private let recovery = RecoveryPrompt()
    private let exportGate = ExportGate()
    private var editors: [URL: EditorWindowController] = [:]
    private var onboarding: OnboardingWindowController?
    private var powerOffObserver: (any NSObjectProtocol)?
    /// The take is being closed to quit or power off.
    private var closingForQuit = false
    /// Closing to quit has taken longer than `quitTimeLimit`.
    private var quitTimeLimitPassed = false
    /// `applicationShouldTerminate` answered `.terminateLater` and waits for a reply.
    private var terminationPending = false
    private var terminationReplied = false

    /// How long quitting waits for the take to close.
    private static let quitTimeLimit = Duration.seconds(30)

    private static let logger = Logger(subsystem: "dev.toma.Toma", category: "App")

    override init() {
        recording = RecordingController(probe: probe)
        super.init()
        recording.openEditor = { [weak self] url, take in self?.showEditor(for: url, take: take) }
        recording.openOnboarding = { [weak self] in self?.showOnboarding() }
        recording.recordingStateChanged = { [weak self] in self?.updateActivationPolicy() }
        recovery.recovered = { [weak self] url in
            self?.recording.noteRecovered(url)
            self?.showEditor(for: url, take: nil)
        }
    }

    // MARK: - Life cycle

    func applicationDidFinishLaunching(_ notification: Notification) {
        powerOffObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.willPowerOffNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.willPowerOff() }
        }
        Task {
            await recovery.run(in: RecordingController.projectsFolder, atLaunch: true)
            if PermissionsModel.needsAttention(probe: probe) { showOnboarding() }
        }
    }

    /// A take in progress is closed before quitting: the app quits once `stop()` returns (even if closing
    /// failed: the take can still be recovered), or after `quitTimeLimit` if it has not returned by then.
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard recording.isRecording else { return .terminateNow }
        if quitTimeLimitPassed {
            // Closing for a power off already took too long.
            Self.logger.error("Quitting before the take closed; it stays recoverable")
            return .terminateNow
        }
        Self.logger.notice("Quitting while recording: closing the take first")
        terminationPending = true
        closeTakeBeforeQuitting()
        return .terminateLater
    }

    /// Logging out, restarting or shutting down: the take starts closing now, before the system asks the
    /// app to quit, which then waits for the same stop and the same time limit.
    private func willPowerOff() {
        guard recording.isRecording else { return }
        Self.logger.notice("Powering off while recording: closing the take")
        closeTakeBeforeQuitting()
    }

    /// Starts closing the take, once, with `quitTimeLimit`; whichever ends first answers a pending quit.
    private func closeTakeBeforeQuitting() {
        guard !closingForQuit else { return }
        closingForQuit = true
        let deadline = Task {
            try? await Task.sleep(for: Self.quitTimeLimit)
            guard !Task.isCancelled else { return }
            quitTimeLimitPassed = true
            replyToTermination(takeClosed: false)
        }
        Task {
            await recording.stop(openingEditor: false)
            deadline.cancel()
            closingForQuit = false
            quitTimeLimitPassed = false
            replyToTermination(takeClosed: true)
        }
    }

    /// Lets a pending quit go ahead; only the first call replies.
    private func replyToTermination(takeClosed: Bool) {
        guard terminationPending, !terminationReplied else { return }
        terminationReplied = true
        if !takeClosed { Self.logger.error("Quitting before the take closed; it stays recoverable") }
        NSApp.reply(toApplicationShouldTerminate: true)
    }

    /// Projects opened from Finder (or dropped on the app) open in the editor.
    func application(_ application: NSApplication, open urls: [URL]) {
        for url in urls where url.pathExtension.lowercased() == ProjectPackage.fileExtension {
            showEditor(for: url, take: nil)
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    // MARK: - Menu actions

    func recoverRecordings() {
        Task { await recovery.run(in: RecordingController.projectsFolder, atLaunch: false) }
    }

    func showOnboarding() {
        if onboarding == nil {
            onboarding = OnboardingWindowController(probe: probe) { [weak self] in
                guard let self, onboarding?.window?.isVisible != true else { return }  // shown again meanwhile
                onboarding = nil
                updateActivationPolicy()
            }
        }
        present(onboarding)
    }

    // MARK: - Windows

    func showEditor(for url: URL, take: String?) {
        let key = url.standardizedFileURL
        if let editor = editors[key] {
            editor.reloadIfNeeded()
            present(editor)
            return
        }
        let editor = EditorWindowController(packageURL: key, takeID: take, exportGate: exportGate) { [weak self] in
            guard let self, editors[key]?.window?.isVisible != true else { return }  // shown again meanwhile
            editors[key] = nil
            updateActivationPolicy()
        }
        editors[key] = editor
        present(editor)
    }

    private func present(_ controller: NSWindowController?) {
        updateActivationPolicy()
        NSApp.activate()
        controller?.showWindow(nil)
        controller?.window?.makeKeyAndOrderFront(nil)
    }

    /// In the Dock and Cmd-Tab only while a window is open and no take is being recorded.
    private func updateActivationPolicy() {
        let openWindows = editors.count + (onboarding == nil ? 0 : 1)
        let policy = ActivationPolicyDecision.policy(openWindows: openWindows, isRecording: recording.isRecording)
        guard NSApp.activationPolicy() != policy else { return }
        NSApp.setActivationPolicy(policy)
        if policy == .regular { NSApp.activate() }
    }
}
