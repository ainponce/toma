// SPDX-License-Identifier: GPL-3.0-or-later
import AppKit
import Export
import Observation
import ProjectFormat
import Render
import SwiftUI
import Synchronization
import UniformTypeIdentifiers
import os

/// Allows one export at a time in the whole app: blocking reads of several exports at once starve each other.
@MainActor @Observable
final class ExportGate {
    var isBusy = false
}

/// A window showing one take of a project: preview, playback, scrubbing and MP4 export.
@MainActor
final class EditorWindowController: NSWindowController, NSWindowDelegate {
    let packageURL: URL
    private let model: EditorModel
    private let onClose: () -> Void

    init(packageURL: URL, takeID: String?, exportGate: ExportGate, onClose: @escaping () -> Void) {
        self.packageURL = packageURL
        self.onClose = onClose
        model = EditorModel(packageURL: packageURL, takeID: takeID, exportGate: exportGate)
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 960, height: 640),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered, defer: false)
        window.title = packageURL.deletingPathExtension().lastPathComponent
        window.representedURL = packageURL
        window.isReleasedWhenClosed = false
        let hosting = NSHostingController(rootView: EditorView(model: model))
        hosting.sizingOptions = [.minSize]
        window.contentViewController = hosting
        window.setContentSize(NSSize(width: 960, height: 640))
        window.center()
        super.init(window: window)
        window.delegate = self
        model.window = window
        model.load()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        nil
    }

    /// Loads the project again if it could not be shown, for example after it was recovered.
    func reloadIfNeeded() {
        if case .failed = model.state { model.load() }
    }

    func windowWillClose(_ notification: Notification) {
        model.close()
        // On the next turn: the window is still closing, and dropping this controller releases it.
        Task { self.onClose() }
    }
}

// MARK: - Model

/// The output size of the preview in phase 0.
private let previewOutputSize: SIMD2<Int> = [1920, 1080]

@MainActor @Observable
final class EditorModel {
    enum State {
        case loading
        case ready(PreviewRenderer)
        case failed(String)
    }

    enum ExportState: Equatable {
        case idle
        case running(progress: Double)
        case finished(URL)
    }

    let packageURL: URL
    let takeID: String?
    private(set) var state = State.loading
    private(set) var duration = 0.0
    private(set) var currentTime = 0.0
    private(set) var isPlaying = false
    private(set) var exportState = ExportState.idle
    var canExport: Bool { project != nil && !exportGate.isBusy }

    @ObservationIgnored weak var window: NSWindow?
    @ObservationIgnored private let exportGate: ExportGate
    @ObservationIgnored private var project: LoadedProject?
    @ObservationIgnored private var exportTask: Task<Void, Never>?
    @ObservationIgnored private var resumeAfterScrub = false
    @ObservationIgnored private var closed = false
    @ObservationIgnored private var lastPublished: ContinuousClock.Instant?

    private nonisolated static let logger = Logger(subsystem: "dev.toma.Toma", category: "Editor")

    /// While playing, the time shown is published at most this often.
    private static let playbackPublishInterval = Duration.milliseconds(100)

    init(packageURL: URL, takeID: String?, exportGate: ExportGate) {
        self.packageURL = packageURL
        self.takeID = takeID
        self.exportGate = exportGate
    }

    private var preview: PreviewRenderer? {
        if case .ready(let preview) = state { preview } else { nil }
    }

    // MARK: Loading

    /// Reads the take and prepares the preview on `PreviewPreparation`'s queue, never on the main thread or
    /// a Swift concurrency thread: reading the events and the first frame of a segment blocks.
    func load() {
        state = .loading
        let url = packageURL, take = takeID
        Task {
            do {
                let prepared = try await PreviewPreparation.prepare(url: url, take: take, outputSize: previewOutputSize)
                guard !closed else { return }
                project = prepared.project
                duration = prepared.duration
                currentTime = 0
                isPlaying = false
                state = .ready(prepared.preview)
            } catch PreviewPreparationError.unfinished {
                state = .failed(String(localized: "This recording hasn't finished saving. If it isn't being recorded now, recover it with Recover Recordings… in the menu bar."))
            } catch PreviewPreparationError.cannotDraw(let reason) {
                Self.logger.error("Cannot draw the first frame: \(reason, privacy: .public)")
                state = .failed(String(localized: "Couldn't draw the preview."))
            } catch {
                Self.logger.error("Cannot open \(url.path, privacy: .public): \(String(describing: error), privacy: .public)")
                state = .failed(userFacingDescription(of: error))
            }
        }
    }

    // MARK: Playback

    func togglePlay() {
        guard let preview else { return }
        if !preview.isPlaying, preview.currentTime >= duration { preview.currentTime = 0 }
        preview.isPlaying.toggle()
        sync()
    }

    func seek(to time: Double) {
        guard let preview else { return }
        preview.currentTime = time
        sync()
    }

    /// Dragging the time bar pauses playback until it is let go.
    func scrubbing(_ editing: Bool) {
        guard let preview else { return }
        if editing {
            resumeAfterScrub = preview.isPlaying
            preview.isPlaying = false
        } else if resumeAfterScrub {
            resumeAfterScrub = false
            preview.isPlaying = true
        }
        sync()
    }

    /// After every frame drawn: playing moves the time, and stops at the end. While it plays, the time is
    /// published at most every `playbackPublishInterval`, not on every frame.
    func previewDidDraw() {
        guard let preview else { return }
        if isPlaying, preview.isPlaying, let lastPublished,
           ContinuousClock.now - lastPublished < Self.playbackPublishInterval {
            return
        }
        sync()
    }

