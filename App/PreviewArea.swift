// SPDX-License-Identifier: GPL-3.0-or-later
import AppKit
import AppSupport
import Editing
import ProjectFormat
import QuartzCore
import SwiftUI

/// The preview's part of the window (design §5.3): the banner on top, then, on a fixed dark gray in light and dark mode
/// alike (#161618: colors are judged against a dark neutral), the video with 16 pt around it in the format's proportion
/// and the transport under it: ⏮ ▶/⏸ ⏭ and `0:42,18 / 2:14,00`. Before it can show the video, what stands in its place:
/// "Opening…", a take that didn't finish saving, a project that couldn't be opened, or one of a newer version.
struct PreviewArea: View {
    let model: EditorModel

    /// The gray around the video.
    static let background = Color(red: 0x16 / 255.0, green: 0x16 / 255.0, blue: 0x18 / 255.0)

    var body: some View {
        VStack(spacing: 0) {
            EditorBanners(model: model)
            ZStack {
                Self.background
                content
                    .environment(\.colorScheme, .dark)
            }
        }
        .navigationTitle(Text(verbatim: model.name))
    }

    @ViewBuilder
    private var content: some View {
        switch model.state {
        case .opening:
            ProgressView("Opening…")
        case .unfinished:
            ContentUnavailableView {
                Label("This recording hasn't finished saving", systemImage: "exclamationmark.triangle")
            } description: {
                Text("If it isn't being recorded now, click Recover. Nothing recorded is deleted.")
            } actions: {
                Button("Recover") { model.recover() }
                    .keyboardShortcut(.defaultAction)
            }
        case .recovering:
            ProgressView("Recovering…")
        case let .failed(message):
            ContentUnavailableView {
                Label("Couldn't open the project", systemImage: "exclamationmark.triangle")
            } description: {
                Text(verbatim: message)
            }
        case .newerDocument:
            ContentUnavailableView {
                Label {
                    Text(verbatim: EditorBanners.text(.newerDocument(0)))
                } icon: {
                    Image(systemName: "arrow.down.app")
                }
            }
        case .ready:
            VStack(spacing: 12) {
                PreviewSurface(model: model)
                    .aspectRatio(CGFloat(model.previewAspect.ratio), contentMode: .fit)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                Transport(model: model)
            }
            .padding(16)
        }
    }
}

/// ⏮ (to the start), ▶/⏸ and ⏭ (to the end), and the time of the playhead over what the output lasts.
private struct Transport: View {
    let model: EditorModel

    var body: some View {
        HStack(spacing: 16) {
            Button {
                model.seekToStart()
            } label: {
                Label("Go to the Beginning", systemImage: "backward.end.fill")
            }
            Button {
                model.togglePlay()
            } label: {
                if model.isPlaying {
                    Label("Pause", systemImage: "pause.fill")
                } else {
                    Label("Play", systemImage: "play.fill")
                }
            }
            .keyboardShortcut(.space, modifiers: [])
            .frame(width: 20)
            Button {
                model.seekToEnd()
            } label: {
                Label("Go to the End", systemImage: "forward.end.fill")
            }
            Text(verbatim: time)
                .monospacedDigit()
                .foregroundStyle(.secondary)
                .padding(.leading, 8)
        }
        .labelStyle(.iconOnly)
        .buttonStyle(.borderless)
        .font(.title3)
        .disabled(!model.canPlay)
    }

    private var time: String {
        let total = model.durationSeconds
        return Timecode.precise(model.currentSeconds, total: total, locale: .current) + " / "
            + Timecode.precise(total, total: total, locale: .current)
    }
}

/// The view the preview engine draws into: it hosts the model's `CAMetalLayer`, keeps the layer's drawable at its size
/// in pixels, and, while playing, asks for a frame on each refresh of its display.
private struct PreviewSurface: NSViewRepresentable {
    let model: EditorModel

    func makeNSView(context: Context) -> PreviewSurfaceView {
        PreviewSurfaceView(model: model)
    }

    func updateNSView(_ view: PreviewSurfaceView, context: Context) {
        view.setPlaying(model.isPlaying)
        view.setAccessibilityValue(Timecode.precise(model.currentSeconds, total: model.durationSeconds, locale: .current))
    }

    static func dismantleNSView(_ view: PreviewSurfaceView, coordinator: ()) {
        view.stopDisplayLink()
    }
}

/// See `PreviewSurface`. A click plays or pauses, as in QuickTime (a double click does nothing more: only its first
/// click counts); a drag does not.
final class PreviewSurfaceView: NSView {
    private let model: EditorModel
    private var displayLink: CADisplayLink?
    private var isPlaying = false
    private var mouseDownPoint: NSPoint?

    init(model: EditorModel) {
        self.model = model
        super.init(frame: .zero)
        // Layer-hosting: the layer first, then `wantsLayer`.
        layer = model.previewLayer
        wantsLayer = true
        model.previewLayer.contentsGravity = .resizeAspect
        setAccessibilityElement(true)
        setAccessibilityRole(.image)
        setAccessibilityLabel(String(localized: "Preview"))
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        nil
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        stopDisplayLink()
        guard window != nil else { return }
        // In the common modes, so playback goes on while a menu, a slider or a scroll is tracking.
        let link = displayLink(target: self, selector: #selector(displayTick(_:)))
        link.add(to: .main, forMode: .common)
        link.isPaused = !isPlaying
        displayLink = link
        updateDrawableSize()
    }

    func stopDisplayLink() {
        displayLink?.invalidate()
        displayLink = nil
    }

    func setPlaying(_ playing: Bool) {
        isPlaying = playing
        displayLink?.isPaused = !playing
    }

    @objc private func displayTick(_ link: CADisplayLink) {
        model.displayTick()
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        updateDrawableSize()
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        updateDrawableSize()
    }

    /// The layer's drawable is the view's size in pixels; paused, the frame is drawn again at it.
    private func updateDrawableSize() {
        let pixels = convertToBacking(bounds).size
        guard pixels.width >= 1, pixels.height >= 1 else { return }
        let scale = window?.backingScaleFactor ?? 2
        let layer = model.previewLayer
        guard layer.drawableSize != pixels || layer.contentsScale != scale else { return }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        layer.contentsScale = scale
        layer.drawableSize = pixels
        CATransaction.commit()
        model.redrawPaused()
    }

    override func mouseDown(with event: NSEvent) {
        mouseDownPoint = event.clickCount == 1 ? convert(event.locationInWindow, from: nil) : nil
    }

    override func mouseUp(with event: NSEvent) {
        defer { mouseDownPoint = nil }
        guard let start = mouseDownPoint else { return }
        let end = convert(event.locationInWindow, from: nil)
        guard hypot(end.x - start.x, end.y - start.y) < 4 else { return }
        model.togglePlay()
    }
}