    private func sync() {
        guard let preview else { return }
        let time = preview.currentTime, playing = preview.isPlaying
        lastPublished = .now
        if currentTime != time { currentTime = time }
        if isPlaying != playing { isPlaying = playing }
    }

    // MARK: Export

    func exportMP4() {
        guard canExport, let window else { return }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.mpeg4Movie]
        panel.canCreateDirectories = true
        panel.nameFieldStringValue = packageURL.deletingPathExtension().lastPathComponent + ".mp4"
        panel.directoryURL = packageURL.deletingLastPathComponent()
        Task {
            guard await panel.beginSheetModal(for: window) == .OK, let destination = panel.url else { return }
            startExport(to: destination)
        }
    }

    private func startExport(to destination: URL) {
        guard canExport, let project else { return }
        exportGate.isBusy = true
        exportState = .running(progress: 0)
        let exporter = MP4Exporter(project: project)
        let throttle = ProgressThrottle()
        // Called off the main thread, per frame.
        let progress: @Sendable (Double) -> Void = { [weak self] value in
            guard throttle.shouldReport(value) else { return }
            Task { @MainActor in self?.exportProgressed(value) }
        }
        exportTask = Task {
            do {
                let summary = try await exporter.export(to: destination, progress: progress)
                exportState = .finished(destination)
                if !summary.missingAudio.isEmpty {
                    showAlert(String(localized: "The video was exported, but \(summary.missingAudio.count) parts have no sound: their microphone audio couldn't be read."), style: .warning)
                }
            } catch let error where Self.isCancellation(error) {
                exportState = .idle
            } catch {
                Self.logger.error("Export to \(destination.path, privacy: .public) failed: \(String(describing: error), privacy: .public)")
                exportState = .idle
                showAlert(String(localized: "Couldn't export the video"), informative: userFacingDescription(of: error), style: .warning)
            }
            exportGate.isBusy = false
            exportTask = nil
        }
    }

    func cancelExport() {
        exportTask?.cancel()
    }

    private func exportProgressed(_ value: Double) {
        guard case .running(let progress) = exportState, value > progress else { return }
        exportState = .running(progress: value)
    }

    private static func isCancellation(_ error: any Error) -> Bool {
        error is CancellationError || (error as? ExportError) == .cancelled
    }

    // MARK: Closing

    /// The window closed: playback stops and an export in progress is cancelled.
    func close() {
        closed = true
        preview?.isPlaying = false
        exportTask?.cancel()
    }

    private func showAlert(_ message: String, informative: String = "", style: NSAlert.Style) {
        let alert = NSAlert()
        alert.alertStyle = style
        alert.messageText = message
        alert.informativeText = informative
        if let window, window.isVisible {
            alert.beginSheetModal(for: window)
        } else {
            alert.runModal()
        }
    }
}

/// Lets export progress through at most every half percent, so the main thread is not called per frame.
private final class ProgressThrottle: Sendable {
    private let last = Mutex(-1.0)

    func shouldReport(_ value: Double) -> Bool {
        last.withLock { last in
            guard value >= 1 || value - last >= 0.005 else { return false }
            last = value
            return true
        }
    }
}

// MARK: - View

struct EditorView: View {
    let model: EditorModel

    var body: some View {
        VStack(spacing: 0) {
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            if case .ready = model.state {
                Divider()
                controls
                    .padding(12)
            }
        }
        .frame(minWidth: 520, minHeight: 360)
    }

    @ViewBuilder
    private var content: some View {
        switch model.state {
        case .loading:
            ProgressView("Loading…")
        case .failed(let message):
            ContentUnavailableView {
                Label("Couldn't open the project", systemImage: "exclamationmark.triangle")
            } description: {
                Text(message)
            }
        case .ready(let preview):
            PreviewView(preview: preview, isPlaying: model.isPlaying, time: model.currentTime, onDraw: model.previewDidDraw)
                .aspectRatio(CGFloat(previewOutputSize.x) / CGFloat(previewOutputSize.y), contentMode: .fit)
                .padding(16)
        }
    }

    private var controls: some View {
        HStack(spacing: 12) {
            Button {
                model.togglePlay()
            } label: {
                if model.isPlaying {
                    Label("Pause", systemImage: "pause.fill")
                } else {
                    Label("Play", systemImage: "play.fill")
                }
            }
            .labelStyle(.iconOnly)
            .frame(width: 24)
            .keyboardShortcut(.space, modifiers: [])

            Slider(
                value: Binding(get: { model.currentTime }, set: { model.seek(to: $0) }),
                in: 0...max(model.duration, 0.001),
                onEditingChanged: { model.scrubbing($0) })

            Text(verbatim: "\(Self.timecode(model.currentTime, duration: model.duration)) / \(Self.timecode(model.duration, duration: model.duration))")
                .monospacedDigit()
                .foregroundStyle(.secondary)

            exportControls
        }
    }

    @ViewBuilder
    private var exportControls: some View {
        switch model.exportState {
        case .running(let progress):
            ProgressView(value: progress) {
                Text("Exporting…")
            }
            .frame(width: 140)
            Button("Cancel") { model.cancelExport() }
        case .idle, .finished:
            if case .finished(let url) = model.exportState {
                Text("Export finished.")
                    .foregroundStyle(.secondary)
                Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([url]) }
            }
            Button("Export MP4…") { model.exportMP4() }
                .disabled(!model.canExport)
        }
    }

    /// `m:ss`, or `h:mm:ss` when the take lasts an hour or more; whole seconds, rounded down.
    private static func timecode(_ seconds: Double, duration: Double) -> String {
        let whole = Duration.seconds(max(0, seconds).rounded(.down))
        return whole.formatted(.time(pattern: duration >= 3600 ? .hourMinuteSecond : .minuteSecond))
    }
}
